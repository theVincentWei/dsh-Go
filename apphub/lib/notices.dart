/// Mini-program notices: backends push reminders here, clients poll them.
/// Server half of the M3 notify chain — the dsh-go client poller raising
/// local notifications (AlertKind.miniapp) lands with the container v2 work.
library;

import 'dart:convert';

import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf_router/shelf_router.dart' as shelf_router;

import 'db.dart';

class Notices {
  Notices(this.db);

  final Db db;

  shelf_router.Router get router {
    final router = shelf_router.Router()
      ..post('/api/v1/apps/<appId>/notify', _push)
      ..get('/api/v1/notices', _poll);
    return router;
  }

  /// POST /api/v1/apps/<appId>/notify — {title, body}. Requires the
  /// notify scope to exist as a gateway route for the app (cheap allowlist:
  /// the app must have at least one route registered) — a backend that never
  /// mounted itself cannot ring the user's phone.
  Future<shelf.Response> _push(shelf.Request request, String appId) async {
    final Object? decoded;
    try {
      decoded = jsonDecode(await request.readAsString());
    } catch (_) {
      return _json(400, 'body must be JSON');
    }
    if (decoded is! Map<String, Object?>) return _json(400, 'body must be a JSON object');
    final String title = decoded['title'] as String? ?? '';
    final String body = decoded['body'] as String? ?? '';
    if (title.isEmpty) return _json(400, 'title required');

    final List<Map<String, Object?>> routes = await db.q(
        'SELECT COUNT(*) AS n FROM app_routes WHERE app_id = ?', [appId]);
    final int routeCount = routes.isEmpty ? 0 : int.tryParse('${routes.first['n']}') ?? 0;
    if (routeCount == 0) return _json(403, 'app has no gateway route (notify scope denied)');

    await db.exec(
        'INSERT INTO install_events (app_id, event, detail) VALUES (?, "notify", ?)',
        [appId, '$title | $body']);
    await db.audit('notify', appId, title);
    return _json(200, <String, Object?>{'ok': true});
  }

  /// GET /api/v1/notices?since=<id> — poll for recent notify events
  /// (id-monotonic; the client remembers the last id it showed).
  Future<shelf.Response> _poll(shelf.Request request) async {
    final String sinceRaw = request.url.queryParameters['since'] ?? '0';
    final int since = int.tryParse(sinceRaw) ?? 0;
    print('[notices] poll since=$since from ${request.headers['host']}');
    final List<Map<String, Object?>> rows = await db.q(
        'SELECT id, app_id, event, detail, ts FROM install_events '
        'WHERE event = "notify" AND id > ? ORDER BY id DESC LIMIT 20',
        [since]);
    return _json(200, <String, Object?>{
      'notices': <Object?>[
        for (final row in rows)
          <String, Object?>{
            'id': int.tryParse('${row['id']}') ?? 0,
            'appId': row['app_id'],
            'detail': row['detail'],
            'ts': row['ts'],
          },
      ],
    });
  }

  shelf.Response _json(int status, Object? body) => shelf.Response(status,
      body: jsonEncode(body),
      headers: <String, String>{'content-type': 'application/json; charset=utf-8'});
}
