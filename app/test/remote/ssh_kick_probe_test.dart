// 回前台 kick 的「探活优先」回归(取代「长后台必死」盲拆):
//
// kick 先 2s 快探——活链路零打扰不重建(Android 真机后台 NAT 常几分钟内
// 不掉,盲拆会让每次亮屏/网络抖动都白断一次,页面空白刷新);死链路探活
// 失败后首跳零等待直连重连,死亡已被确认,再睡退避是纯多余延迟。
import 'package:dsh_app/remote/link_status.dart';
import 'package:dsh_app/remote/ssh/ssh_host_config.dart';
import 'package:dsh_app/remote/ssh/ssh_link.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_ssh.dart';
import 'support/wait.dart';

SshHostLink buildLink({required FakeSshServer server, required FakeConnector connector, Backoff? backoff}) {
  return SshHostLink(
    config: sampleSsh,
    loadSecrets: () async => const SshSecrets(password: 'pw'),
    transportFactory: server.connect,
    connectClient: connector.call,
    backoff:
        backoff ??
        Backoff(
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

  test('kick keeps a live link without churn', () async {
    final link = buildLink(server: server, connector: connector);
    addTearDown(link.close);
    await link.open();
    expect(link.status.phase, HostLinkPhase.connected);
    link.kick();
    // 假传输探活即时成功:留出窗口,期间出现 reconnecting 即为误杀活链路。
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(link.status.phase, HostLinkPhase.connected, reason: 'kick+活链路:不应重建');
    expect(link.currentClient, isNotNull);
    expect(server.transports.length, 1, reason: '全程只有最初那条传输');
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('kick reconnects a dead link via the failed probe', () async {
    final link = buildLink(server: server, connector: connector);
    addTearDown(link.close);
    await link.open();
    expect(link.status.phase, HostLinkPhase.connected);
    server.last.pingOk = false;
    final reconnecting = nextStatus(link, (s) => s.phase == HostLinkPhase.reconnecting, what: '探活失败后重连');
    link.kick();
    await reconnecting;
    await nextStatus(link, (s) => s.isConnected, what: '重建后回到 connected');
    expect(link.currentClient, isNotNull);
    expect(server.transports.length, 2, reason: '旧传输被替换');
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('kick-triggered reconnect skips the first backoff wait', () async {
    // initial 拉大到 600ms:若首跳仍走退避(半随机 300~600ms),kick→恢复
    // 会明显慢于探活失败本身;零等待时 fake 全即时,应在 300ms 内回绿。
    final link = buildLink(
      server: server,
      connector: connector,
      backoff: Backoff(
        initial: const Duration(milliseconds: 600),
        max: const Duration(seconds: 2),
        maxAttempts: null,
      ),
    );
    addTearDown(link.close);
    await link.open();
    expect(link.status.phase, HostLinkPhase.connected);
    server.last.pingOk = false;
    final connected = nextStatus(link, (s) => s.isConnected, what: '零等待重建回绿');
    final sw = Stopwatch()..start();
    link.kick();
    await connected;
    expect(
      sw.elapsed,
      lessThan(const Duration(milliseconds: 300)),
      reason: '确认死亡后的首跳不应再等退避(实测 ${sw.elapsedMilliseconds}ms)',
    );
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('backoff applies again from the second reconnect attempt on', () async {
    // 首跳免等待只给一次:首连失败后必须回到正常退避,否则退化成零间隔
    // 紧密重试循环。initial=250ms → 第二跳等待半随机 125~250ms,断言总耗
    // 时 >100ms;紧密循环会 <50ms 瞬间回绿。
    final link = buildLink(
      server: server,
      connector: connector,
      backoff: Backoff(
        initial: const Duration(milliseconds: 250),
        max: const Duration(seconds: 2),
        maxAttempts: null,
      ),
    );
    addTearDown(link.close);
    await link.open();
    expect(link.status.phase, HostLinkPhase.connected);
    server.last.pingOk = false;
    server.failNext.add(const HostLinkError(HostLinkErrorKind.unreachable, 'refused', retryable: true));
    final connected = nextStatus(link, (s) => s.isConnected, what: '第二次尝试回绿');
    final sw = Stopwatch()..start();
    link.kick();
    await connected;
    expect(
      sw.elapsed,
      greaterThan(const Duration(milliseconds: 100)),
      reason: '首连失败后第二跳必须退避(实测 ${sw.elapsedMilliseconds}ms),零间隔紧密循环是回归',
    );
  }, timeout: const Timeout(Duration(seconds: 20)));
}
