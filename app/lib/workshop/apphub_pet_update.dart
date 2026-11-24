// AppHub 宠物源自动更新:家端(引擎主机上的 AppHub)发布的宠物包,冷启动与
// 宠物设置页各拉起一次,没有定时器——调用方决定何时跑(与工坊
// runWorkshopAutoUpdate 同一档位)。目录来自 `GET <appHubBase>/api/v1/pets`,
// 包是 `POST /api/v1/pets/<petId>/versions` 发布的 schema-1 zip;完整校验在
// 安装路径(PetLibrary)里做,这里只做身份与 sha256。
//
// 语义(2026-11-24 用户拍板):家端主权——目录里有什么,手机上就该是什么。
// 手机没有的宠物会被装上,已装的被新版替换(包括从创意工坊或手工导入装的
// 同 id 宠物);家端把一只宠物撤下后手机上仍留着(不主动卸载),直到用户
// 自己删。AppHub 不在家(网络失败、非 200)整体静默跳过:这是常态而不是
// 故障,冷启动不能因此打扰。
//
// 版本与免下载:每只装过的宠物目录里留 `.apphub-pet.json`(版本+sha256)。
// 目录行的 sha256 与记录相同就跳过;否则按 WorkshopVersion 比较决定是否换
// 包。没有记录(第一次纳管,或工坊/手工装的同 id 宠物)直接装——家端优先。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

import '../pets/pet_library.dart';
import '../update/update_http.dart';
import 'workshop_models.dart';

/// One row of `GET /api/v1/pets`.
class AppHubPetEntry {
  AppHubPetEntry({
    required this.petId,
    required this.name,
    required this.version,
    required this.versionCode,
    required this.packageUrl,
    required this.sha256,
  });

  final String petId;
  final String name;
  final String version;
  final int versionCode;
  final Uri packageUrl;
  final String sha256;

  /// Server rows that can't be trusted never reach the install loop; one bad
  /// row never hides its neighbours.
  static AppHubPetEntry? tryParse(Object? value) {
    if (value is! Map<String, Object?>) return null;
    final Object? petId = value['petId'];
    final Object? version = value['version'];
    final Object? url = value['packageUrl'];
    final Object? sha = value['sha256'];
    if (petId is! String || petId.isEmpty || petId.length > 40) return null;
    if (!RegExp(r'^[a-z0-9][a-z0-9-]{0,39}$').hasMatch(petId)) return null;
    // The ordering rules are the workshop's (the server stores the same
    // string the pack.json carries); unparseable rows are skipped here.
    if (WorkshopVersion.tryParse(version) == null) return null;
    if (url is! String) return null;
    final Uri? packageUrl = Uri.tryParse(url);
    if (packageUrl == null || !packageUrl.hasScheme || packageUrl.path.isEmpty) return null;
    if (sha is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha)) return null;
    final Object? versionCode = value['versionCode'];
    return AppHubPetEntry(
      petId: petId,
      name: value['name'] is String && (value['name'] as String).isNotEmpty
          ? value['name'] as String
          : petId,
      version: version as String,
      versionCode: versionCode is int ? versionCode : 0,
      packageUrl: packageUrl,
      sha256: sha,
    );
  }
}

/// What one pass did, same reporting shape as the workshop pass (the settings
/// page shows both as one count).
class AppHubPetUpdateResult {
  const AppHubPetUpdateResult({
    required this.updated,
    required this.skipped,
    required this.errors,
  });
  final List<String> updated;

  /// Stable reason codes by `pet/<petId>`.
  final Map<String, String> skipped;

  /// One pack's failure never stops its neighbours; the error stays here
  /// keyed the same way, and is not swallowed.
  final Map<String, Object> errors;

  bool get quiet => updated.isEmpty && errors.isEmpty;
}

/// The `.apphub-pet.json` kept beside the installed pack — the phone-side
/// counterpart of the server's catalog row. Never inside an exported archive
/// (PetLibrary keeps only the manifest and the sheets it names).
const appHubPetRecordName = '.apphub-pet.json';

Future<Map<String, Object?>?> _readRecord(Directory petDir) async {
  final file = File('${petDir.path}/$appHubPetRecordName');
  if (!await file.exists()) return null;
  try {
    if (await file.length() > 4096) return null;
    final Object? decoded = jsonDecode(await file.readAsString());
    if (decoded is Map<String, Object?> &&
        decoded['version'] is String &&
        decoded['sha256'] is String) {
      return decoded;
    }
  } on Object {
    // Unreadable or half-written: treat as no record, the pack decides.
  }
  return null;
}

Future<void> _writeRecord(Directory petDir, AppHubPetEntry entry) async {
  await File('${petDir.path}/$appHubPetRecordName').writeAsString(jsonEncode(<String, Object?>{
    'schema': 1,
    'petId': entry.petId,
    'version': entry.version,
    'versionCode': entry.versionCode,
    'sha256': entry.sha256,
  }), flush: true);
}

/// Runs one pass. [base] is the AppHub base the rest of the app already uses
/// (`appHubBase` — loopback, LAN IP or the SSH tunnel forward). [http] is the
/// shared update transport seam; the pass owns no timer and no retry.
/// [skipPetIds] are ids the APK ships built-in (assets/pets/): those belong
/// to the app store update channel, the home side never shadows them
/// (2026-11-24 用户拍板), so a same-id home release is skipped with the
/// `apphub_builtin` reason instead of installing a duplicate.
///
/// Every catalog-level failure (unreachable, non-200, bad JSON) resolves to a
/// quiet empty result: the home server being away is normal, not an error to
/// surface. Only per-pack failures land in [AppHubPetUpdateResult.errors].
Future<AppHubPetUpdateResult> runAppHubPetAutoUpdate({
  required PetLibrary pets,
  required Uri base,
  UpdateHttp? http,
  Set<String> skipPetIds = const <String>{},
  Duration timeout = const Duration(seconds: 15),
}) async {
  final UpdateHttp transport = http ?? IoUpdateHttp();

  final List<AppHubPetEntry> catalog;
  try {
    final UpdateHttpResponse response =
        await transport.get(base.resolve('/api/v1/pets'), timeout: timeout);
    if (response.status != 200) return _empty;
    final Object? decoded = jsonDecode(await response.text(maxBytes: 2 * 1024 * 1024));
    if (decoded is! Map<String, Object?> || decoded['pets'] is! List) {
      return _empty;
    }
    catalog = <AppHubPetEntry>[
      for (final dynamic row in decoded['pets'] as List)
        if (AppHubPetEntry.tryParse(row) case final AppHubPetEntry entry) entry,
    ];
  } on Object {
    return _empty;
  }
  final updated = <String>[];
  final skipped = <String, String>{};
  final errors = <String, Object>{};

  for (final AppHubPetEntry entry in catalog) {
    final String identity = 'pet/${entry.petId}';
    if (skipPetIds.contains(entry.petId)) {
      // APK ships this one; the home release never shadows the built-in.
      skipped[identity] = 'apphub_builtin';
      continue;
    }
    try {
      final String folderId = '$userPetPrefix${entry.petId}';
      final Directory petDir = await pets.folder(folderId);
      final Map<String, Object?>? record = await _readRecord(petDir);
      if (record != null) {
        if (record['sha256'] == entry.sha256) {
          skipped[identity] = 'workshop_up_to_date';
          continue;
        }
        final WorkshopVersion? installed =
            WorkshopVersion.tryParse(record['version']);
        final WorkshopVersion? incoming = WorkshopVersion.tryParse(entry.version);
        if (installed != null && incoming != null && incoming.compareTo(installed) <= 0) {
          skipped[identity] = 'workshop_up_to_date';
          continue;
        }
      }
      // No record: the pack isn't managed by this source yet (first bring,
      // or installed from the workshop or by hand) — the home side wins.
      await _installOne(pets, transport, entry, timeout);
      updated.add(entry.petId);
    } on PetImportException catch (error) {
      errors[identity] = error.problem.name;
    } on WorkshopException catch (error) {
      errors[identity] = error.code;
    } on Object catch (error) {
      errors[identity] = error.toString();
    }
  }
  return AppHubPetUpdateResult(updated: updated, skipped: skipped, errors: errors);
}

const AppHubPetUpdateResult _empty =
    AppHubPetUpdateResult(updated: <String>[], skipped: <String, String>{}, errors: <String, Object>{});

/// Downloads the pack, verifies its digest and hands it to the ordinary
/// install path — full schema-1 validation happens there, and
/// [PetLibrary.install] with `replaceExisting: true` replaces any same-id
/// pack regardless of where it came from (workshop receipts are not
/// consulted on this path: this source owns the pet now).
Future<void> _installOne(
  PetLibrary pets,
  UpdateHttp transport,
  AppHubPetEntry entry,
  Duration timeout,
) async {
  final UpdateHttpResponse response =
      await transport.get(entry.packageUrl, timeout: timeout);
  if (response.status != 200) {
    throw WorkshopException('workshop_download_failed');
  }
  final bytes = <int>[];
  await for (final List<int> chunk in response.body.timeout(timeout)) {
    bytes.addAll(chunk);
    // The schema-1 limits cap expansion at 64 MiB; the zip itself is far
    // smaller (real packs are ≤2 MiB). Refuse bigger bodies outright.
    if (bytes.length > 64 * 1024 * 1024) {
      await response.discard();
      throw WorkshopException('workshop_download_failed');
    }
  }
  final String digest = crypto.sha256.convert(bytes).toString();
  if (digest != entry.sha256) {
    throw WorkshopException('workshop_checksum_failed');
  }
  final String fileName = entry.packageUrl.pathSegments.where((s) => s.isNotEmpty).last;
  final File staging = File(
      '${(await Directory.systemTemp.createTemp('apphub-pet')).path}/$fileName');
  try {
    await staging.writeAsBytes(bytes, flush: true);
    final ({String id, bool replaced}) result =
        await pets.install(staging, replaceExisting: true);
    await _writeRecord(await pets.folder(result.id), entry);
  } finally {
    try {
      if (await staging.exists()) await staging.delete();
    } on Object {
      // Best-effort cleanup; the temp dir is discarded anyway.
    }
  }
}
