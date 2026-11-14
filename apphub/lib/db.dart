/// MariaDB access for AppHub: one pool connection, schema bootstrap, and the
/// tiny query helpers the market/gateway need. Uses mysql1 0.22's
/// prepared-statement `execute`; rows come back as string maps via assoc(),
/// so [Store] normalises types at its boundary.
library;

import 'dart:convert' show utf8;
import 'dart:typed_data' show Uint8List;

import 'package:mysql1/mysql1.dart'
    show Blob, ConnectionSettings, MySqlConnection, Result, ResultRow;

/// mysql1 0.22 values normalised for JSON: VARCHAR columns arrive as strings,
/// but TEXT/MEDIUMTEXT columns come back as [Blob] and TIMESTAMPs as
/// [DateTime] — neither is jsonEncode-able until converted here.
Object? _normalize(Object? value) {
  if (value is Blob) return value.toString();
  if (value is Uint8List) return utf8.decode(value, allowMalformed: true);
  if (value is DateTime) return value.toIso8601String();
  return value;
}

List<Map<String, Object?>> _rows(Result result) => <Map<String, Object?>>[
      for (final ResultRow row in result)
        <String, Object?>{
          for (final MapEntry<String, Object?> entry in row.toColumnMap().entries)
            entry.key: _normalize(entry.value),
        },
    ];

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

  /// Runs the query, returning rows as string-keyed maps with JSON-safe
  /// values (see [_normalize]). mysql1 0.22's query() substitutes [values]
  /// as literals (text protocol), so numeric columns arrive as strings —
  /// [Store] normalises the numeric ones at its boundary.
  Future<List<Map<String, Object?>>> q(String sql, [List<Object?>? values]) async =>
      _rows(await _c.query(sql, values));

  Future<void> exec(String sql, [List<Object?>? values]) async {
    await _c.query(sql, values);
  }

  /// 打开一个**独立连接**跑单个事务，事务体里的查询一律走 [DbTx]。
  ///
  /// 通知发送的「八步判定 + 落库」必须原子（契约 §4.2），但 [Db] 的长连接被
  /// 轮询/市场等无事务查询共用：若在长连接上 START TRANSACTION，别的请求的
  /// 写入会被卷进本事务，rollback 时一起丢。独立连接让事务边界干净，代价是
  /// 每条通知一次建连（发送频率低，可接受）。
  Future<T> transaction<T>(Future<T> Function(DbTx tx) body) async {
    final MySqlConnection conn = await MySqlConnection.connect(_settings);
    final DbTx tx = DbTx._(conn);
    try {
      await tx.exec('START TRANSACTION');
      final T result = await body(tx);
      await tx.exec('COMMIT');
      return result;
    } catch (_) {
      try {
        await tx.exec('ROLLBACK');
      } catch (_) {
        // 连接已断时 ROLLBACK 也会失败，交给 rethrow 报原始错误。
      }
      rethrow;
    } finally {
      await conn.close();
    }
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
        'icon_file VARCHAR(128) NULL,'
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

    // ---- 通知系统四表（契约 dimina-notify-contract §3.1 原样）----
    // 模板登记：小程序声明 → AppHub 发 id（等价微信「选用模板」，省掉审核）。
    await exec('CREATE TABLE IF NOT EXISTS notify_templates ('
        'template_id VARCHAR(64) PRIMARY KEY,'
        'app_id VARCHAR(64) NOT NULL,'
        'name VARCHAR(64) NOT NULL,'
        'fields_json TEXT NOT NULL,'
        'created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,'
        'UNIQUE KEY uk_app_name (app_id, name))');
    // 订阅记账：一次性配额，单机 user_id 固定 'local'。
    await exec('CREATE TABLE IF NOT EXISTS notify_subscriptions ('
        'app_id VARCHAR(64) NOT NULL,'
        'template_id VARCHAR(64) NOT NULL,'
        'user_id VARCHAR(64) NOT NULL DEFAULT "local",'
        'remain INT NOT NULL DEFAULT 0,'
        'updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,'
        'PRIMARY KEY (app_id, template_id, user_id))');
    // 用户级总开关：scope = 'global' | 'app:<appId>'。
    await exec('CREATE TABLE IF NOT EXISTS notify_prefs ('
        'scope VARCHAR(64) PRIMARY KEY,'
        'enabled TINYINT NOT NULL DEFAULT 1)');
    // 通知对象：替代旧「往 install_events 塞字符串」的做法（§3.1）。
    await exec('CREATE TABLE IF NOT EXISTS notify_messages ('
        'id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,'
        'app_id VARCHAR(64) NOT NULL,'
        'template_id VARCHAR(64) NOT NULL,'
        'title VARCHAR(128) NOT NULL,'
        'body VARCHAR(512) NOT NULL,'
        'page VARCHAR(512) NULL,'
        'miniprogram_state VARCHAR(16) NOT NULL DEFAULT "formal",'
        'dedupe_key VARCHAR(128) NULL,'
        'read_at TIMESTAMP NULL,'
        'dismissed_at TIMESTAMP NULL,'
        'created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,'
        'KEY idx_app_created (app_id, created_at),'
        'KEY idx_read (read_at),'
        // 去重幂等的兜底：同 app + 同 dedupe_key 只能有一条（NULL 可重复）。
        // 没有它时「先查再插」在并发重试下会各插一条，幂等就漏了（E2E 实测）。
        'UNIQUE KEY uk_app_dedupe (app_id, dedupe_key))');

    // 轻量迁移:老库补列(列已存在时忽略报错)。
    for (final String sql in <String>[
      'ALTER TABLE apps ADD COLUMN description VARCHAR(256) NULL',
      'ALTER TABLE apps ADD COLUMN category VARCHAR(32) NULL',
      'ALTER TABLE app_versions ADD COLUMN changelog MEDIUMTEXT NULL',
      'ALTER TABLE app_versions ADD COLUMN icon VARCHAR(16) NULL',
      'ALTER TABLE app_versions ADD COLUMN icon_file VARCHAR(128) NULL',
      // Bundle 制图标(2026-11-10):icon 从 iconKey(≤16 字符)升格为可存
      // bundle 图标文件名(<appId>-<versionCode>-icon.png,27+ 字符)。
      // MODIFY 幂等,每次启动重跑无害。
      'ALTER TABLE app_versions MODIFY icon VARCHAR(128) NULL',
      // 商店详情元数据(2026-11-10):main/store.json 白名单化后的整包 JSON,
      // 读取侧解析失败一律按"无详情"降级,所以列保持可空、不设默认值。
      'ALTER TABLE app_versions ADD COLUMN listing_json TEXT NULL',
      // 通知契约 §3.4:consent 的 reject 要「记 itemSettings=reject」，而 §3.1
      // 的 notify_subscriptions 没有这一列。补一列（幂等）承载最近一次
      // accept/reject 结果；accept 的配额记账仍只靠 remain。
      'ALTER TABLE notify_subscriptions ADD COLUMN item_status VARCHAR(16) NULL',
      // 通知落库去重的唯一索引（幂等兜底 + 去重键精确查找），老库补索引；
      // 已有重复 key 时 ALTER 会失败并被忽略，此时退回「先查再插」的尽力去重。
      'ALTER TABLE notify_messages ADD UNIQUE KEY uk_app_dedupe (app_id, dedupe_key)',
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

/// 事务上下文：只由 [Db.transaction] 创建，事务体内的查询必须走这里，
/// 否则（走 [Db]）会落在另一条连接上，不受事务保护。
class DbTx {
  DbTx._(this._conn);

  final MySqlConnection _conn;

  Future<List<Map<String, Object?>>> q(String sql, [List<Object?>? values]) async =>
      _rows(await _conn.query(sql, values));

  Future<void> exec(String sql, [List<Object?>? values]) async {
    await _conn.query(sql, values);
  }

  /// 执行并返回受影响行数（INSERT IGNORE 判重、UPDATE 统计用）。
  Future<int> execAffected(String sql, [List<Object?>? values]) async {
    final Result result = await _conn.query(sql, values);
    return result.affectedRows;
  }

  Future<void> audit(String actor, String action, String detail) =>
      exec('INSERT INTO audit_log (actor, action, detail) VALUES (?, ?, ?)',
          [actor, action, detail]);
}
