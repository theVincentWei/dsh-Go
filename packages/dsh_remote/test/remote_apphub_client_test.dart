// RemoteAppHubClient round trips against the fake Host (contract
// docs/apphub-proxy.v1.md §5/§7 and the dart-dev implementation appendix):
// inline round trips, the two-step large-body uplink (512 KiB chunks plus a
// four-field body reference the Host reassembles byte-exactly), chunked
// large-response downlink pulled as raw bytes by index, capability gating
// and verbatim rpc.error mapping. Real REST, Control/Relay WebSockets, Noise
// and RemoteRpcClient throughout.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dsh_remote/dsh_remote.dart';
import 'package:dsh_remote/src/util/bytes.dart' show uuidV7;
import 'package:test/test.dart';

import 'support/fake_remote.dart';

final _random = Random(7);

Uint8List _randomBytes(int length) =>
    Uint8List.fromList(List<int>.generate(length, (_) => _random.nextInt(256)));

void main() {
  late FakeRemoteServer server;
  late FakeRemoteHost host;
  late RemoteAccount account;
  late DshClient client;
  late RemoteTunnelCarrier carrier;
  late RemoteAppHubClient hub;

  int rpcCalls(String method) => host.rpcMethods.where((method1) => method1 == method).length;

  setUp(() async {
    server = await FakeRemoteServer.start();
    host = await FakeRemoteHost.start(server);
    host.handlers['session/list'] = (_) => {
      'ok': true,
      'value': {'items': <Object?>[]},
    };
    host.capabilities = [
      'transport.relay',
      'harness.remote.v3',
      'harness.remote.transfer.v1',
      appHubProxyCapability,
    ];
    account = RemoteAccount(secrets: MemorySecretStore(), serverUrl: server.url);
    await account.loginWithPassword(FakeRemoteServer.account, FakeRemoteServer.password);
    client = await account.connectHost((await account.listHosts()).single);
    carrier = client.remoteCarrier!;
    hub = RemoteAppHubClient(carrier);
  });

  tearDown(() async {
    await account.close();
    await host.close();
    await server.close();
    expect(server.protocolErrors, isEmpty);
  });

  test('supported mirrors the describe capabilities', () {
    expect(hub.supported, isTrue);
  });

  test('inline uplink and inline downlink round trip', () async {
    host.appHub = (request) async => (201, {'content-type': 'application/json'}, utf8.encode('{"id":7}'));
    final response = await hub.request(
      method: 'POST',
      path: '/api/v1/apps',
      query: 'since=12',
      headers: {'Accept': 'application/json'},
      body: utf8.encode('{"name":"demo"}'),
    );
    expect(response.status, 201);
    expect(response.headers, {'content-type': 'application/json'});
    expect(utf8.decode(response.body), '{"id":7}');
    // What the Host decoded out of the params.
    expect(host.appHubCalls, hasLength(1));
    final received = host.appHubCalls.single;
    expect(received.method, 'POST');
    expect(received.path, '/api/v1/apps');
    expect(received.query, 'since=12');
    expect(received.headers, containsPair('accept', 'application/json')); // keys lower-cased
    expect(utf8.decode(received.body), '{"name":"demo"}');
    // No transfer machinery on the inline path.
    expect(host.rpcMethods.where((method) => method.startsWith('harness.remote.transfer.')), isEmpty);
    expect(host.appHubParams.single['body'], {'kind': 'inline', 'data': base64Encode(utf8.encode('{"name":"demo"}'))});
  });

  test('large request bodies: two-step uplink, the Host reassembles exact bytes', () async {
    final payload = _randomBytes(600 * 1024); // 512 KiB + 88 KiB across two chunks
    host.appHub = (request) async => (200, const <String, String>{}, <int>[]);
    final response = await hub.request(method: 'PUT', path: '/api/v1/bundles/demo', body: payload);
    expect(response.status, 200);
    expect(response.body, isEmpty);
    // Step 1: the raw-body write stream.
    expect(rpcCalls('harness.remote.transfer.open'), 1);
    expect(rpcCalls('harness.remote.transfer.chunk'), 2);
    expect(rpcCalls('harness.remote.transfer.commit'), 1);
    // Step 2: exactly one main RPC referencing the resource.
    expect(rpcCalls(appHubProxyRpc), 1);
    expect(rpcCalls('harness.remote.transfer.read'), 0);
    // The four-field body reference on the main RPC.
    final reference = host.appHubParams.single['body']! as Map;
    expect(reference['kind'], 'transfer');
    expect(reference['transferId'], isA<String>());
    expect(reference['totalBytes'], payload.length);
    expect(reference['totalChunks'], 2);
    // Byte-exact reassembly on the Host.
    expect(host.appHubCalls.single.method, 'PUT');
    expect(host.appHubCalls.single.path, '/api/v1/bundles/demo');
    expect(host.appHubCalls.single.body, payload);
    // Let the unawaited close land before counting it.
    await client.listSessions();
    expect(rpcCalls('harness.remote.transfer.close'), 1);
    expect(host.connections.values.single.transfers, isEmpty);
  });

  test('large responses: a transfer reference pulled as raw bytes by index', () async {
    final payload = _randomBytes(700 * 1024 + 3); // 2 chunks: exact edge + remainder
    host.appHub = (request) async => (200, {'content-type': 'application/octet-stream'}, payload);
    final response = await hub.request(method: 'GET', path: '/api/v1/apps/7/icon');
    expect(response.status, 200);
    expect(response.headers, {'content-type': 'application/octet-stream'});
    expect(response.body, payload);
    expect(rpcCalls(appHubProxyRpc), 1);
    expect(rpcCalls('harness.remote.transfer.read'), 2);
    // Let the unawaited close land before counting it.
    await client.listSessions();
    expect(rpcCalls('harness.remote.transfer.close'), 1);
    expect(host.connections.values.single.transfers, isEmpty);
  });

  test('a HEAD answer with kind:none yields an empty body', () async {
    host.appHub = (request) async => (204, {'x-mark': 'a'}, <int>[]);
    final response = await hub.request(method: 'HEAD', path: '/api/v1/apps/7');
    expect(response.status, 204);
    expect(response.headers, {'x-mark': 'a'});
    expect(response.body, isEmpty);
    expect(host.appHubCalls.single.method, 'HEAD');
    expect(host.appHubParams.single['body'], {'kind': 'none'});
  });

  test('local validation refuses bad methods and paths without any RPC', () async {
    Matcher code(String value) => isA<RemoteRpcException>().having((error) => error.code, 'code', value);
    final before = host.rpcMethods.length;
    await expectLater(hub.request(method: 'PATCH', path: '/api/v1/apps'), throwsA(code('UNSUPPORTED_METHOD')));
    await expectLater(hub.request(method: 'GET', path: 'api/v1/apps'), throwsA(code('APPHUB_BAD_PATH')));
    await expectLater(hub.request(method: 'GET', path: '/api/../secret'), throwsA(code('APPHUB_BAD_PATH')));
    await expectLater(hub.request(method: 'GET', path: '/api/v1', query: '?a=1'), throwsA(code('APPHUB_BAD_PATH')));
    await expectLater(hub.request(method: 'GET', path: '/api/v1\n'), throwsA(code('APPHUB_BAD_PATH')));
    expect(host.rpcMethods.length, before);
    expect(host.appHubCalls, isEmpty);
  });

  test('a Host without the capability: supported=false, refused locally', () async {
    final quietServer = await FakeRemoteServer.start();
    final quietHost = await FakeRemoteHost.start(quietServer);
    final quietAccount = RemoteAccount(secrets: MemorySecretStore(), serverUrl: quietServer.url);
    await quietAccount.loginWithPassword(FakeRemoteServer.account, FakeRemoteServer.password);
    final quietClient = await quietAccount.connectHost((await quietAccount.listHosts()).single);
    final quietHub = RemoteAppHubClient(quietClient.remoteCarrier!);
    expect(quietHub.supported, isFalse);
    await expectLater(
      quietHub.request(method: 'GET', path: '/api/v1/apps'),
      throwsA(isA<RemoteRpcException>().having((error) => error.code, 'code', 'CAPABILITY_NOT_SUPPORTED')),
    );
    expect(quietHost.rpcMethods.where((method) => method == appHubProxyRpc), isEmpty);
    await quietClient.close();
    await quietAccount.close();
    await quietHost.close();
    await quietServer.close();
    expect(quietServer.protocolErrors, isEmpty);
  });

  test('a lost link throws DshClosedException', () async {
    await client.close();
    expect(hub.supported, isTrue); // last-known capabilities survive the drop
    await expectLater(hub.request(method: 'GET', path: '/api/v1/apps'), throwsA(isA<DshClosedException>()));
  });

  test('Host rpc.error maps verbatim (APPHUB_UNREACHABLE, retryable)', () async {
    host.appHubValue =
        (request) async => throw const FakeAppHubRpcError('APPHUB_UNREACHABLE', 'upstream refused', retryable: true);
    await expectLater(
      hub.request(method: 'GET', path: '/api/v1/apps'),
      throwsA(
        isA<RemoteRpcException>()
            .having((error) => error.code, 'code', 'APPHUB_UNREACHABLE')
            .having((error) => error.retryable, 'retryable', isTrue),
      ),
    );
  });

  test('malformed response descriptors are rejected without any reads', () async {
    Matcher protocol() => isA<DshProtocolException>();
    // Non-UUID transferId.
    host.appHubValue = (request) async => {
      'status': 200,
      'headers': <String, String>{},
      'body': {'kind': 'transfer', 'transferId': 'not-a-uuid', 'totalBytes': 10, 'totalChunks': 1},
    };
    await expectLater(hub.request(method: 'GET', path: '/x'), throwsA(protocol()));
    // totalChunks inconsistent with ceil(totalBytes / 512 KiB).
    host.appHubValue = (request) async => {
      'status': 200,
      'headers': <String, String>{},
      'body': {'kind': 'transfer', 'transferId': uuidV7(), 'totalBytes': 10, 'totalChunks': 2},
    };
    await expectLater(hub.request(method: 'GET', path: '/x'), throwsA(protocol()));
    // Oversized inline body (> 64 KiB decoded).
    host.appHubValue = (request) async => {
      'status': 200,
      'headers': <String, String>{},
      'body': {'kind': 'inline', 'data': base64Encode(_randomBytes(appHubInlineBytes + 1))},
    };
    await expectLater(hub.request(method: 'GET', path: '/x'), throwsA(protocol()));
    // Unknown body kind.
    host.appHubValue = (request) async => {'status': 200, 'headers': <String, String>{}, 'body': {'kind': 'mystery'}};
    await expectLater(hub.request(method: 'GET', path: '/x'), throwsA(protocol()));
    // Validation rejects before the read loop starts; the async transfer
    // cleanup still lands in the background but never reads.
    expect(rpcCalls('harness.remote.transfer.read'), 0);
  });

  test('a non-canonical inline body is rejected', () async {
    host.appHubValue = (request) async => {
      'status': 200,
      'headers': <String, String>{},
      'body': {'kind': 'inline', 'data': '${base64Encode([1, 2])}==='},
    };
    await expectLater(hub.request(method: 'GET', path: '/x'), throwsA(isA<DshProtocolException>()));
  });
}
