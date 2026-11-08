/// The route gateway: third-party mini-program backends mount prefixes here,
/// and every request under /api/v1/apps/<appId>/<prefix>/… is reverse-proxied
/// to the backend with identity headers injected and per-route limits applied.
///
/// Failure isolation is per route: timeouts never leak past 504, backend
/// errors become 502, and an rpm overrun is 429 — one bad backend cannot
/// take AppHub or other mini programs down with it.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf_router/shelf_router.dart' as shelf_router;

import 'config.dart';
import 'db.dart';
import 'store.dart';

class _Route {
  _Route(this.appId, this.prefix, this.target, this.timeoutMs, this.rpm);

  final String appId;
  final String prefix;
  final String target;
  final int timeoutMs;
  final int rpm;
  final List<int> _hits = <int>[];

  bool matches(String rest) =>
      prefix == '/' || rest == prefix || rest.startsWith('$prefix/') || rest.startsWith(prefix);

  bool allow(int nowMs) {
    _hits.removeWhere((t) => nowMs - t > 60000);
    if (_hits.length >= rpm) return false;
    _hits.add(nowMs);
    return true;
  }
}

class Gateway {
  Gateway(this.cfg, this.db, this.store);

  final AppConfig cfg;
  final Db db;
  final Store store;
  final Map<String, Map<String, _Route>> _byApp = <String, Map<String, _Route>>{};
  final http.Client _client = http.Client();

  Future<void> reload() async {
    _byApp.clear();
    // Store.listRoutes hands back normalised keys (appId/timeoutMs/rpm).
    for (final row in await store.listRoutes()) {
      final String appId = row['appId'] as String;
      (_byApp[appId] ??= <String, _Route>{})[row['prefix'] as String] = _Route(
        appId,
        row['prefix'] as String,
        row['target'] as String,
        row['timeoutMs'] as int,
        row['rpm'] as int,
      );
    }
  }

  shelf_router.Router get adminRouter {
    final router = shelf_router.Router()
      ..get('/api/v1/gateway/routes', _list)
      ..post('/api/v1/gateway/routes', _register)
      ..delete('/api/v1/gateway/routes/<appId>/<prefix>', _remove);
    return router;
  }

  bool _publisher(shelf.Request request) {
    final String key = cfg.publisherKey;
    return key.isNotEmpty &&
        (request.headers['authorization'] ?? '') == 'Bearer $key';
  }

  Future<shelf.Response> _list(shelf.Request request) async =>
      shelf.Response.ok(jsonEncode(<String, Object?>{'routes': await store.listRoutes()}),
          headers: <String, String>{'content-type': 'application/json; charset=utf-8'});

  Future<shelf.Response> _register(shelf.Request request) async {
    if (!_publisher(request)) {
      return shelf.Response(401,
          body: jsonEncode(<String, Object?>{'error': 'unauthorized'}),
          headers: <String, String>{'content-type': 'application/json; charset=utf-8'});
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(await request.readAsString());
    } catch (_) {
      return _err(400, 'body must be JSON');
    }
    if (decoded is! Map<String, Object?>) return _err(400, 'body must be a JSON object');
    final String appId = decoded['appId'] as String? ?? '';
    final String prefix = decoded['prefix'] as String? ?? '';
    final String target = decoded['target'] as String? ?? '';
    if (!isValidAppId(appId)) return _err(400, 'invalid appId');
    if (prefix.isEmpty || !prefix.startsWith('/')) return _err(400, 'prefix must start with /');
    final Uri? uri = Uri.tryParse(target);
    if (uri == null || !<String>['http', 'https'].contains(uri.scheme)) {
      return _err(400, 'target must be an http(s) URL');
    }
    final int timeoutMs = (decoded['timeoutMs'] as num?)?.toInt() ?? 5000;
    final int rpm = (decoded['rateLimit'] as Map<String, Object?>?)?['rpm'] != null
        ? ((decoded['rateLimit'] as Map<String, Object?>)['rpm'] as num).toInt()
        : 120;
    await store.upsertRoute(appId, prefix, target, timeoutMs, rpm);
    await reload();
    await db.audit('publisher', 'route.register', '$appId$prefix -> $target');
    return shelf.Response.ok(
        jsonEncode(<String, Object?>{
          'appId': appId,
          'prefix': prefix,
          'target': target,
          'timeoutMs': timeoutMs,
          'rpm': rpm,
        }),
        headers: <String, String>{'content-type': 'application/json; charset=utf-8'});
  }

  Future<shelf.Response> _remove(shelf.Request request, String appId, String prefix) async {
    if (!_publisher(request)) return _err(401, 'unauthorized');
    await store.deleteRoute(appId, prefix);
    await reload();
    await db.audit('publisher', 'route.remove', '$appId$prefix');
    return _err(200, 'removed');
  }

  shelf.Response _err(int status, String message) => shelf.Response(status,
      body: jsonEncode(<String, Object?>{'error': message}),
      headers: <String, String>{'content-type': 'application/json; charset=utf-8'});

  /// The proxy itself. Mounted under /api/v1/apps/<appId>/… by app.dart; the
  /// handler receives the request with `apphub-app` and `apphub-rest` context
  /// values extracted by the mounting router.
  Future<shelf.Response> proxy(shelf.Request request, String appId, String rest) async {
    final Map<String, _Route>? routes = _byApp[appId];
    final _Route? route = routes == null
        ? null
        : (routes[rest] ??
            (routes['/'] ?? routes.entries
                .where((e) => e.value.matches(rest))
                .map((e) => e.value)
                .reduce((a, b) => a.prefix.length >= b.prefix.length ? a : b)));
    if (route == null) return _err(404, 'no route for $appId:$rest');

    final int now = DateTime.now().millisecondsSinceEpoch;
    if (!route.allow(now)) return _err(429, 'rate limited ($route.rpm rpm)');

    final Uri upstream;
    try {
      final String base = route.target.endsWith('/')
          ? route.target.substring(0, route.target.length - 1)
          : route.target;
      upstream = Uri.parse('$base/$rest${Uri(query: request.url.query).toString()}');
    } catch (_) {
      return _err(502, 'bad target');
    }

    final Map<String, String> headers = <String, String>{
      for (final entry in request.headers.entries)
        if (!<String>['host', 'authorization', 'content-length'].contains(entry.key))
          entry.key: entry.value,
      'x-dsh-app': appId,
      'x-dsh-request-id': request.headers['x-request-id'] ??
          'req-${DateTime.now().millisecondsSinceEpoch}',
    };

    try {
      final http.Response upstreamResponse = await _client
          .send(http.Request(request.method, upstream)
            ..headers.addAll(headers)
            ..followRedirects = false)
          .then((streamed) => http.Response.fromStream(streamed))
          .timeout(Duration(milliseconds: route.timeoutMs));
      final Map<String, String> responseHeaders = <String, String>{
        for (final entry in upstreamResponse.headers.entries)
          if (!<String>['transfer-encoding', 'content-length', 'connection']
              .contains(entry.key))
            entry.key: entry.value,
      };
      return shelf.Response(upstreamResponse.statusCode,
          body: upstreamResponse.bodyBytes, headers: responseHeaders);
    } on TimeoutException {
      await db.audit('gateway', 'timeout', '$appId:$rest ${route.timeoutMs}ms');
      return _err(504, 'backend timeout after ${route.timeoutMs}ms');
    } catch (error) {
      await db.audit('gateway', 'error', '$appId:$rest $error');
      return _err(502, 'backend unreachable');
    }
  }
}
