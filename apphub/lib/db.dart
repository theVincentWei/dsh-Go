/// MariaDB access for AppHub: one pool connection, schema bootstrap, and the
/// tiny query helpers the market/gateway need. Uses mysql1 0.22's
/// prepared-statement `execute`; rows come back as string maps via assoc(),
/// so [Store] normalises types at its boundary.
library;

import 'dart:convert' show utf8;
import 'dart:typed_data' show Uint8List;

import 'package:mysql1/mysql1.dart'
    show Blob, ConnectionSettings, MySqlConnection, Result, ResultRow;

class Db {
  Db(this._settings);

  final ConnectionSettings _settings;
  MySqlConnection? _conn;

  Future<void> connect() async {
    _conn = await MySqlConnection.connect(_settings);
  }

  MySqlConnection get _c {
    final MySqlConnection? conn = _conn;
    if (conn == null) throw StateError('db not connected');
    return conn;
  }

  /// Normalises mysql1 0.22 values for JSON: VARCHAR columns arrive as
  /// strings, but TEXT/MEDIUMTEXT columns come back as [Blob] and TIMESTAMPs
  /// as [DateTime] — neither is jsonEncode-able until converted here.
  Object? _normalize(Object? value) {
    if (value is Blob) return value.toString();
    if (value is Uint8List) return utf8.decode(value, allowMalformed: true);
    if (value is DateTime) return value.toIso8601String();
    return value;
  }

  /// Runs the query, returning rows as string-keyed maps with JSON-safe
  /// values (see [_normalize]). mysql1 0.22's query() substitutes [values]
  /// as literals (text protocol), so numeric columns arrive as strings —
  /// [Store] normalises the numeric ones at its boundary.
  Future<List<Map<String, Object?>>> q(String sql, [List<Object?>? values]) async {
    final Result result = await _c.query(sql, values);
    return <Map<String, Object?>>[
      for (final ResultRow row in result)
        {
          for (final MapEntry<String, Object?> entry in row.toColumnMap().entries)
            entry.key: _normalize(entry.value),
        },
    ];
  }

  Future<void> exec(String sql, [List<Object?>? values]) async {
    await _c.query(sql, values);
  }

  Future<void> initSchema() async {
    await exec('CREATE TABLE IF NOT EXISTS apps ('
        'app_id VARCHAR(64) PRIMARY KEY,'
        'name VARCHAR(128) NOT NULL,'
        'path VARCHAR(256) NOT NULL,'
        'description VARCHAR(256) NULL,'
        'category VARCHAR(32) NULL,'
        'channel VARCHAR(16) NOT NULL DEFAULT "stable",'
        'created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)');
    await exec('CREATE TABLE IF NOT EXISTS app_versions ('
        'app_id VARCHAR(64) NOT NULL,'
        'version_code INT NOT NULL,'
        'version_name VARCHAR(32) NOT NULL,'
        'zip_path VARCHAR(512) NOT NULL,'
        'sha256 CHAR(64) NOT NULL,'
        'size_bytes INT NOT NULL DEFAULT 0,'
        'changelog MEDIUMTEXT NULL,'
        'icon VARCHAR(16) NULL,'
        'tools_json MEDIUMTEXT NULL,'
        'min_container VARCHAR(32) NULL,'
        'created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,'
        'PRIMARY KEY (app_id, version_code))');
    await exec('CREATE TABLE IF NOT EXISTS app_routes ('
        'app_id VARCHAR(64) NOT NULL,'
        'prefix VARCHAR(128) NOT NULL,'
        'target VARCHAR(512) NOT NULL,'
        'scopes_json TEXT NULL,'
        'timeout_ms INT NOT NULL DEFAULT 5000,'
        'rpm INT NOT NULL DEFAULT 120,'
        'PRIMARY KEY (app_id, prefix))');
    await exec('CREATE TABLE IF NOT EXISTS app_tokens ('
        'app_id VARCHAR(64) NOT NULL,'
        'token VARCHAR(80) PRIMARY KEY,'
        'ai_daily_tokens INT NOT NULL DEFAULT 200000,'
        'created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)');
    await exec('CREATE TABLE IF NOT EXISTS ai_usage ('
        'app_id VARCHAR(64) NOT NULL,'
        'ts TIMESTAMP DEFAULT CURRENT_TIMESTAMP,'
        'tokens INT NOT NULL)');
    await exec('CREATE TABLE IF NOT EXISTS install_events ('
        'id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,'
        'app_id VARCHAR(64) NOT NULL,'
        'event VARCHAR(32) NOT NULL,'
        'detail TEXT NULL,'
        'ts TIMESTAMP DEFAULT CURRENT_TIMESTAMP)');
    // 轻量迁移:老库补列(列已存在时忽略报错)。
    for (final String sql in <String>[
      'ALTER TABLE apps ADD COLUMN description VARCHAR(256) NULL',
      'ALTER TABLE apps ADD COLUMN category VARCHAR(32) NULL',
      'ALTER TABLE app_versions ADD COLUMN changelog MEDIUMTEXT NULL',
      'ALTER TABLE app_versions ADD COLUMN icon VARCHAR(16) NULL',
    ]) {
      try {
        await exec(sql);
      } catch (_) {}
    }
    await exec('CREATE TABLE IF NOT EXISTS audit_log ('
        'id BIGINT AUTO_INCREMENT PRIMARY KEY,'
        'ts TIMESTAMP DEFAULT CURRENT_TIMESTAMP,'
        'actor VARCHAR(64) NOT NULL,'
        'action VARCHAR(128) NOT NULL,'
        'detail TEXT NULL)');
  }

  Future<void> audit(String actor, String action, String detail) async {
    await exec('INSERT INTO audit_log (actor, action, detail) VALUES (?, ?, ?)',
        [actor, action, detail]);
  }
}
