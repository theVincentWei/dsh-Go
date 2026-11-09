// AppHub 额外转发(M4):同一条 SSH 连接上的第二个本地转发,把引擎主机上
// 的 AppHub 端口带给真机,本地口钉死在与远端相同的 7610 上——小程序硬编码
// `http://127.0.0.1:7610`(网关是后端唯一对外口),与仿真器 adb reverse
// tcp:7610 同款语义。链路建链后探测 → 绑定;主机没有 AppHub 时保持 loopback
// 默认;base 不再被改写,App 自己读的也是这个默认值。

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

/// 反复试 roundTrip 直到转发监听真正开始应答(探测打出的 tunnel 记录
/// 早于监听绑定,按 tunnels 计数等会假阳性)。
Future<void> waitRoundTrip(int port, String payload) async {
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 3));
  while (true) {
    try {
      await roundTrip(port, payload);
      return;
    } catch (_) {}
    if (DateTime.now().isAfter(deadline)) fail('等待转发监听应答：$port');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// 抓一个空闲 loopback 口再放掉:测试里的「固定口」,不碰真 7610。
Future<int> grabFreePort() async {
  final ServerSocket probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final int port = probe.port;
  await probe.close();
  return port;
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

  test('engine: a pinned extra local port binds exactly there', () async {
    final FakeRemote remote = FakeRemote();
    remote.pid = 1000;
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
    await tunnel.setEndpoint(remote.port);
    final int pinned = await grabFreePort();

    final int bound = await tunnel.setExtraEndpoint(kAppHubRemotePort, localPort: pinned);
    // 绑在指定口上(小程序硬编码 127.0.0.1:7610 依赖这一点),数据落到达。
    expect(bound, pinned);
    await waitRoundTrip(pinned, 'apphub');
    // 幂等:同远端再问,返回同一监听。
    expect(await tunnel.setExtraEndpoint(kAppHubRemotePort), pinned);
  });

  test('link: a host running AppHub gets a fixed local forward, base stays loopback', () async {
    final FakeSshServer server = FakeSshServer();
    server.extraPort = kAppHubRemotePort;
    final int pinned = await grabFreePort();
    final SshHostLink l = link(server, appHubLocalPort: pinned);
    await l.open();

    // 固定口上数据真的落到达;base 不被改写——小程序硬编码 127.0.0.1:7610
    // 与 App 自己读的是同一个 loopback 默认值。
    await waitRoundTrip(pinned, 'apphub');
    expect(appHubBase, kAppHubDefaultBase);
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

  test('link: closing the link frees the pinned forward', () async {
    final FakeSshServer server = FakeSshServer();
    server.extraPort = kAppHubRemotePort;
    final int pinned = await grabFreePort();
    final SshHostLink l = link(server, appHubLocalPort: pinned);
    await l.open();
    await waitRoundTrip(pinned, 'apphub');

    // 直接关链路(keepalive/重连一并停):固定口随监听关闭一起释放。
    await l.close();
    await expectLater(roundTrip(pinned, 'x'), throwsA(anything));
  });
}

SshHostLink link(FakeSshServer server, {int? appHubLocalPort}) {
  final connector = FakeConnector();
  final SshHostLink l = SshHostLink(
    config: sampleSsh,
    loadSecrets: () async => const SshSecrets(password: 'pw'),
    transportFactory: server.connect,
    connectClient: connector.call,
    appHubLocalPort: appHubLocalPort,
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
