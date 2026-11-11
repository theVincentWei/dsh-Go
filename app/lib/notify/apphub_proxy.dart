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
/// 修法:原生容器永远只认这个固定端口;代理在每个请求到达时用「当下」的
/// [appHubBase] 转发字节,隧道怎么重连都无所谓。转发刻意保留代理自己的
/// Host 头——AppHub 按 Host 拼 packageUrl,于是包下载地址也稳定指向代理。
/// 链路断了代理回 502:后台升级检查静默失败(no-update),不崩容器。
library;

import 'dart:async';
import 'dart:io';

import 'apphub_base.dart';

/// 代理固定端口起点;被占则顺延(最多 20 个),避开 adb reverse 之类。
const int kAppHubProxyPort = 7619;

/// 原生容器应使用的 AppHub base:代理活着就是代理,否则退回动态 base
/// (与旧行为一致)。
String get appHubProxyBase =>
    AppHubProxy.started ? 'http://127.0.0.1:${AppHubProxy.port}' : appHubBase;

class AppHubProxy {
  AppHubProxy._();

  static HttpServer? _server;
  static HttpClient? _client;
  static int _port = kAppHubProxyPort;

  static bool get started => _server != null;
  static int get port => _port;

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
    final HttpClient client = _client ??= HttpClient();
    try {
      // 目标 = 当下的 appHubBase + 原样路径/查询;Host 保持代理端口,
      // 让服务端把 packageUrl 也拼回代理(下载链路同样稳定)。
      final Uri live = Uri.parse(appHubBase);
      final Uri target = live.replace(
        path: request.uri.path,
        query: request.uri.query.isEmpty ? null : request.uri.query,
      );
      final HttpClientRequest upstream = await client.openUrl(
        request.method,
        target,
      );
      upstream.headers.set(HttpHeaders.hostHeader, '127.0.0.1:$_port');
      request.headers.forEach((String name, List<String> values) {
        if (_hopByHop.contains(name.toLowerCase()) ||
            name.toLowerCase() == HttpHeaders.hostHeader.toLowerCase()) {
          return;
        }
        for (final String value in values) {
          upstream.headers.add(name, value);
        }
      });
      await request.drain<void>();
      final HttpClientResponse upstreamResponse = await upstream.close();
      final dynamic response = request.response;
      response.statusCode = upstreamResponse.statusCode;
      upstreamResponse.headers.forEach((String name, List<String> values) {
        if (_hopByHop.contains(name.toLowerCase())) return;
        for (final String value in values) {
          response.headers.add(name, value);
        }
      });
      await upstreamResponse.pipe(response);
    } on Object {
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
