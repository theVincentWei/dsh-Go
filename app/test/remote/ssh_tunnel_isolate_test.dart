// IsolateSshTunnel 的跨 isolate 管道冒烟:连接失败要以带 retryable 的
// HostLinkError 形态穿过 isolate 边界,worker 存活且后续操作正常应答。

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
}
