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

/// The zip's file entry at [name], or null when absent or not a regular
/// file — the read side of publish's `has()` gate.
ArchiveFile? _archiveEntry(Archive archive, String name) {
  for (final ArchiveFile file in archive.files) {
    if (file.name == name && file.isFile) return file;
  }
  return null;
}

/// Normalises a decoded main/store.json to the listing schema: unknown keys
/// are dropped and wrong-typed values are dropped too (collects coerces to
/// false — a wrong "collects" must never read as "collects data"). Blank
/// strings stay: detail falls back per field, so empties are harmless.
/// Screenshots are left out here on purpose — they name zip entries and can
/// only be resolved against the archive (see [_extractShots]).
Map<String, Object?> _whitelistedListing(Map<String, Object?> raw) {
  final Map<String, Object?> listing = <String, Object?>{};
  for (final String key in const <String>[
    'subtitle',
    'category',
    'developer',
    'description',
    'language',
    'compatibility',
    'whatsNew',
  ]) {
    final Object? value = raw[key];
    if (value is String) listing[key] = value;
  }
  final Object? keywords = raw['keywords'];
  if (keywords is List) listing['keywords'] = List<Object?>.from(keywords);
  final Object? permissions = raw['permissions'];
  if (permissions is List) {
    listing['permissions'] = <Object?>[
      for (final dynamic permission in permissions)
        if (permission is Map<String, Object?>) permission,
    ];
  }
  if (raw.containsKey('collects')) {
    listing['collects'] = raw['collects'] is bool ? raw['collects'] : false;
  }
  return listing;
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
      ..get('/icons/<file>', _icon)
      ..get('/shots/<file>', _shot)
      ..get('/api/v1/apps', _list)
      ..get('/api/v1/apps/<appId>', _detail)
      ..get('/api/v1/apps/<appId>/versions', _versions)
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
      if ((version['icon_file'] as String?)?.isNotEmpty ?? false)
        'iconUrl': _iconUrl(request.headers['host'] ?? '127.0.0.1:7610', version['icon_file']),
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

  /// GET /icons/<file> — a bundle icon extracted at publish time
  /// (main/icon.png lives in the zip; the file lands beside the packages).
  Future<shelf.Response> _icon(shelf.Request request, String file) async {
    final String name = p.basename(file);
    final File icon = File(p.join(cfg.packagesDir, name));
    if (!await icon.exists()) {
      return shelf.Response.notFound('no such icon');
    }
    final Uint8List bytes = await icon.readAsBytes();
    return shelf.Response(200,
        body: bytes,
        headers: <String, String>{
          'content-type': 'image/png',
          'content-length': '${bytes.length}',
          'cache-control': 'max-age=86400',
        });
  }

  /// Absolute URL for a stored icon file — same-host trick as packageUrl:
  /// whichever host the client used for this request also serves the icon.
  String _iconUrl(String host, Object? iconFile) =>
      iconFile == null ? '' : 'http://$host/icons/$iconFile';

  /// GET /shots/<file> — a store screenshot extracted at publish time
  /// (store.json's screenshots point into the zip; validated ones land
  /// beside the packages). Same serve/sanitise shape as [_icon].
  Future<shelf.Response> _shot(shelf.Request request, String file) async {
    final String name = p.basename(file);
    final File shot = File(p.join(cfg.packagesDir, name));
    if (!await shot.exists()) {
      return shelf.Response.notFound('no such screenshot');
    }
    final Uint8List bytes = await shot.readAsBytes();
    return shelf.Response(200,
        body: bytes,
        headers: <String, String>{
          'content-type': 'image/png',
          'content-length': '${bytes.length}',
          'cache-control': 'max-age=86400',
        });
  }

  Future<shelf.Response> _list(shelf.Request request) async {
    final String host = request.headers['host'] ?? '127.0.0.1:7610';
    final List<Map<String, Object?>> apps = await store.listApps();
    return _json(<String, Object?>{
      'apps': <Map<String, Object?>>[
        for (final Map<String, Object?> app in apps)
          <String, Object?>{
            ...app,
            if ((app['iconFile'] as String?)?.isNotEmpty ?? false)
              'iconUrl': _iconUrl(host, app['iconFile']),
          },
      ],
    });
  }

  /// GET /api/v1/apps/<appId> — everything a tool registrar needs: the latest
  /// version's tools manifest, the gateway routes serving this app, and the
  /// App Store-style listing from main/store.json (when one was published).
  Future<shelf.Response> _detail(shelf.Request request, String appId) async {
    final version = await store.latestVersion(appId);
    final routes = await store.listRoutes();
    final String host = request.headers['host'] ?? '127.0.0.1:7610';
    Object? tools;
    if (version != null && version['tools_json'] != null) {
      try {
        tools = jsonDecode(version['tools_json'] as String);
      } catch (_) {
        tools = null;
      }
    }
    // Store listing: optional decoration — corrupt or missing stored JSON
    // degrades field by field below, never a 500.
    Map<String, Object?>? listing;
    final String? listingJson = version?['listing_json'] as String?;
    if (listingJson != null && listingJson.isNotEmpty) {
      try {
        final Object? decoded = jsonDecode(listingJson);
        if (decoded is Map<String, Object?>) listing = decoded;
      } catch (_) {
        listing = null;
      }
    }
    final String? listingDescription = listing?['description'] as String?;
    final String description = listingDescription != null && listingDescription.isNotEmpty
        ? listingDescription
        : await _appMeta(appId, 'description');
    // store.json 的 category 优先于 apps 表里 header 时代的旧分类。
    final String? listingCategory = listing?['category'] as String?;
    final String category = listingCategory != null && listingCategory.isNotEmpty
        ? listingCategory
        : await _appMeta(appId, 'category');
    final String? listingWhatsNew = listing?['whatsNew'] as String?;
    final String? whatsNew =
        listingWhatsNew != null && listingWhatsNew.isNotEmpty
            ? listingWhatsNew
            : version?['changelog'] as String?;
    final Object? rawKeywords = listing?['keywords'];
    final Object? rawPermissions = listing?['permissions'];
    final Object? rawShots = listing?['screenshots'];
    // 不写成 `listing?['collects'] is bool ? listing?['collects'] : false`:
    // 真分支的 ?[ 会被当成嵌套三元解析(实测 analyze 报错),先提升为变量。
    final Object? rawCollects = listing?['collects'];
    final bool collects = rawCollects is bool ? rawCollects : false;
    final Object? createdAt = version?['created_at'];
    return _json(<String, Object?>{
      'appId': appId,
      'name': await _appName(appId, fallback: appId),
      'path': await _appPath(appId),
      'description': description,
      'category': category,
      'versionCode': version?['version_code'],
      'versionName': version?['version_name'],
      'changelog': version?['changelog'],
      // Listing extras — every field falls back to an empty/default value so
      // versions published before store.json answer the same response shape.
      'subtitle': listing?['subtitle'] as String? ?? '',
      'developer': listing?['developer'] as String? ?? '',
      'keywords':
          rawKeywords is List ? List<Object?>.from(rawKeywords) : <Object?>[],
      'language': listing?['language'] as String? ?? '',
      'compatibility': listing?['compatibility'] as String? ?? '',
      'whatsNew': whatsNew,
      'collects': collects,
      'permissions': [
        if (rawPermissions is List)
          for (final dynamic permission in rawPermissions)
            if (permission is Map<String, Object?>)
              <String, Object?>{
                // Keep only the three renderable string fields; anything
                // else a package smuggled into a permission stays in the DB.
                for (final String key in const <String>['key', 'title', 'usage'])
                  if (permission[key] is String) key: permission[key] as String,
              },
      ],
      // Stored file names become same-host absolute URLs (see [_iconUrl]).
      'screenshots': [
        if (rawShots is List)
          for (final dynamic shot in rawShots)
            if (shot is String && shot.isNotEmpty) 'http://$host/shots/$shot',
      ],
      'sizeBytes': version?['size_bytes'],
      // TIMESTAMP arrives ISO-8601 via Db._normalize; guard the raw type
      // anyway so a null/odd value can never leak into the JSON.
      'updatedAt': createdAt is DateTime
          ? createdAt.toIso8601String()
          : (createdAt is String && createdAt.isNotEmpty ? createdAt : null),
      'icon': version?['icon'],
      if ((version?['icon_file'] as String?)?.isNotEmpty ?? false)
        'iconUrl': _iconUrl(host, version?['icon_file']),
      'tools': tools,
      'routes': [
        for (final route in routes)
          if (route['appId'] == appId) route,
      ],
    });
  }

  /// GET /api/v1/apps/<appId>/versions — recent versions for the store
  /// detail page's history list.
  Future<shelf.Response> _versions(shelf.Request request, String appId) async {
    return _json(<String, Object?>{
      'appId': appId,
      'versions': await store.versions(appId),
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

    // Bundle icon: main/icon.png ships with the package — extract it next to
    // the zip so /icons/<appId>-<versionCode>-icon.png can serve it. Absent
    // or oversized icons degrade gracefully (clients fall back to icon keys).
    String? iconFile;
    for (final ArchiveFile entry in archive.files) {
      if (!entry.isFile || entry.name != 'main/icon.png') continue;
      final Uint8List iconBytes = Uint8List.fromList(entry.content as List<int>);
      if (iconBytes.isEmpty || iconBytes.lengthInBytes > 512 * 1024) break;
      final File iconTarget = File(cfg.iconPath(appId, versionCode));
      await iconTarget.writeAsBytes(iconBytes, flush: true);
      iconFile = p.basename(iconTarget.path);
      break;
    }
    // Publishes that ship no bundle icon (and no explicit x-icon) inherit the
    // previous version's icon — a bare republish must never blank the icon
    // out of the market. Explicit metadata always wins.
    final String? icon =
        (request.headers['x-icon']?.isNotEmpty ?? false)
            ? request.headers['x-icon']
            : iconFile ?? latest?['icon'] as String?;
    iconFile ??= latest?['icon_file'] as String?;

    // Store listing: optional main/store.json carries the App Store-style
    // detail metadata. Whole block inside one try — bad JSON, an unreadable
    // entry or a failed screenshot write all degrade to "no listing"; a
    // broken store.json must never fail the publish.
    Map<String, Object?>? listing;
    try {
      final ArchiveFile? entry = _archiveEntry(archive, 'main/store.json');
      if (entry != null) {
        final Object? decoded = jsonDecode(utf8.decode(
            Uint8List.fromList(entry.content as List<int>),
            allowMalformed: true));
        if (decoded is Map<String, Object?>) {
          listing = _whitelistedListing(decoded);
          await _extractShots(archive, decoded, listing, appId, versionCode);
        }
      }
    } catch (_) {
      listing = null;
    }
    // A bare republish inherits the previous version's listing just like its
    // icon — shipping no store.json must never blank the store page out.
    final bool hasListing = listing != null;
    final String? listingJson =
        listing != null ? jsonEncode(listing) : latest?['listing_json'] as String?;

    final String name = await _metaUtf8(request, 'x-app-name-b64') ??
        request.headers['x-app-name'] ??
        appId;
    final String path = await _metaUtf8(request, 'x-app-path-b64') ??
        request.headers['x-app-path'] ??
        'pages/index/index';
    final String? description = await _metaUtf8(request, 'x-app-desc-b64');
    final String? category = request.headers['x-app-category'];
    final String? changelog = await _metaUtf8(request, 'x-changelog-b64');
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
      iconFile: iconFile,
      toolsJson: toolsJson,
      minContainer: request.headers['x-min-container'],
      listingJson: listingJson,
    );
    await store.provisionAppDb(appId, cfg.appDbPassword);
    await db.audit('publisher', 'publish', '$appId v$versionCode sha=$sha256hex');

    return _json(<String, Object?>{
      'appId': appId,
      'versionCode': versionCode,
      'versionName': versionName,
      'sha256': sha256hex,
      'sizeBytes': bytes.length,
      // 本次发布是否真的带上了 store.json(继承来的不算),方便发布方核对。
      'listing': hasListing,
    });
  }

  /// Resolves [rawStore]['screenshots'] (the as-authored store.json map —
  /// the whitelisted [listing] deliberately drops the key, screenshot paths
  /// are only meaningful against this archive) and rewrites
  /// [listing]['screenshots'] to the stored file names: every entry must be a relative path under
  /// main/ naming a real PNG file entry (no escapes, ≤2 MiB, magic bytes
  /// checked). Survivors are written as
  /// <appId>-<versionCode>-shot-<i>.png beside the zip where /shots/ serves
  /// them; six is the storefront cap. Anything rejected is skipped, and an
  /// empty survivor list removes the key — a bad screenshot never fails the
  /// publish.
  Future<void> _extractShots(Archive archive, Map<String, Object?> rawStore,
      Map<String, Object?> listing, String appId, int versionCode) async {
    final Object? raw = rawStore['screenshots'];
    if (raw is! List) {
      listing.remove('screenshots');
      return;
    }
    final List<String> stored = <String>[];
    for (final dynamic shot in raw) {
      if (stored.length >= 6) break;
      if (shot is! String || shot.isEmpty) continue;
      // Zip paths are app-authored: reject anything that could climb out of
      // main/ before it reaches the filesystem.
      if (shot.startsWith('/') || shot.split('/').contains('..')) continue;
      final ArchiveFile? entry = _archiveEntry(archive, 'main/$shot');
      if (entry == null) continue;
      final Uint8List png = Uint8List.fromList(entry.content as List<int>);
      // Header must be the PNG magic — anything else would render broken in
      // <img> tags on clients, so treat it as absent.
      if (png.length < 4 ||
          png[0] != 0x89 ||
          png[1] != 0x50 ||
          png[2] != 0x4E ||
          png[3] != 0x47) {
        continue;
      }
      if (png.length > 2 * 1024 * 1024) continue;
      final File target = File(p.join(
          cfg.packagesDir, '$appId-$versionCode-shot-${stored.length + 1}.png'));
      await target.writeAsBytes(png, flush: true);
      stored.add(p.basename(target.path));
    }
    if (stored.isEmpty) {
      listing.remove('screenshots');
    } else {
      listing['screenshots'] = stored;
    }
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
    // 下载 URL 按 <appId>-<versionCode>.zip 拼,所以必须把捐体 zip 落到新
    // 版本号的文件名下——只插版本行复用旧路径的话,客户端拉包 404。
    final File donorFile = File(donor['zip_path'] as String);
    final File rollbackTarget = File(cfg.packagePath(appId, newCode));
    if (!await rollbackTarget.exists()) {
      if (!await donorFile.exists()) {
        return _json(<String, Object?>{'error': 'donor package file missing'}, 500);
      }
      await donorFile.copy(rollbackTarget.path);
    }
    // The donor's bundle icon rides along under the new version's name so
    // /icons/<appId>-<newCode>-icon.png answers without a DB pointer dance.
    String? iconFile = donor['icon_file'] as String?;
    if (iconFile != null && iconFile.isNotEmpty) {
      final File donorIcon = File(p.join(cfg.packagesDir, iconFile));
      if (await donorIcon.exists()) {
        final File iconTarget = File(cfg.iconPath(appId, newCode));
        await donorIcon.copy(iconTarget.path);
        iconFile = p.basename(iconTarget.path);
      } else {
        iconFile = null;
      }
    }
    // The donor's store listing rides along the same way: screenshot files
    // are copied under the new code's names (missing ones drop out of the
    // list — all gone means no listing), and the stored JSON is re-pointed
    // by swapping only the '<code>-shot-' fragment; a bare donorCode swap
    // could corrupt listing text that merely contains the number. Corrupt
    // stored JSON degrades to no listing, same as publish.
    final int donorCode = donor['version_code'] as int;
    String? listingJson = donor['listing_json'] as String?;
    if (listingJson != null && listingJson.isNotEmpty) {
      try {
        final Object? decoded = jsonDecode(listingJson);
        if (decoded is Map<String, Object?>) {
          final Object? rawShots = decoded['screenshots'];
          if (rawShots is List) {
            final List<String> kept = <String>[];
            for (final dynamic shot in rawShots) {
              if (shot is! String || shot.isEmpty) continue;
              final File donorShot = File(p.join(cfg.packagesDir, shot));
              if (!await donorShot.exists()) continue;
              final String newShot =
                  shot.replaceAll('$donorCode-shot-', '$newCode-shot-');
              await donorShot.copy(p.join(cfg.packagesDir, newShot));
              kept.add(newShot);
            }
            if (kept.isEmpty) {
              listingJson = null;
            } else {
              decoded['screenshots'] = kept;
              listingJson = jsonEncode(decoded);
            }
          }
          // Only the shot-name fragment needs re-pointing; listings without
          // screenshots pass through with the same fragment swap.
          listingJson =
              listingJson?.replaceAll('$donorCode-shot-', '$newCode-shot-');
        } else {
          listingJson = null;
        }
      } catch (_) {
        listingJson = null;
      }
    }
    await store.insertVersion(
      appId: appId,
      versionCode: newCode,
      versionName: donor['version_name'] as String? ?? 'rollback',
      zipPath: donor['zip_path'] as String,
      sha256: donor['sha256'] as String,
      sizeBytes: donor['size_bytes'] as int? ?? 0,
      changelog: donor['changelog'] as String?,
      icon: donor['icon'] as String?,
      iconFile: iconFile,
      toolsJson: donor['tools_json'] as String?,
      minContainer: donor['min_container'] as String?,
      listingJson: listingJson,
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
