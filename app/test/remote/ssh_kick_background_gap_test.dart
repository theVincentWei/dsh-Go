// 回前台 kick 的「长后台默认必死」策略回归:
//
// ≥15s 的后台(进程冻结、NAT 掉线,socket 基本必死)不再花探活等待,kick
// 直接进重连;短后台仍先快探,保住还活着的链路——快速切 App 不应触发重建。
import 'package:dsh_app/remote/link_status.dart';
import 'package:dsh_app/remote/ssh/ssh_host_config.dart';
import 'package:dsh_app/remote/ssh/ssh_link.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_ssh.dart';
import 'support/wait.dart';

SshHostLink buildLink({
  required FakeSshServer server,
  required FakeConnector connector,
  Duration? Function()? backgroundGap,
}) {
  return SshHostLink(
    config: sampleSsh,
    loadSecrets: () async => const SshSecrets(password: 'pw'),
    transportFactory: server.connect,
    connectClient: connector.call,
    backgroundGap: backgroundGap,
    backoff: Backoff(
      initial: const Duration(milliseconds: 2),
      max: const Duration(milliseconds: 4),
      maxAttempts: null,
    ),
  );
}

void main() {
  late FakeSshServer server;
  late FakeConnector connector;

  setUp(() {
    server = FakeSshServer();
    connector = FakeConnector();
  });

  test('kick after a long background reconnects without probing a live link', () async {
    final link = buildLink(server: server, connector: connector, backgroundGap: () => const Duration(seconds: 20));
    addTearDown(link.close);
    await link.open();
    expect(link.status.phase, HostLinkPhase.connected);
    // 老链路明明活着(FakeTransport 默认 pingOk),长后台判定必死:kick 应
    // 立即进重连而不是等探活——reconnecting 状态本身就是「没探活」的证据。
    final reconnecting = nextStatus(link, (s) => s.phase == HostLinkPhase.reconnecting, what: '长后台 kick 直接重连');
    link.kick();
    await reconnecting;
    await nextStatus(link, (s) => s.isConnected, what: '重建后回到 connected');
    expect(link.currentClient, isNotNull);
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('kick after a short background keeps a live link without churn', () async {
    final link = buildLink(server: server, connector: connector, backgroundGap: () => const Duration(seconds: 3));
    addTearDown(link.close);
    await link.open();
    expect(link.status.phase, HostLinkPhase.connected);
    link.kick();
    // 探活(假传输即时成功)后应保持 connected;留出足够时间窗,若出现
    // reconnecting 即为误杀活链路。
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(link.status.phase, HostLinkPhase.connected, reason: '短后台+活链路:kick 不应重建');
    expect(link.currentClient, isNotNull);
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('kick after a short background still reconnects a dead link via the probe', () async {
    final link = buildLink(server: server, connector: connector, backgroundGap: () => const Duration(seconds: 3));
    addTearDown(link.close);
    await link.open();
    expect(link.status.phase, HostLinkPhase.connected);
    server.last.pingOk = false;
    final reconnecting = nextStatus(link, (s) => s.phase == HostLinkPhase.reconnecting, what: '短后台探活失败后重连');
    link.kick();
    await reconnecting;
    await nextStatus(link, (s) => s.isConnected, what: '重建后回到 connected');
    expect(link.currentClient, isNotNull);
  }, timeout: const Timeout(Duration(seconds: 20)));
}
