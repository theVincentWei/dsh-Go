/// AppHub 本机固定端口反向代理(`127.0.0.1:kAppHubProxyPort`)。
///
/// 为什么必须有它:原生 Dimina 容器(OkHttp,非 Dart 线程)拿着 open 时传入的
/// updateManifestUrl 去拉 manifest/升级包,而这个 URL 的端口来自 SSH 链路
/// 每次建立时动态绑定的本地转发(`SshHostLink._ensureAppHubForward` →
/// `appHubBase`)。链路一重连端口就换,烤进 URL 的旧端口立刻死掉——容器
/// installInitialPackage 抛 `Failed to connect to /127.0.0.1:<旧端口>`,
/// DiminaActivity 在 prepare 的 catch 里 finish(),表现为小程序「一打开就
/// 闪退」,而市场页(Dart 侧发请求)一切正常,极具迷惑性(2026-11-09 真机)。
///
/// 修法:原生容器永远只认这个固定端口;代理在每个请求到达时经当下的上游
/// ([AppHubUpstream])把字节转出去——SSH/本地是 [TcpAppHubUpstream],转发
/// 刻意保留代理自己的 Host 头,AppHub 按 Host 拼 packageUrl,于是包下载
/// 地址也稳定指向代理;relay 链路(`remote.apphub.proxy.v1`)是
/// `RemoteAppHubUpstream`,经加密 RPC 直达引擎主机上的 AppHub 网关,主机
/// 侧 AppHub 没有动态端口问题。链路断了代理回 502:后台升级检查静默失败
/// (no-update),不崩容器。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'apphub_base.dart';
import 'apphub_upstream.dart';

/// 代理固定端口起点;被占则顺延(最多 20 个),避开 adb reverse 之类。
const int kAppHubProxyPort = 7619;

/// 原生容器应使用的 AppHub base:代理活着就是代理,否则退回动态 base
/// (与旧行为一致)。
String get appHubProxyBase =>
    AppHubProxy.started ? 'http://127.0.0.1:${AppHubProxy.port}' : appHubBase;

class AppHubProxy {
  AppHubProxy._();

  static HttpServer? _server;
  static int _port = kAppHubProxyPort;

  /// 当前上游。relay 链路建链且 Host 声明 `remote.apphub.proxy.v1` 时,
  /// `RelayHostLink` 把它切成 `RemoteAppHubUpstream`(市场/容器流量经
  /// relay RPC 到引擎主机);链路断开/关闭时经 [resetUpstream] 回 Tcp。
  static AppHubUpstream upstream = TcpAppHubUpstream();

  static bool get started => _server != null;
  static int get port => _port;

  /// 回到默认 Tcp 上游(断链/链路关闭时;relay_backend 负责调用)。
  static void resetUpstream() {
    upstream = TcpAppHubUpstream(proxyPort: started ? _port : null);
  }

  /// 进程内只绑一次;main() 里 await,保证任何 open 之前端口已就绪。
  /// 全部端口都被占时静默放弃(消费方经 [appHubProxyBase] 回退旧行为)。
  static Future<void> ensureStarted() async {
    if (_server != null) return;
    for (var attempt = 0; attempt < 20; attempt++) {
      try {
        final server = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          _port,
        );
        _server = server;
        // 绑定成功才带代理端口:Host 头 = 代理自身端口,AppHub 按它拼
        // packageUrl,包下载地址稳定指回代理。
        upstream = TcpAppHubUpstream(proxyPort: _port);
        server.listen(
          (request) {
            unawaited(_forward(request).catchError((_) {
              try {
                request.response.statusCode = HttpStatus.badGateway;
                unawaited(request.response.close());
              } on Object {
                // 客户端已断开,无需也无处应答。
              }
            }));
          },
          onError: (_) {},
          cancelOnError: false,
        );
        return;
      } on SocketException {
        _port++;
      } on Object {
        _port++;
      }
    }
  }

  static Future<void> _forward(HttpRequest request) async {
    try {
      // 剥掉 hop-by-hop 与 host 后原样透传;Host 头由上游按自己的路数
      // 设置(Tcp 指回代理端口,Remote 交 RPC 侧定夺)。
      final stripped = <String, List<String>>{};
      request.headers.forEach((String name, List<String> values) {
        final String lower = name.toLowerCase();
        if (_hopByHop.contains(lower) ||
            lower == HttpHeaders.hostHeader.toLowerCase()) {
          return;
        }
        stripped[name] = List.of(values);
      });
      // 代理缓冲全量请求体再交上游:容器流量(GET/HEAD manifest/包)无体,
      // 零开销;relay 模式下 Dart 侧的 POST 通知(notices)体小,必须完整
      // 到达上游。
      final builder = BytesBuilder(copy: false);
      await request.forEach(builder.add);
      final List<int> body = builder.takeBytes();
      final AppHubUpstreamResponse response = await upstream.send(
        AppHubUpstreamRequest(
          method: request.method,
          path: request.uri.path,
          query: request.uri.query,
          headers: stripped,
          body: body.isEmpty ? null : body,
        ),
      );
      final dynamic sink = request.response;
      sink.statusCode = response.status;
      response.headers.forEach((String name, List<String> values) {
        if (_hopByHop.contains(name.toLowerCase())) return;
        for (final String value in values) {
          sink.headers.add(name, value);
        }
      });
      await response.body.pipe(sink);
    } on Object {
      // 上游失败(断链/不支持/连不上/上游错)统一 502:后台升级检查静默
      // 失败(no-update),市场页报未连接,容器不闪退。
      try {
        request.response.statusCode = HttpStatus.badGateway;
        request.response.headers.contentType = ContentType.text;
        request.response.write('apphub proxy: link down');
        await request.response.close();
      } on Object {
        // 客户端已断开,无处应答。
      }
    }
  }

  static const Set<String> _hopByHop = <String>{
    'connection',
    'keep-alive',
    'proxy-authenticate',
    'proxy-authorization',
    'te',
    'trailer',
    'transfer-encoding',
    'upgrade',
  };
}
