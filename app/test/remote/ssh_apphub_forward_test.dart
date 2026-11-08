// AppHub 额外转发(M4):同一条 SSH 连接上的第二个本地转发,把引擎主机上
// 的 AppHub 端口带给真机。链路建链后探测 → 绑定 → 发布 base;主机没有
// AppHub 时保持 loopback 默认。市场页/通知轮询/启动器都读同一个 base。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_app/notify/apphub_base.dart';
import 'package:dsh_app/remote/link_status.dart';
import 'package:dsh_app/remote/ssh/ssh_host_config.dart';
import 'package:dsh_app/remote/ssh/ssh_link.dart';
import 'package:dsh_app/remote/ssh/ssh_transport.dart';
import 'package:dsh_app/remote/ssh/ssh_tunnel.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_ssh.dart';

/// 轮询等待:extra forward 的探测/绑定在链路 open() 之后异步完成。
Future<void> waitUntil(
  bool Function() ok, {
  required String what,
  Duration timeout = const Duration(seconds: 3),
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (!ok()) {
    if (DateTime.now().isAfter(deadline)) fail('等待超时：$what');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// 经本地转发口收发一圈:写进去的字节经 SSH 通道回显出来。
Future<String> roundTrip(int port, String payload) async {
  final Socket socket = await Socket.connect('127.0.0.1', port);
  final Completer<String> done = Completer<String>();
  late final StreamSubscription<Uint8List> sub;
  sub = socket.listen((List<int> data) => done.complete(utf8.decode(data)));
  socket.add(utf8.encode(payload));
  try {
    return await done.future.timeout(const Duration(seconds: 2));
  } finally {
    await sub.cancel();
    socket.destroy();
  }
}

void main() {
  tearDown(resetAppHubBase);

  test('engine: the extra forward is its own listener whose channels hit the extra port', () async {
    final FakeRemote remote = FakeRemote();
    remote.pid = 1000; // FakeTransport:引擎端口只有在进程活着时才可转发。
    final FakeTransport transport = FakeTransport(remote)..extraPort = kAppHubRemotePort;
    final LocalSshTunnel tunnel = LocalSshTunnel(
      SshTunnelEngine(transportFactory: (_, _) async => transport),
    );
    addTearDown(tunnel.close);
    await tunnel.connect(
      const SshConnectParams(
        host: '127.0.0.1',
        port: 22,
        username: 'u',
        auth: SshAuthMethod.password,
        secrets: SshSecrets(password: 'x'),
      ),
      (_) => true,
    );
    final int enginePort = await tunnel.setEndpoint(remote.port);
    final int apphubPort = await tunnel.setExtraEndpoint(kAppHubRemotePort);
    // 两个转发互不挤占:各自的 loopback 口、各自的远端端点。
    expect(apphubPort, isNot(enginePort));

    expect(await roundTrip(apphubPort, 'apphub'), 'apphub');
    expect(await roundTrip(enginePort, 'dsh'), 'dsh');
    expect(transport.tunnels.where((t) => t.$2 == kAppHubRemotePort), hasLength(1));
    expect(transport.tunnels.where((t) => t.$2 == remote.port), hasLength(1));
    // 重新 setExtraEndpoint 幂等:监听口不变。
    expect(await tunnel.setExtraEndpoint(kAppHubRemotePort), apphubPort);
  });

  test('link: a host running AppHub gets its port carried and published as the base', () async {
    final FakeSshServer server = FakeSshServer();
    server.extraPort = kAppHubRemotePort;
    final SshHostLink l = link(server);
    await l.open();

    await waitUntil(
      () => Uri.parse(appHubBase).port != Uri.parse(kAppHubDefaultBase).port,
      what: 'AppHub base 指向额外转发端口',
    );
    // 本地随机口 → 主机 7610,数据真的落到达。
    expect(await roundTrip(Uri.parse(appHubBase).port, 'apphub'), 'apphub');
    expect(
      server.last.tunnels.where((t) => t.$2 == kAppHubRemotePort),
      isNotEmpty,
    );
  });

  test('link: a host without AppHub keeps the loopback default base', () async {
    final FakeSshServer server = FakeSshServer(); // extraPort 为 null:7610 拒连
    final SshHostLink l = link(server);
    await l.open();

    // 探测已经打到 7610 且被拒:base 不动。
    await waitUntil(
      () => server.last.tunnels.any((t) => t.$2 == kAppHubRemotePort),
      what: 'AppHub 端口探测发生',
    );
    expect(appHubBase, kAppHubDefaultBase);
  });

  test('link: closing the link resets the base to loopback', () async {
    final FakeSshServer server = FakeSshServer();
    server.extraPort = kAppHubRemotePort;
    final SshHostLink l = link(server);
    await l.open();
    await waitUntil(
      () => Uri.parse(appHubBase).port != Uri.parse(kAppHubDefaultBase).port,
      what: 'AppHub base 指向额外转发端口',
    );

    // 直接关链路(keepalive/重连一并停):base 回默认,快速失败。
    await l.close();
    expect(appHubBase, kAppHubDefaultBase);
  });
}

SshHostLink link(FakeSshServer server) {
  final connector = FakeConnector();
  final SshHostLink l = SshHostLink(
    config: sampleSsh,
    loadSecrets: () async => const SshSecrets(password: 'pw'),
    transportFactory: server.connect,
    connectClient: connector.call,
    backoff: Backoff(
      initial: const Duration(milliseconds: 10),
      max: const Duration(milliseconds: 40),
    ),
    keepAliveInterval: const Duration(milliseconds: 20),
    keepAliveTimeout: const Duration(milliseconds: 20),
  );
  addTearDown(l.close);
  return l;
}
