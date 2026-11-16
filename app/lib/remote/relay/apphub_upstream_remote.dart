/// relay 链路的 AppHub 上游(`remote.apphub.proxy.v1` 契约 §6.1 的 Remote
/// 实现):把代理收到的请求经 [RemoteAppHubClient] 走
/// `harness.remote.apphub.request` RPC,直达引擎主机上写死的
/// `127.0.0.1:7610` AppHub 网关——主机侧没有动态端口问题,relay 下小程序
/// 市场从此可用。
///
/// send 失败一律原样抛出(断链 `DshClosedException`、Host 不支持
/// `CAPABILITY_NOT_SUPPORTED`、上游错 `APPHUB_*`),代理层统一转 502:
/// 容器静默 no-update 不闪退,市场页报「未连接」。
library;

import 'dart:async';

import 'package:dsh_remote/dsh_remote.dart';

import '../../notify/apphub_upstream.dart';

final class RemoteAppHubUpstream implements AppHubUpstream {
  RemoteAppHubUpstream(this._client);

  final RemoteAppHubClient _client;

  /// Host 声明 `remote.apphub.proxy.v1` 才可用;relay 接线据此决定切不切。
  bool get supported => _client.supported;

  @override
  Future<AppHubUpstreamResponse> send(AppHubUpstreamRequest request) async {
    final AppHubHttpResponse response = await _client.request(
      method: request.method,
      path: request.path,
      query: request.query.isEmpty ? null : request.query,
      headers: _singleValued(request.headers),
      body: request.body,
    );
    return AppHubUpstreamResponse(
      status: response.status,
      headers: <String, List<String>>{
        for (final MapEntry<String, String> entry in response.headers.entries) entry.key: <String>[entry.value],
      },
      // RPC 侧已拼装完整字节;包一层单 chunk 流,代理层照常 pipe。
      body: Stream<List<int>>.value(response.body),
    );
  }
}

/// RPC headers 是单值 map:键按契约 §2.1 小写,多值按 HTTP 惯例逗号连接。
Map<String, String> _singleValued(Map<String, List<String>> headers) => <String, String>{
  for (final MapEntry<String, List<String>> entry in headers.entries) entry.key.toLowerCase(): entry.value.join(','),
};

/// relay 接线(RelayHostLink 建链)用的默认工厂:carrier 缺席、Host 未声明
/// 能力时返回 null,调用方据此回退 Tcp 上游 + loopback base(市场显示
/// 「未连接」,维持契约 §1 的现状语义)。
AppHubUpstream? defaultRemoteAppHubUpstream(DshClient client) {
  final RemoteTunnelCarrier? carrier = client.remoteCarrier;
  if (carrier == null) return null;
  final RemoteAppHubUpstream upstream = RemoteAppHubUpstream(RemoteAppHubClient(carrier));
  return upstream.supported ? upstream : null;
}
