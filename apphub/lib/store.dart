/// Market data access over [Db]: apps, versions, routes, events, and the
/// per-app MariaDB provisioning (schema `app_<appId>` + dedicated user).
/// mysql1's assoc() hands back strings, so every integer column is normalised
/// here — callers see plain ints/strings.
library;

import 'db.dart';

/// Same character set as dsh-go's applet ids: lowercase letters, digits and
/// hyphens; this doubles as the MariaDB schema suffix, so stay strict here.
bool isValidAppId(String id) => RegExp(r'^[a-z0-9][a-z0-9-]{0,62}$').hasMatch(id);

int? _int(Object? value) =>
    value == null ? null : value is int ? value : int.tryParse(value.toString());

class Store {
  Store(this.db);

  final Db db;

  Future<void> upsertApp(String appId, String name, String path,
      {String? description, String? category}) async {
    await db.exec(
        'INSERT INTO apps (app_id, name, path, description, category) VALUES (?, ?, ?, ?, ?) '
        'ON DUPLICATE KEY UPDATE name = VALUES(name), path = VALUES(path), '
        'description = VALUES(description), category = VALUES(category)',
        [appId, name, path, description, category]);
  }

  Future<void> insertVersion({
    required String appId,
    required int versionCode,
    required String versionName,
    required String zipPath,
    required String sha256,
    required int sizeBytes,
    String? changelog,
    String? icon,
    String? toolsJson,
    String? minContainer,
  }) async {
    await db.exec(
        'INSERT INTO app_versions '
        '(app_id, version_code, version_name, zip_path, sha256, size_bytes, changelog, icon, tools_json, min_container) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [appId, versionCode, versionName, zipPath, sha256, sizeBytes, changelog, icon, toolsJson, minContainer]);
  }

  Future<Map<String, Object?>?> latestVersion(String appId) async {
    final List<Map<String, Object?>> rows = await db.q(
        'SELECT * FROM app_versions WHERE app_id = ? ORDER BY version_code DESC LIMIT 1',
        [appId]);
    return rows.isEmpty
        ? null
        : <String, Object?>{
            'app_id': rows.first['app_id'],
            'version_code': _int(rows.first['version_code']),
            'version_name': rows.first['version_name'],
            'zip_path': rows.first['zip_path'],
            'sha256': rows.first['sha256'],
            'size_bytes': _int(rows.first['size_bytes']),
            'tools_json': rows.first['tools_json'],
            'min_container': rows.first['min_container'],
          };
  }

  /// The newest version strictly below [belowVersionCode] — rollback's donor.
  Future<Map<String, Object?>?> versionBelow(String appId, int belowVersionCode) async {
    final List<Map<String, Object?>> rows = await db.q(
        'SELECT * FROM app_versions WHERE app_id = ? AND version_code < ? '
        'ORDER BY version_code DESC LIMIT 1',
        [appId, belowVersionCode]);
    return rows.isEmpty
        ? null
        : <String, Object?>{
            'version_code': _int(rows.first['version_code']),
            'version_name': rows.first['version_name'],
            'zip_path': rows.first['zip_path'],
            'sha256': rows.first['sha256'],
            'size_bytes': _int(rows.first['size_bytes']),
            'tools_json': rows.first['tools_json'],
            'min_container': rows.first['min_container'],
          };
  }

  Future<List<Map<String, Object?>>> listApps() async {
    final List<Map<String, Object?>> rows = await db.q(
        'SELECT a.app_id, a.name, a.path, a.category, a.created_at, '
        'v.version_code, v.version_name, v.sha256, v.changelog, v.icon '
        'FROM apps a LEFT JOIN app_versions v '
        'ON v.app_id = a.app_id AND v.version_code = '
        '(SELECT MAX(version_code) FROM app_versions WHERE app_id = a.app_id) '
        'ORDER BY a.name');
    return <Map<String, Object?>>[
      for (final row in rows)
        <String, Object?>{
          'appId': row['app_id'],
          'name': row['name'],
          'path': row['path'],
          'category': row['category'],
          'versionCode': _int(row['version_code']),
          'versionName': row['version_name'],
          'sha256': row['sha256'],
          'changelog': row['changelog'],
          'icon': row['icon'],
        },
    ];
  }

  Future<void> setLatestTools(String appId, String toolsJson) async {
    await db.exec(
        'UPDATE app_versions SET tools_json = ? '
        'WHERE app_id = ? AND version_code = '
        '(SELECT version_code FROM (SELECT MAX(version_code) AS version_code '
        'FROM app_versions WHERE app_id = ?) t)',
        [toolsJson, appId, appId]);
  }

  Future<void> addEvent(String appId, String event, String? detail) async {
    await db.exec(
        'INSERT INTO install_events (app_id, event, detail) VALUES (?, ?, ?)',
        [appId, event, detail]);
  }

  Future<void> upsertRoute(String appId, String prefix, String target,
      int timeoutMs, int rpm) async {
    await db.exec(
        'INSERT INTO app_routes (app_id, prefix, target, timeout_ms, rpm) '
        'VALUES (?, ?, ?, ?, ?) '
        'ON DUPLICATE KEY UPDATE target = VALUES(target), '
        'timeout_ms = VALUES(timeout_ms), rpm = VALUES(rpm)',
        [appId, prefix, target, timeoutMs, rpm]);
  }

  Future<void> deleteRoute(String appId, String prefix) async {
    await db.exec('DELETE FROM app_routes WHERE app_id = ? AND prefix = ?',
        [appId, prefix]);
  }

  Future<List<Map<String, Object?>>> listRoutes() async {
    final List<Map<String, Object?>> rows =
        await db.q('SELECT * FROM app_routes ORDER BY app_id, prefix');
    return <Map<String, Object?>>[
      for (final row in rows)
        <String, Object?>{
          'appId': row['app_id'],
          'prefix': row['prefix'],
          'target': row['target'],
          'timeoutMs': _int(row['timeout_ms']),
          'rpm': _int(row['rpm']),
        },
    ];
  }

  /// Best-effort per-app database: schema `app_<appId>` owned by a dedicated
  /// user. Requires the AppHub DB user to hold CREATE/DROP grants (localhost
  /// setup grants ALL). Failures are non-fatal — backends may also bring
  /// their own database.
  Future<String?> provisionAppDb(String appId, String password) async {
    try {
      final String schema = 'app_$appId';
      final String user = 'app_$appId';
      await db.exec('CREATE DATABASE IF NOT EXISTS `$schema` CHARACTER SET utf8mb4');
      await db.exec(
          'CREATE USER IF NOT EXISTS `$user`@`localhost` IDENTIFIED BY ?', [password]);
      await db.exec('ALTER USER `$user`@`localhost` IDENTIFIED BY ?', [password]);
      await db.exec('GRANT ALL PRIVILEGES ON `$schema`.* TO `$user`@`localhost`');
      return schema;
    } catch (_) {
      return null;
    }
  }
}
