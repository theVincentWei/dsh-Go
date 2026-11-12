// AppHubUpstream 抽象与 TcpAppHubUpstream(契约 apphub-proxy.v1 §6.1):
// 目标 = 「当下」的 appHubBase,Host 头 = 代理自身端口,方法/路径/查询/
// 头/体全量转出,响应 status/headers/body 原样带回。

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/notify/apphub_base.dart';
import 'package:dsh_app/notify/apphub_upstream.dart';
import 'package:flutter_test/flutter_test.dart';

/// 假 AppHub:记录每个请求,回一句固定 JSON。
class FakeAppHub {
  FakeAppHub();

  late final HttpServer server;
  late final String base;
  final requests = <({String method, String path, String query, String? host, String? body})>[];
  final seenHeaders = <String, List<String>>{};

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      requests.add((
        method: request.method,
        path: request.uri.path,
        query: request.uri.query,
        host: request.headers.value(HttpHeaders.hostHeader),
        body: body.isEmpty ? null : body,
      ));
      seenHeaders.clear();
      request.headers.forEach((name, values) => seenHeaders[name] = values);
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.add('x-apphub', 'one');
      request.response.headers.add('x-apphub', 'two');
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"ok":true}');
      await request.response.close();
    });
  }

  Future<void> stop() => server.close(force: true);
}

void main() {
  late FakeAppHub hub;
  setUp(() async {
    hub = FakeAppHub();
    await hub.start();
    appHubBase = hub.base;
  });
  tearDown(() async {
    resetAppHubBase();
    await hub.stop();
  });

  group('TcpAppHubUpstream', () {
    test('GET 转出方法/路径/查询,Host 头指回代理端口,自定义头透传', () async {
      final upstream = TcpAppHubUpstream(proxyPort: 7619);
      final response = await upstream.send(AppHubUpstreamRequest(
        method: 'GET',
        path: '/api/v1/apps',
        query: 'since=12',
        headers: {'accept': ['application/json']},
      ));

      expect(response.status, 200);
      expect(hub.requests.single.path, '/api/v1/apps');
      expect(hub.requests.single.query, 'since=12');
      expect(hub.requests.single.host, '127.0.0.1:7619');
      expect(hub.seenHeaders['accept'], ['application/json']);
    });

    test('POST 请求体完整到达上游', () async {
      final upstream = TcpAppHubUpstream(proxyPort: 7619);
      await upstream.send(AppHubUpstreamRequest(
        method: 'POST',
        path: '/api/v1/notices',
        headers: {'content-type': ['application/json']},
        body: utf8.encode('{"appId":"a","title":"t"}'),
      ));

      expect(hub.requests.single.method, 'POST');
      expect(hub.requests.single.body, '{"appId":"a","title":"t"}');
    });

    test('响应 status/多值头/body 原样带回', () async {
      final upstream = TcpAppHubUpstream();
      final response = await upstream.send(
        const AppHubUpstreamRequest(method: 'GET', path: '/x'),
      );

      expect(response.status, 200);
      // dart:io 把上游同名多值头折叠为一行逗号串(旧 _forward 透传同行为)。
      expect(response.headers['x-apphub'], ['one, two']);
      final body = await response.body.transform(utf8.decoder).join();
      expect(body, '{"ok":true}');
    });

    test('每个请求重读当下 base:base 换了目标跟着换', () async {
      final other = FakeAppHub();
      await other.start();
      final upstream = TcpAppHubUpstream(proxyPort: 7619);

      await upstream.send(const AppHubUpstreamRequest(method: 'GET', path: '/a'));
      appHubBase = other.base;
      await upstream.send(const AppHubUpstreamRequest(method: 'GET', path: '/b'));

      expect(hub.requests.single.path, '/a');
      expect(other.requests.single.path, '/b');
      await other.stop();
    });

    test('上游连不上时抛出(代理层负责转 502)', () async {
      // base 指向一个已关闭的口。
      final dead = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = dead.port;
      await dead.close(force: true);
      appHubBase = 'http://127.0.0.1:$deadPort';

      final upstream = TcpAppHubUpstream();
      await expectLater(
        upstream.send(const AppHubUpstreamRequest(method: 'GET', path: '/x')),
        throwsA(isA<SocketException>()),
      );
    });
  });

  group('headersOf', () {
    test('拷成多值 map', () {
      final upstream = TcpAppHubUpstream();
      // 借一次真实请求验证拷贝形状。
      return upstream
          .send(const AppHubUpstreamRequest(method: 'GET', path: '/h'))
          .then((response) {
        expect(response.headers['x-apphub'], ['one, two']);
        expect(response.headers['content-type'], isNotNull);
      });
    });
  });
}
