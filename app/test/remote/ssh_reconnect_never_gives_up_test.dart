// iOS 后台切回前台「SSH 断了不会自己重试,只能杀 App 重进」的回归:
//
// 1) SshHostLink 的重连退避默认不封顶——旧实现 8 次预算(约 2-4 分钟)用完
//    就进 failed 永久躺平,主机/网络恢复后也等不到;回前台 kick 与 keepalive
//    本来就齐,配上限不封顶后恢复闭环。
// 2) 认证超时是终态(非重试),不会被「退避不封顶」放大成无提示静默重试
//    (见 ssh_auth_abort_test.dart)。
import 'package:dsh_app/remote/link_status.dart';
import 'package:dsh_app/remote/ssh/ssh_host_config.dart';
import 'package:dsh_app/remote/ssh/ssh_link.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_ssh.dart';
import 'support/wait.dart';

void main() {
  late FakeSshServer server;
  late FakeConnector connector;

  setUp(() {
    server = FakeSshServer();
    connector = FakeConnector();
  });

  test('reconnect keeps trying past the old 8-attempt budget and recovers by itself', () async {
    // 快退避 + 不封顶(生产默认语义),把十几次失败压缩到毫秒级。
    final link = SshHostLink(
      config: sampleSsh,
      loadSecrets: () async => const SshSecrets(password: 'pw'),
      transportFactory: server.connect,
      connectClient: connector.call,
      backoff: Backoff(
        initial: const Duration(milliseconds: 2),
        max: const Duration(milliseconds: 4),
        maxAttempts: null,
      ),
      keepAliveInterval: const Duration(milliseconds: 20),
      keepAliveTimeout: const Duration(milliseconds: 20),
    );
    addTearDown(link.close);
    await link.open();
    for (var i = 0; i < 15; i++) {
      server.failNext.add(const HostLinkError(HostLinkErrorKind.unreachable, 'down', retryable: true));
    }
    final reconnecting = nextStatus(link, (s) => s.phase == HostLinkPhase.reconnecting, what: 'SSH 掉了开始重连');
    server.last.drop();
    await reconnecting;
    await nextStatus(
      link,
      (s) => s.phase == HostLinkPhase.reconnecting && s.attempt > 8,
      what: '过了旧 8 次预算仍在重连',
    );
    expect(link.status.phase, HostLinkPhase.reconnecting, reason: '旧 8 次预算不再让链路永久 failed');
    // 失败用尽(主机恢复)后不需要任何手动动作,链路自己回到 connected。
    await nextStatus(link, (s) => s.isConnected, what: '主机恢复后自动连回');
    expect(link.currentClient, isNotNull);
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('the default reconnect backoff of an SSH link never gives up', () async {
    final link = SshHostLink(
      config: sampleSsh,
      loadSecrets: () async => const SshSecrets(password: 'pw'),
      transportFactory: server.connect,
      connectClient: connector.call,
    );
    addTearDown(link.close);
    final backoff = link.debugBackoff;
    for (var i = 0; i < 100; i++) {
      expect(backoff.exhausted, isFalse, reason: '第 ${i + 1} 次重连前不得判定放弃');
      expect(backoff.next(), lessThanOrEqualTo(const Duration(seconds: 30)));
    }
    expect(backoff.exhausted, isFalse, reason: '退避不封顶:主机恢复后永远等得到下一次重连');
  });
}
