/// The market: Dimina-compatible manifests, package downloads, publish with a
/// gate, listing, rollback (旧包新版本号) and install events.
///
/// Manifest contract (Dimina consumes these fields directly):
///   { appId, name, path, versionCode, versionName, packageUrl, sha256 }
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf_router/shelf_router.dart' as shelf_router;

import 'config.dart';
import 'db.dart';
import 'store.dart';

const Map<String, String> _jsonHeaders = {
  'content-type': 'application/json; charset=utf-8',
};

shelf.Response _json(Object? body, [int status = 200]) =>
    shelf.Response(status, body: jsonEncode(body), headers: _jsonHeaders);

/// Validates the tools manifest (OpenAPI subset) published alongside a
/// version: the single source of truth the DSH plugin registers from.
String? validateTools(Object? decoded) {
  if (decoded == null) return null;
  if (decoded is! Map<String, Object?> || decoded['tools'] is! List) {
    return 'tools must be an object with a "tools" array';
  }
  final List<dynamic> tools = decoded['tools'] as List<dynamic>;
  for (final dynamic tool in tools) {
    if (tool is! Map<String, Object?>) return 'each tool must be an object';
    final String name = tool['name'] as String? ?? '';
    final String method = (tool['method'] as String? ?? 'GET').toUpperCase();
    final String path = tool['path'] as String? ?? '';
    if (!RegExp(r'^[a-z][a-z0-9_]{1,40}$').hasMatch(name)) {
      return 'tool name "$name" must be snake_case';
    }
    if (!<String>['GET', 'POST', 'PUT', 'DELETE'].contains(method)) {
      return 'tool "$name": method must be GET/POST/PUT/DELETE';
    }
    if (!path.startsWith('/')) return 'tool "$name": path must start with /';
    final Object? params = tool['params'];
    if (params != null && params is! Map<String, Object?>) {
      return 'tool "$name": params must be a JSON schema object';
    }
  }
  return null;
}

class Market {
  Market(this.cfg, this.db, this.store);

  final AppConfig cfg;
  final Db db;
  final Store store;

  shelf_router.Router get router {
    final router = shelf_router.Router()
      ..get('/healthz', (shelf.Request request) => shelf.Response.ok('ok'))
      ..get('/apps/<appId>/manifest.json', _manifest)
      // Dimina-style alias: the POC page and older clients use
      // /manifest/<appId>.json — same handler, same headers.
      ..get('/manifest/<appIdJson>', _manifestAlias)
      ..get('/packages/<file>', _package)
      ..get('/api/v1/apps', _list)
      ..get('/api/v1/apps/<appId>', _detail)
      ..post('/api/v1/apps/<appId>/versions', _publish)
      ..post('/api/v1/apps/<appId>/tools', _setTools)
      ..post('/api/v1/apps/<appId>/rollback', _rollback)
      ..post('/api/v1/apps/<appId>/events', _event);
    return router;
  }

  bool _publisher(shelf.Request request) {
    final String key = cfg.publisherKey;
    return key.isNotEmpty &&
        (request.headers['authorization'] ?? '') == 'Bearer $key';
  }

  /// GET /apps/<appId>/manifest.json — the Dimina updateManifestUrl target.
  Future<shelf.Response> _manifest(shelf.Request request, String appId) async {
    final version = await store.latestVersion(appId);
    if (version == null) {
      return _json(<String, Object?>{'error': 'no such app'}, 404);
    }
    final String zipName =
        '$appId-${version['version_code']}.zip';
    final Object? body = <String, Object?>{
      'appId': appId,
      'name': await _appName(appId, fallback: appId),
      'path': await _appPath(appId),
      'versionCode': version['version_code'],
      'versionName': version['version_name'],
      // Absolute: the Dimina updater fetches this URL, and the Host the client
      // used for the manifest is exactly the host it can fetch the package
      // from (LAN IP, adb reverse loopback, or the ssh tunnel — all work).
      'packageUrl': 'http://${request.headers['host'] ?? '127.0.0.1:7610'}'
          '/packages/$zipName',
      'sha256': version['sha256'],
      'channel': 'stable',
    };
    await store.addEvent(appId, 'manifest_fetch', 'v${version['version_code']}');
    return _json(body);
  }

  /// GET /manifest/<appId>.json — alias of /apps/<appId>/manifest.json.
  Future<shelf.Response> _manifestAlias(shelf.Request request, String appIdJson) async {
    final String appId = appIdJson.replaceAll(RegExp(r'\.json$'), '');
    return _manifest(request, appId);
  }

  Future<String> _appName(String appId, {required String fallback}) async {
    final rows = await db.q('SELECT name FROM apps WHERE app_id = ?', [appId]);
    return rows.isEmpty ? fallback : (rows.first['name'] as String? ?? fallback);
  }

  Future<String> _appPath(String appId) async {
    final rows = await db.q('SELECT path FROM apps WHERE app_id = ?', [appId]);
    return rows.isEmpty ? 'pages/index/index' : (rows.first['path'] as String? ?? 'pages/index/index');
  }

  /// HTTP headers are latin-1; UTF-8 metadata (Chinese names) travels base64.
  Future<String?> _metaUtf8(shelf.Request request, String header) async {
    final String? b64 = request.headers[header];
    if (b64 == null || b64.isEmpty) return null;
    try {
      return utf8.decode(base64Decode(b64));
    } catch (_) {
      return null;
    }
  }

  /// GET /packages/<file> — the zip bytes. Name is sanitised to a bare file.
  Future<shelf.Response> _package(shelf.Request request, String file) async {
    final String name = p.basename(file);
    final File zip = File(p.join(cfg.packagesDir, name));
    if (!await zip.exists()) {
      return shelf.Response.notFound('no such package');
    }
    final Uint8List bytes = await zip.readAsBytes();
    return shelf.Response(200,
        body: bytes,
        headers: <String, String>{
          'content-type': 'application/zip',
          'content-length': '${bytes.length}',
        });
  }

  Future<shelf.Response> _list(shelf.Request request) async {
    return _json(<String, Object?>{'apps': await store.listApps()});
  }

  /// GET /api/v1/apps/<appId> — everything a tool registrar needs: the latest
  /// version's tools manifest plus the gateway routes serving this app.
  Future<shelf.Response> _detail(shelf.Request request, String appId) async {
    final version = await store.latestVersion(appId);
    final routes = await store.listRoutes();
    Object? tools;
    if (version != null && version['tools_json'] != null) {
      try {
        tools = jsonDecode(version['tools_json'] as String);
      } catch (_) {
        tools = null;
      }
    }
    return _json(<String, Object?>{
      'appId': appId,
      'name': await _appName(appId, fallback: appId),
      'path': await _appPath(appId),
      'description': await _appMeta(appId, 'description'),
      'category': await _appMeta(appId, 'category'),
      'versionCode': version?['version_code'],
      'versionName': version?['version_name'],
      'changelog': version?['changelog'],
      'icon': version?['icon'],
      'tools': tools,
      'routes': [
        for (final route in routes)
          if (route['appId'] == appId) route,
      ],
    });
  }

  Future<String> _appMeta(String appId, String column) async {
    final rows = await db.q('SELECT $column FROM apps WHERE app_id = ?', [appId]);
    return rows.isEmpty ? '' : (rows.first[column] as String? ?? '');
  }

  /// POST /api/v1/apps/<appId>/versions — raw zip body; metadata via headers:
  ///   authorization: Bearer <publisherKey>
  ///   x-app-name / x-app-path / x-version-name / x-min-container (optional)
  ///   x-version-code (optional; defaults to latest + 1)
  ///   x-tools-b64 (optional; base64 of the tools manifest JSON)
  /// The gate: a zip must contain main/app-config.json and main/logic.js
  /// (Dimina's minimum), versionCode must strictly increase, tools (when
  /// given) must pass [validateTools].
  Future<shelf.Response> _publish(shelf.Request request, String appId) async {
    if (!_publisher(request)) return _json(<String, Object?>{'error': 'unauthorized'}, 401);
    if (!isValidAppId(appId)) return _json(<String, Object?>{'error': 'invalid appId'}, 400);

    final Uint8List bytes = await request.read().fold<BytesBuilder>(
        BytesBuilder(), (builder, chunk) => builder..add(chunk)).then((b) => b.takeBytes());
    if (bytes.isEmpty) return _json(<String, Object?>{'error': 'empty body'}, 400);

    // --- gate: structure ---
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes, verify: true);
    } catch (_) {
      return _json(<String, Object?>{'error': 'body is not a zip'}, 400);
    }
    bool has(String name) => archive.files.any((f) => f.name == name && f.isFile);
    if (!has('main/app-config.json') || !has('main/logic.js')) {
      return _json(<String, Object?>{
        'error': 'package must contain main/app-config.json and main/logic.js'
      }, 400);
    }

    // --- gate: versionCode strictly increases ---
    final latest = await store.latestVersion(appId);
    final int latestCode = latest == null ? 0 : latest['version_code'] as int;
    final int versionCode = int.tryParse(
            request.headers['x-version-code'] ?? '') ??
        latestCode + 1;
    if (versionCode <= latestCode) {
      return _json(<String, Object?>{
        'error': 'versionCode must be > $latestCode'
      }, 409);
    }

    // --- gate: tools manifest ---
    final String? toolsB64 = request.headers['x-tools-b64'];
    String? toolsJson;
    if (toolsB64 != null && toolsB64.isNotEmpty) {
      try {
        final Object? decoded =
            jsonDecode(utf8.decode(base64Decode(toolsB64)));
        final String? problem = validateTools(decoded);
        if (problem != null) return _json(<String, Object?>{'error': problem}, 400);
        toolsJson = jsonEncode(decoded);
      } catch (_) {
        return _json(<String, Object?>{'error': 'x-tools-b64 is not base64 JSON'}, 400);
      }
    }

    final String sha256hex = sha256.convert(bytes).toString();
    final File target = File(cfg.packagePath(appId, versionCode));
    await target.parent.create(recursive: true);
    final File tmp = File('${target.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(target.path);

    final String name = await _metaUtf8(request, 'x-app-name-b64') ??
        request.headers['x-app-name'] ??
        appId;
    final String path = await _metaUtf8(request, 'x-app-path-b64') ??
        request.headers['x-app-path'] ??
        'pages/index/index';
    final String? description = await _metaUtf8(request, 'x-app-desc-b64');
    final String? category = request.headers['x-app-category'];
    final String? changelog = await _metaUtf8(request, 'x-changelog-b64');
    final String? icon = request.headers['x-icon'];
    final String versionName = request.headers['x-version-name'] ?? '0.0.$versionCode';
    await store.upsertApp(appId, name, path, description: description, category: category);
    await store.insertVersion(
      appId: appId,
      versionCode: versionCode,
      versionName: versionName,
      zipPath: target.path,
      sha256: sha256hex,
      sizeBytes: bytes.length,
      changelog: changelog,
      icon: icon,
      toolsJson: toolsJson,
      minContainer: request.headers['x-min-container'],
    );
    await store.provisionAppDb(appId, cfg.appDbPassword);
    await db.audit('publisher', 'publish', '$appId v$versionCode sha=$sha256hex');

    return _json(<String, Object?>{
      'appId': appId,
      'versionCode': versionCode,
      'versionName': versionName,
      'sha256': sha256hex,
      'sizeBytes': bytes.length,
    });
  }

  /// POST /api/v1/apps/<appId>/tools — set the tools manifest on the latest
  /// version (agent-authored tools live with the version they belong to).
  Future<shelf.Response> _setTools(shelf.Request request, String appId) async {
    if (!_publisher(request)) return _json(<String, Object?>{'error': 'unauthorized'}, 401);
    final Object? decoded;
    try {
      decoded = jsonDecode(await request.readAsString());
    } catch (_) {
      return _json(<String, Object?>{'error': 'body must be JSON'}, 400);
    }
    final String? problem = validateTools(decoded);
    if (problem != null) return _json(<String, Object?>{'error': problem}, 400);
    await store.setLatestTools(appId, jsonEncode(decoded));
    await db.audit('publisher', 'tools', appId);
    return _json(<String, Object?>{'appId': appId, 'tools': 'set'});
  }

  /// POST /api/v1/apps/<appId>/rollback — 旧包新版本号: re-issue the newest
  /// version below latest as latest+1 (Dimina only ever upgrades by
  /// versionCode, so a true "downgrade" pointer cannot reach clients).
  Future<shelf.Response> _rollback(shelf.Request request, String appId) async {
    if (!_publisher(request)) return _json(<String, Object?>{'error': 'unauthorized'}, 401);
    final latest = await store.latestVersion(appId);
    if (latest == null) return _json(<String, Object?>{'error': 'no versions'}, 404);
    final donor = await store.versionBelow(appId, latest['version_code'] as int);
    if (donor == null) return _json(<String, Object?>{'error': 'only one version'}, 409);
    final int newCode = (latest['version_code'] as int) + 1;
    await store.insertVersion(
      appId: appId,
      versionCode: newCode,
      versionName: donor['version_name'] as String? ?? 'rollback',
      zipPath: donor['zip_path'] as String,
      sha256: donor['sha256'] as String,
      sizeBytes: donor['size_bytes'] as int? ?? 0,
      toolsJson: donor['tools_json'] as String?,
      minContainer: donor['min_container'] as String?,
    );
    await db.audit('publisher', 'rollback', '$appId -> v$newCode (donor ${donor['version_code']})');
    return _json(<String, Object?>{
      'appId': appId,
      'versionCode': newCode,
      'donorVersionCode': donor['version_code'],
      'sha256': donor['sha256'],
    });
  }

  /// POST /api/v1/apps/<appId>/events — client lifecycle reports.
  Future<shelf.Response> _event(shelf.Request request, String appId) async {
    if (cfg.deviceToken.isNotEmpty &&
        (request.headers['authorization'] ?? '') != 'Bearer ${cfg.deviceToken}') {
      return _json(<String, Object?>{'error': 'unauthorized'}, 401);
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(await request.readAsString());
    } catch (_) {
      return _json(<String, Object?>{'error': 'body must be JSON'}, 400);
    }
    final String event = decoded is Map<String, Object?> && decoded['event'] is String
        ? decoded['event'] as String
        : 'unknown';
    await store.addEvent(appId, event,
        decoded is Map<String, Object?> ? decoded['detail']?.toString() : null);
    return _json(<String, Object?>{'ok': true});
  }
}
