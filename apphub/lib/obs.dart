/// Observation sink: POST /api/v1/apps/<appId>/logs appends client-reported
/// lines (errors, vConsole exports, events) into the engine's
/// ~/dsh/apps/<appId>/data/logs/ — exactly where the DSH Agent reads. This is
/// the "运行 → 报错回到 Agent" half of the AI iteration loop.
library;

import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf_router/shelf_router.dart' as shelf_router;

import 'config.dart';

class Obs {
  Obs(this.cfg);

  final AppConfig cfg;

  shelf_router.Router get router {
    final router = shelf_router.Router()
      ..post('/api/v1/apps/<appId>/logs', _logs);
    return router;
  }

  Future<shelf.Response> _logs(shelf.Request request, String appId) async {
    if (!RegExp(r'^[a-z0-9][a-z0-9-]{0,62}$').hasMatch(appId)) {
      return shelf.Response(400,
          body: jsonEncode(<String, Object?>{'error': 'invalid appId'}),
          headers: <String, String>{'content-type': 'application/json; charset=utf-8'});
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(await request.readAsString());
    } catch (_) {
      return shelf.Response(400,
          body: jsonEncode(<String, Object?>{'error': 'body must be JSON'}),
          headers: <String, String>{'content-type': 'application/json; charset=utf-8'});
    }
    final List<dynamic> lines = decoded is Map<String, Object?>
        ? decoded['lines'] as List<dynamic>? ?? const <dynamic>[]
        : const <dynamic>[];
    if (lines.isEmpty) {
      return shelf.Response(400,
          body: jsonEncode(<String, Object?>{'error': 'lines required'}),
          headers: <String, String>{'content-type': 'application/json; charset=utf-8'});
    }
    final File file = File(cfg.logFileFor(appId, DateTime.now()));
    await file.parent.create(recursive: true);
    final IOSink sink = file.openWrite(mode: FileMode.append);
    for (final dynamic line in lines.take(500)) {
      sink.writeln(
          '${DateTime.now().toIso8601String()} [${request.headers['x-dsh-app'] ?? appId}] $line');
    }
    await sink.flush();
    await sink.close();
    return shelf.Response(200,
        body: jsonEncode(<String, Object?>{'ok': true, 'lines': lines.length}),
        headers: <String, String>{'content-type': 'application/json; charset=utf-8'});
  }
}
