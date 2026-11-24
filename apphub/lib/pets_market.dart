/// Pet-pack distribution over the same tables as the market: each pack is an
/// app row named `pet-<petId>` (the prefix is a namespace marker — the
/// mini-program market never lists it, see store.listApps/listPets), each
/// release one app_versions row. Publish gates on pack.json identity; the
/// full schema-1 validation happens phone-side at install time, the same way
/// the Dimina gate here checks only structure.
///
///   GET  /api/v1/pets                        catalog (latest of each pack)
///   GET  /api/v1/pets/<petId>/manifest.json  one pack's latest release
///   GET  /api/v1/pets/<petId>/versions       release history
///   POST /api/v1/pets/<petId>/versions       publish (Bearer publisherKey,
///                                            raw zip body, metadata headers)
///
/// Phone-side contract for `GET /api/v1/pets` rows:
///   { petId, name, version, versionCode, packageUrl, sha256, sizeBytes, updatedAt }
/// `version` is the pack.json version string the phone compares with the
/// WorkshopVersion ordering; `sha256` is the zip digest the phone verifies
/// before installing.
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

/// Same shape as dsh-go's workshop ids (workshopId): lowercase start, then
/// lowercase letters, digits and hyphens, at most 40 characters.
bool isValidPetId(String id) =>
    RegExp(r'^[a-z0-9][a-z0-9-]{0,39}$').hasMatch(id);

/// A loose version shape — non-empty, bounded, no whitespace or control
/// characters. The real ordering rules live phone-side (WorkshopVersion);
/// the server only refuses strings that could never compare.
bool isPlausibleVersion(Object? version) =>
    version is String &&
    version.isNotEmpty &&
    version.length <= 32 &&
    !RegExp(r'[\s\u0000-\u001f]').hasMatch(version);

/// The pack.json entry inside a published zip: top level, or in exactly one
/// top folder — the same candidates PetArchive accepts phone-side, and there
/// must be exactly one.
ArchiveFile? _packJsonEntry(Archive archive) {
  ArchiveFile? found;
  for (final ArchiveFile file in archive.files) {
    if (!file.isFile || p.basename(file.name) != 'pack.json') continue;
    final String dir = p.dirname(file.name);
    if (dir != '.' && dir != '') return null; // nested too deep
    if (found != null) return null; // ambiguous
    found = file;
  }
  return found;
}

const Map<String, String> _jsonHeaders = {
  'content-type': 'application/json; charset=utf-8',
};

shelf.Response _json(Object? body, [int status = 200]) =>
    shelf.Response(status, body: jsonEncode(body), headers: _jsonHeaders);

/// Pet packs ship no icon today; the overlay never renders one from the
/// market. Keep the header/inheritance plumbing out until a real preview
/// lands — [publish] stores none.
class PetMarket {
  PetMarket(this.cfg, this.db, this.store);

  final AppConfig cfg;
  final Db db;
  final Store store;

  /// Zip bodies are small (real packs are 0.3–2 MiB; the phone-side schema
  /// caps declared expansion at 64 MiB). Refuse bigger uploads early.
  static const int _maxPackBytes = 64 * 1024 * 1024;

  shelf_router.Router get router {
    final router = shelf_router.Router()
      ..get('/api/v1/pets', _catalog)
      ..get('/api/v1/pets/<petId|[^/]+>/manifest.json', _manifest)
      ..get('/api/v1/pets/<petId|[^/]+>/versions', _versions)
      ..post('/api/v1/pets/<petId|[^/]+>/versions', _publish);
    return router;
  }

  bool _publisher(shelf.Request request) {
    final String key = cfg.publisherKey;
    return key.isNotEmpty &&
        (request.headers['authorization'] ?? '') == 'Bearer $key';
  }

  /// The app row id for a pet — the `pet-` namespace marker.
  String _appId(String petId) => 'pet-$petId';

  /// Same-host absolute URL, exactly like the market's packageUrl: whichever
  /// host the client used for this request also serves the bytes (loopback,
  /// LAN IP or the SSH tunnel forward — all work).
  String _packageUrl(String host, String petId, int versionCode) =>
      'http://$host/packages/pet-$petId-$versionCode.zip';

  Map<String, Object?> _catalogRow(
      String host, Map<String, Object?> pet, Map<String, Object?>? latest) {
    final int? versionCode = latest?['version_code'] as int?;
    return <String, Object?>{
      'petId': pet['petId'],
      'name': pet['name'],
      'version': latest?['version_name'],
      'versionCode': versionCode,
      if (versionCode != null)
        'packageUrl':
            _packageUrl(host, pet['petId'] as String, versionCode),
      'sha256': latest?['sha256'],
      'sizeBytes': latest?['size_bytes'],
      'updatedAt': latest?['created_at'] is DateTime
          ? (latest!['created_at'] as DateTime).toIso8601String()
          : latest?['created_at'],
    };
  }

  /// GET /api/v1/pets — every pack's latest release.
  Future<shelf.Response> _catalog(shelf.Request request) async {
    final String host = request.headers['host'] ?? '127.0.0.1:7610';
    final pets = await store.listPets();
    final latest = <String, Map<String, Object?>?>{
      for (final Map<String, Object?> pet in pets)
        pet['petId'] as String: await store.latestVersion(_appId(pet['petId'] as String)),
    };
    return _json(<String, Object?>{
      'pets': <Map<String, Object?>>[
        for (final Map<String, Object?> pet in pets)
          _catalogRow(host, pet, latest[pet['petId'] as String]),
      ],
    });
  }

  Future<shelf.Response> _manifest(shelf.Request request, String petId) async {
    if (!isValidPetId(petId)) return _json(<String, Object?>{'error': 'invalid petId'}, 400);
    final latest = await store.latestVersion(_appId(petId));
    if (latest == null) return _json(<String, Object?>{'error': 'no such pet'}, 404);
    final rows = await db.q('SELECT name FROM apps WHERE app_id = ?', [_appId(petId)]);
    final String name = rows.isEmpty ? petId : (rows.first['name'] as String? ?? petId);
    final String host = request.headers['host'] ?? '127.0.0.1:7610';
    final int versionCode = latest['version_code'] as int;
    return _json(<String, Object?>{
      'petId': petId,
      'name': name,
      'version': latest['version_name'],
      'versionCode': versionCode,
      'packageUrl': _packageUrl(host, petId, versionCode),
      'sha256': latest['sha256'],
      'sizeBytes': latest['size_bytes'],
    });
  }

  /// GET /api/v1/pets/<petId>/versions — release history, newest first.
  Future<shelf.Response> _versions(shelf.Request request, String petId) async {
    if (!isValidPetId(petId)) return _json(<String, Object?>{'error': 'invalid petId'}, 400);
    return _json(<String, Object?>{
      'petId': petId,
      'versions': await store.versions(_appId(petId)),
    });
  }

  /// POST /api/v1/pets/<petId>/versions — raw zip body; metadata via headers:
  ///   authorization: Bearer <publisherKey>
  ///   x-pet-name-b64   (optional; base64 UTF-8 display name, else pack.json's
  ///                     name, else the petId)
  /// Identity comes from the zip itself: pack.json (top level or one top
  /// folder, exactly one candidate) must carry id == <petId> and a plausible
  /// version. The same version string re-published with different bytes is
  /// refused (workshop's version-rewritten rule); anything else just adds a
  /// new versionCode — the phone decides by version comparison what to
  /// install, so a mistaken downgrade publish stays possible and rollable.
  Future<shelf.Response> _publish(shelf.Request request, String petId) async {
    if (!_publisher(request)) return _json(<String, Object?>{'error': 'unauthorized'}, 401);
    if (!isValidPetId(petId)) return _json(<String, Object?>{'error': 'invalid petId'}, 400);

    final Uint8List bytes = await request.read().fold<BytesBuilder>(
        BytesBuilder(), (builder, chunk) => builder..add(chunk)).then((b) => b.takeBytes());
    if (bytes.isEmpty) return _json(<String, Object?>{'error': 'empty body'}, 400);
    if (bytes.length > _maxPackBytes) {
      return _json(<String, Object?>{'error': 'pack too large'}, 413);
    }

    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes, verify: true);
    } catch (_) {
      return _json(<String, Object?>{'error': 'body is not a zip'}, 400);
    }
    final ArchiveFile? packEntry = _packJsonEntry(archive);
    if (packEntry == null) {
      return _json(<String, Object?>{
        'error': 'zip must contain exactly one top-level (or one-folder) pack.json'
      }, 400);
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(
          Uint8List.fromList(packEntry.content as List<int>),
          allowMalformed: true));
    } catch (_) {
      return _json(<String, Object?>{'error': 'pack.json is not JSON'}, 400);
    }
    if (decoded is! Map<String, Object?>) {
      return _json(<String, Object?>{'error': 'pack.json must be an object'}, 400);
    }
    if (decoded['id'] != petId) {
      return _json(<String, Object?>{
        'error': 'pack.json id ${decoded['id']} does not match petId $petId'
      }, 400);
    }
    // The pack.json version is optional: today's packs don't carry one. When
    // present it must be plausible (the phone orders releases by it); when
    // absent every publish gets a synthetic rising version, so the phone's
    // comparison still sees each release as new.
    if (decoded['version'] != null && !isPlausibleVersion(decoded['version'])) {
      return _json(<String, Object?>{'error': 'pack.json version malformed'}, 400);
    }

    // Same version + different bytes must never exist side by side (the
    // phone refuses version_rewritten, so the release would be dead weight).
    final latest = await store.latestVersion(_appId(petId));
    final String sha256hex = sha256.convert(bytes).toString();
    final int versionCode = latest == null ? 1 : (latest['version_code'] as int) + 1;
    final String version =
        decoded['version'] as String? ?? '0.0.$versionCode';
    if (latest != null && latest['version_name'] == version && latest['sha256'] != sha256hex) {
      return _json(<String, Object?>{
        'error': 'version $version already published with different bytes'
      }, 409);
    }

    String? name;
    final String? nameB64 = request.headers['x-pet-name-b64'];
    if (nameB64 != null && nameB64.isNotEmpty) {
      try {
        name = utf8.decode(base64Decode(nameB64));
      } catch (_) {
        return _json(<String, Object?>{'error': 'x-pet-name-b64 is not base64 UTF-8'}, 400);
      }
    }
    name ??= decoded['name'] is String && (decoded['name'] as String).isNotEmpty
        ? decoded['name'] as String
        : petId;

    final File target = File(cfg.packagePath(_appId(petId), versionCode));
    await target.parent.create(recursive: true);
    final File tmp = File('${target.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(target.path);

    final String path = decoded['path'] is String ? decoded['path'] as String : 'pets/pack';
    await store.upsertApp(_appId(petId), name, path);
    await store.insertVersion(
      appId: _appId(petId),
      versionCode: versionCode,
      versionName: version,
      zipPath: target.path,
      sha256: sha256hex,
      sizeBytes: bytes.length,
    );
    // No app database, no tools manifest: those are mini-program concerns.
    await store.addEvent(_appId(petId), 'pet_publish', 'v$versionCode $version sha=$sha256hex');
    await db.audit('publisher', 'publish-pet', 'pet/$petId v$versionCode $version sha=$sha256hex');

    return _json(<String, Object?>{
      'petId': petId,
      'version': version,
      'versionCode': versionCode,
      'sha256': sha256hex,
      'sizeBytes': bytes.length,
    });
  }
}
