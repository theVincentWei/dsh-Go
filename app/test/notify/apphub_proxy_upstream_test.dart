// AppHubProxy 双上游接线(契约 apphub-proxy.v1 §6.1):代理层剥离
// hop-by-hop/host、缓冲请求体、上游失败统一 502;Tcp 与 fake Remote 上游
// 都能经代理跑通。断链 502 → 容器静默 no-update 的语义靠这里的用例钉住。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/notify/apphub_base.dart';
import 'package:dsh_app/notify/apphub_proxy.dart';
import 'package:dsh_app/notify/apphub_upstream.dart';
import 'package:flutter_test/flutter_test.dart';

import 'apphub_upstream_test.dart' show FakeAppHub;

/// 自定义上游:记录收到的请求,按脚本应答或抛错。
class FakeUpstream implements AppHubUpstream {
  FakeUpstream();

  final requests = <AppHubUpstreamRequest>[];
  Object? throwOnSend;
  AppHubUpstreamResponse? Function(AppHubUpstreamRequest request)? reply;

  @override
  Future<AppHubUpstreamResponse> send(AppHubUpstreamRequest request) async {
    requests.add(request);
    final Object? error = throwOnSend;
    if (error != null) throw error;
    return reply?.call(request) ??
        AppHubUpstreamResponse(
          status: 200,
          headers: {'x-remote': const ['yes']},
          body: Stream<List<int>>.value(utf8.encode('{"via":"remote"}')),
        );
  }
}

void main() {
  late FakeAppHub hub;
  setUp(() async {
    hub = FakeAppHub();
    await hub.start();
    appHubBase = hub.base;
    await AppHubProxy.ensureStarted();
  });
  tearDown(() async {
    AppHubProxy.resetUpstream();
    resetAppHubBase();
    await hub.stop();
  });

  /// 经真实代理端口发一个请求,读完全量响应(单订阅流,读一次)。
  Future<({int status, HttpHeaders headers, String body})> viaProxy(
    String method,
    String path, {
    String? query,
    Map<String, String> headers = const {},
    List<int>? body,
  }) async {
    final client = HttpClient();
    final request = await client.openUrl(
      method,
      Uri.http('127.0.0.1:${AppHubProxy.port}', path, query == null ? null : Uri(query: query).queryParameters),
    );
    headers.forEach(request.headers.set);
    if (body != null) request.add(body);
    final response = await request.close();
    final responseBody = await utf8.decoder.bind(response).join();
    client.close(force: true);
    return (status: response.statusCode, headers: response.headers, body: responseBody);
  }

  group('Tcp 上游(现行为)', () {
    test('GET 经代理到假 AppHub:路径/查询/Host(代理口)都对', () async {
      final result = await viaProxy('GET', '/api/v1/apps', query: 'since=12');
      expect(result.status, 200);
      expect(hub.requests.single.path, '/api/v1/apps');
      expect(hub.requests.single.query, 'since=12');
      expect(hub.requests.single.host, '127.0.0.1:${AppHubProxy.port}');
    });

    test('客户端带的 host 头被剥掉,不透传给上游', () async {
      final result = await viaProxy('GET', '/h', headers: {'host': 'evil.example:9'});
      expect(result.status, 200);
      expect(hub.requests.single.host, '127.0.0.1:${AppHubProxy.port}');
    });

    test('自定义头透传,connection 不透传', () async {
      final result = await viaProxy('GET', '/h', headers: {
        'x-probe': '1',
        'connection': 'close',
      });
      expect(result.status, 200);
      expect(hub.seenHeaders['x-probe'], ['1']);
      // 代理层剥了 connection;上游 HttpClient 自己管连接头。
      expect(hub.seenHeaders['connection'], isNot(contains('close')));
    });

    test('POST 请求体经代理完整到达上游', () async {
      final result = await viaProxy(
        'POST',
        '/api/v1/notices',
        body: utf8.encode('{"appId":"a","title":"t"}'),
      );
      expect(result.status, 200);
      expect(hub.requests.single.method, 'POST');
      expect(hub.requests.single.body, '{"appId":"a","title":"t"}');
    });
  });

  group('Remote 上游(fake)', () {
    test('切到 fake Remote 后流量走它,响应透传回客户端', () async {
      final remote = FakeUpstream();
      AppHubProxy.upstream = remote;

      final result = await viaProxy('GET', '/api/v1/apps');
      expect(result.status, 200);
      expect(result.headers.value('x-remote'), 'yes');
      expect(result.body, '{"via":"remote"}');

      final request = remote.requests.single;
      expect(request.method, 'GET');
      expect(request.path, '/api/v1/apps');
      expect(request.headers.containsKey('host'), isFalse, reason: 'host 头在代理层剥掉');
    });

    test('上游抛异常 → 502「link down」(断链语义:静默 no-update)', () async {
      final remote = FakeUpstream()..throwOnSend = StateError('link closed');
      AppHubProxy.upstream = remote;

      final result = await viaProxy('GET', '/api/v1/apps');
      expect(result.status, HttpStatus.badGateway);
      expect(result.body, contains('link down'));
    });

    test('resetUpstream 后回到 Tcp(假 AppHub 又能收到请求)', () async {
      AppHubProxy.upstream = FakeUpstream()..throwOnSend = StateError('x');
      final first = await viaProxy('GET', '/x');
      expect(first.status, HttpStatus.badGateway);

      AppHubProxy.resetUpstream();
      final second = await viaProxy('GET', '/back-on-tcp');
      expect(second.status, 200);
      expect(hub.requests.single.path, '/back-on-tcp');
    });

    test('上游响应的 hop-by-hop 头被兜底剔除(connection)', () async {
      final remote = FakeUpstream()
        ..reply = (request) => AppHubUpstreamResponse(
              status: 200,
              headers: {
                'x-keep': const ['1'],
                'connection': const ['close'],
              },
              body: Stream<List<int>>.value(utf8.encode('ok')),
            );
      AppHubProxy.upstream = remote;

      final result = await viaProxy('GET', '/x');
      expect(result.headers.value('x-keep'), '1');
      expect(result.headers.value('connection'), isNull);
    });
  });

  test('代理在上游切换前后的端口/started 语义不变', () {
    expect(AppHubProxy.started, isTrue);
    expect(AppHubProxy.port, greaterThanOrEqualTo(kAppHubProxyPort));
  });
}
