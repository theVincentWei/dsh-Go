/// AppHub 代理的上游抽象(`remote.apphub.proxy.v1` 契约 §6.1)。
///
/// 代理([AppHubProxy],手机侧固定口)每个请求到达时挑一个上游把字节转
/// 出去:
/// * [TcpAppHubUpstream] —— 现行为:直连「当下」的 [appHubBase](SSH 隧道
///   动态口 / 仿真器 adb reverse / 本地);
/// * `RemoteAppHubUpstream`(见 `remote/relay/apphub_upstream_remote.dart`)
///   —— 经 `RemoteAppHubClient` 走 relay RPC(契约 §5)。
///
/// 职责切分:hop-by-hop 与 host 头的剥离、502 兜底都留在代理层;上游只
/// 负责「按自己的路数转出去 + 给回响应」。send 抛出任何异常都算上游失败
/// (连不上 / 断链 / Host 不支持 / 上游错),代理层统一转 502——容器侧
/// 静默 no-update,不闪退。
library;

import 'dart:async';
import 'dart:io';

import 'apphub_base.dart';

/// 代理转给上游的一个请求(headers 已由代理层剥离 hop-by-hop 与 host)。
final class AppHubUpstreamRequest {
  const AppHubUpstreamRequest({
    required this.method,
    required this.path,
    this.query = '',
    this.headers = const <String, List<String>>{},
    this.body,
  });

  final String method;

  /// 以 `/` 开头的原样路径。
  final String path;

  /// 原样查询串,无前导 `?`;空串即无查询。
  final String query;

  /// 保留原始大小写键与多值(Host 头不在此:各上游自设)。
  final Map<String, List<String>> headers;

  /// 完整请求体;null 即无请求体。
  final List<int>? body;
}

/// 上游应答;[body] 由代理层流式 pipe 回客户端,上游实现自行决定缓冲策略
/// (Tcp 流式直通,Remote 是已拼装完整字节的一次性流)。
final class AppHubUpstreamResponse {
  const AppHubUpstreamResponse({
    required this.status,
    required this.headers,
    required this.body,
  });

  final int status;

  /// 多值保留;hop-by-hop 剔除由代理层兜底再做一遍。
  final Map<String, List<String>> headers;
  final Stream<List<int>> body;
}

abstract interface class AppHubUpstream {
  /// 转发一个请求。实现不得吞异常:失败一律抛出,代理层转 502。
  Future<AppHubUpstreamResponse> send(AppHubUpstreamRequest request);
}

/// 现行为上游:直连「当下」的 [appHubBase]。Host 头刻意写成代理自己的
/// `127.0.0.1:<proxyPort>`——AppHub 按请求 Host 拼 packageUrl/iconUrl,
/// 于是包下载地址也稳定指回代理;[proxyPort] 为 null(代理未启动)时不
/// 覆盖,维持裸直连头。
final class TcpAppHubUpstream implements AppHubUpstream {
  TcpAppHubUpstream({this.proxyPort, HttpClient? client}) : _ownedClient = client;

  /// 代理自己的端口(Host 头用);null 则不覆盖 Host(直连 base 默认头)。
  final int? proxyPort;
  HttpClient? _ownedClient;

  @override
  Future<AppHubUpstreamResponse> send(AppHubUpstreamRequest request) async {
    final HttpClient client = _ownedClient ??= HttpClient();
    // 目标 = 当下的 appHubBase + 原样路径/查询;base 是运行时可变的
    // (SSH 每次建链换动态口),所以每个请求都重读。
    final Uri live = Uri.parse(appHubBase);
    final Uri target = live.replace(
      path: request.path,
      query: request.query.isEmpty ? null : request.query,
    );
    final HttpClientRequest upstream = await client.openUrl(request.method, target);
    final int? port = proxyPort;
    if (port != null) {
      upstream.headers.set(HttpHeaders.hostHeader, '127.0.0.1:$port');
    }
    request.headers.forEach((String name, List<String> values) {
      for (final String value in values) {
        upstream.headers.add(name, value);
      }
    });
    final List<int>? body = request.body;
    if (body != null && body.isNotEmpty) {
      // 必须在写字节之前定长:dart:io 一旦开始写体,headers 即不可变。
      upstream.headers.set(HttpHeaders.contentLengthHeader, '${body.length}');
      upstream.add(body);
    }
    final HttpClientResponse upstreamResponse = await upstream.close();
    return AppHubUpstreamResponse(
      status: upstreamResponse.statusCode,
      headers: headersOf(upstreamResponse.headers),
      body: upstreamResponse,
    );
  }
}

/// 把 [HttpHeaders] 拷成普通多值 map(上游实现共用的小工具)。
Map<String, List<String>> headersOf(HttpHeaders headers) {
  final map = <String, List<String>>{};
  headers.forEach((String name, List<String> values) {
    map[name] = List.of(values);
  });
  return map;
}
