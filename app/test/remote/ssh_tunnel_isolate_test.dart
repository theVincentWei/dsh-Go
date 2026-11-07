// IsolateSshTunnel 的跨 isolate 管道冒烟:连接失败要以带 retryable 的
// HostLinkError 形态穿过 isolate 边界,worker 存活且后续操作正常应答。

import 'dart:async';

import 'package:dsh_app/remote/link_status.dart';
import 'package:dsh_app/remote/ssh/ssh_host_config.dart';
import 'package:dsh_app/remote/ssh/ssh_transport.dart';
import 'package:dsh_app/remote/ssh/ssh_tunnel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('isolate tunnel surfaces a connection refusal as a retryable HostLinkError', () async {
    final tunnel = IsolateSshTunnel();
    addTearDown(tunnel.close);
    await expectLater(
      tunnel.connect(
        SshConnectParams(
          host: '127.0.0.1',
          port: 1,
          username: 'u',
          auth: SshAuthMethod.password,
          secrets: const SshSecrets(password: 'x'),
        ),
        (_) => true,
      ),
      throwsA(
        isA<HostLinkError>()
            .having((e) => e.kind, 'kind', HostLinkErrorKind.unreachable)
            .having((e) => e.retryable, 'retryable', isTrue),
      ),
    );
    // Worker 还活着:请求/应答管道正常,尚无传输所以 ping 应答 false。
    expect(await tunnel.ping(timeout: const Duration(seconds: 2)), isFalse);
  });

  test('probeTunnel returns its record across the isolate boundary (no live transport)', () async {
    final tunnel = IsolateSshTunnel();
    addTearDown(tunnel.close);
    // 没有已连接的传输:_waitTransport 超时,引擎把超时装进 record 返回。
    // 回归:真机路径上 record 曾被 `as Map` 硬转,真机构建必炸而进程内测试全绿。
    final probe = await tunnel.probeTunnel(40000, timeout: const Duration(milliseconds: 300));
    expect(probe.refused, isFalse);
    expect(probe.error, isA<TimeoutException>());
  });
}
