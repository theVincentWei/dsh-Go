// relay 链路的 AppHub 接线(契约 apphub-proxy.v1 §6.2):建链且 Host 声明
// remote.apphub.proxy.v1 时切 Remote 上游、base 指回 7619 代理固定口;
// 不支持/断开/终端失败/关闭都回默认 Tcp + loopback(快速失败「未连接」);
// reconnecting 是暂态,与 SSH mux 自愈对称,保持 Remote 不闪切。

import 'package:dsh_app/notify/apphub_base.dart';
import 'package:dsh_app/notify/apphub_proxy.dart';
import 'package:dsh_app/notify/apphub_upstream.dart';
import 'package:dsh_app/remote/link_status.dart';
import 'package:dsh_app/remote/relay/apphub_upstream_remote.dart';
import 'package:dsh_app/remote/relay/relay_backend.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:dsh_remote/dsh_remote.dart' as remote;
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_relay.dart';

class FakeAppHubUpstream implements AppHubUpstream {
  @override
  Future<AppHubUpstreamResponse> send(AppHubUpstreamRequest request) => Future.error(StateError('not expected'));
}

/// Lets a test push relay states after the connect resolved.
class _StatefulRelay extends FakeRelayBackend {
  _StatefulRelay() : super(user: sampleRelayUser);

  RelayStateCallback? onState;

  @override
  Future<DshClient> connectHost(RelayHost host, {RelayStateCallback? onState}) async {
    this.onState = onState;
    return super.connectHost(host, onState: onState);
  }
}

void main() {
  late _StatefulRelay relay;
  RelayHostLink? link;

  setUp(() async {
    relay = _StatefulRelay();
    // 绑定代理固定口(7619 或顺延),appHubProxyBase 才是代理口。
    await AppHubProxy.ensureStarted();
    // 故意摆一个「别家链路」的 base,验证切换与回退都真实生效。
    appHubBase = 'http://127.0.0.1:1';
  });

  tearDown(() async {
    await link?.close();
    AppHubProxy.resetUpstream();
    resetAppHubBase();
  });

  RelayHostLink makeLink({AppHubUpstream? Function(DshClient client)? factory}) {
    return RelayHostLink(
      backend: relay,
      hostId: 'mac',
      resolveHost: () async => sampleRelayHosts.first,
      backoff: Backoff(initial: const Duration(milliseconds: 5), maxAttempts: 2),
      remoteAppHubUpstream: factory,
    );
  }

  /// 记入 tearDown 生命周期并打开。
  Future<RelayHostLink> openLink(RelayHostLink newLink) async {
    link = newLink;
    await newLink.open();
    return newLink;
  }

  test('建链且 Host 支持 → 上游切 Remote,base 指回代理固定口(契约 §6.2)', () async {
    final remoteUpstream = FakeAppHubUpstream();

    await openLink(makeLink(factory: (_) => remoteUpstream));

    expect(AppHubProxy.upstream, same(remoteUpstream));
    expect(appHubBase, appHubProxyBase);
    expect(Uri.parse(appHubBase).port, greaterThanOrEqualTo(kAppHubProxyPort));
  });

  test('建链但 Host 不支持 → 回默认 Tcp 上游 + loopback base(市场「未连接」现状)', () async {
    await openLink(makeLink(factory: (_) => null));

    expect(AppHubProxy.upstream, isA<TcpAppHubUpstream>());
    expect(appHubBase, kAppHubDefaultBase);
  });

  test('默认工厂:fake client 无 carrier → 同样不切(接线不受测试假件影响)', () async {
    await openLink(makeLink());

    expect(AppHubProxy.upstream, isA<TcpAppHubUpstream>());
    expect(appHubBase, kAppHubDefaultBase);
  });

  test('链路断开(disconnected) → 回默认上游 + loopback base', () async {
    final remoteUpstream = FakeAppHubUpstream();
    await openLink(makeLink(factory: (_) => remoteUpstream));
    expect(AppHubProxy.upstream, same(remoteUpstream));

    relay.onState!(RelayConnectionState.disconnected, null);

    expect(AppHubProxy.upstream, isA<TcpAppHubUpstream>());
    expect(appHubBase, kAppHubDefaultBase);
  });

  test('终端失败(failed) → 回默认上游 + loopback base,等人工重连', () async {
    final remoteUpstream = FakeAppHubUpstream();
    await openLink(makeLink(factory: (_) => remoteUpstream));

    relay.onState!(
      RelayConnectionState.failed,
      const HostLinkError(HostLinkErrorKind.unreachable, 'x'),
    );

    expect(AppHubProxy.upstream, isA<TcpAppHubUpstream>());
    expect(appHubBase, kAppHubDefaultBase);
  });

  test('reconnecting(暂态) → 保持 Remote 上游,隧道自愈不闪切', () async {
    final remoteUpstream = FakeAppHubUpstream();
    await openLink(makeLink(factory: (_) => remoteUpstream));

    relay.onState!(
      RelayConnectionState.reconnecting,
      const HostLinkError(HostLinkErrorKind.unreachable, 'x', retryable: true),
    );

    expect(AppHubProxy.upstream, same(remoteUpstream));
    expect(appHubBase, appHubProxyBase);
  });

  test('close() → 回默认上游 + loopback base', () async {
    final remoteUpstream = FakeAppHubUpstream();
    await openLink(makeLink(factory: (_) => remoteUpstream));
    expect(AppHubProxy.upstream, same(remoteUpstream));

    await link!.close();

    expect(AppHubProxy.upstream, isA<TcpAppHubUpstream>());
    expect(appHubBase, kAppHubDefaultBase);
  });

  test('RemoteAppHubUpstream:未握手 carrier 无能力声明,send 抛 CAPABILITY_NOT_SUPPORTED', () async {
    final carrier = remote.RemoteTunnelCarrier(
      hostId: 'test',
      open: (_) async => throw StateError('no session in this test'),
    );
    final upstream = RemoteAppHubUpstream(remote.RemoteAppHubClient(carrier));
    expect(upstream.supported, isFalse, reason: '未握手的 carrier 没有 capabilities');

    // 客户端本地先拒(能力缺失),语义与 RemoteRpcException 对齐;链路死时
    // 则是 DshClosedException——两者都由代理层统一转 502。
    await expectLater(
      upstream.send(const AppHubUpstreamRequest(method: 'GET', path: '/api/v1/apps')),
      throwsA(isA<remote.RemoteRpcException>()),
    );
  });
}
