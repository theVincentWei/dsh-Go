/// 通知相关的 SQL 封装：app token 鉴权、模板登记、订阅配额、偏好开关、
/// 通知对象、限流计数。
///
/// **事务边界在这里**（契约 §4.2「判定与落库必须同一事务，防并发超发」）：
/// [send] 用 [Db.transaction] 的独立连接，先 `INSERT IGNORE` + `SELECT … FOR
/// UPDATE` 锁住 (app, template, local) 配额行，再在同一事务内完成
/// 去重/配额/限流判定与落库。notices.dart 只负责 HTTP 形状。
library;

import 'dart:convert' show base64Url, jsonEncode;
import 'dart:math' show Random;

import 'db.dart';
import 'notify_logic.dart';

int? _int(Object? value) =>
    value == null ? null : value is int ? value : int.tryParse(value.toString());

/// 发送结果：errcode/errmsg 直接映射到契约 §2.4 的响应体。
class SendOutcome {
  const SendOutcome({required this.errcode, required this.errmsg, this.dedupe = false});

  final int errcode;
  final String errmsg;

  /// dedupe_key 幂等命中：返回 0，但没有落新行、没有扣配额。
  final bool dedupe;

  bool get ok => errcode == 0;
}

class NotifyStore {
  NotifyStore(this.db);

  final Db db;

  // -------------------------------------------------------------------------
  // 鉴权：app_tokens 的 per-app token（契约 §5.4）
  // -------------------------------------------------------------------------

  /// 发送鉴权用 app_tokens 里的 per-app token（Bearer）；不再用
  /// 「该 app 至少有一条网关路由」当代理门槛（旧实现 §9.2 的洞）。
  Future<bool> tokenBelongsTo(String token, String appId) async {
    if (token.isEmpty) return false;
    final List<Map<String, Object?>> rows = await db.q(
        'SELECT 1 AS ok FROM app_tokens WHERE token = ? AND app_id = ? LIMIT 1',
        [token, appId]);
    return rows.isNotEmpty;
  }

  /// 发放/读取 app token（发布者密钥保护的管理入口用）。
  /// app_tokens 此前只有建表没有发放流程；这里补上「有就返回、没有就生成」，
  /// 保证 P2 联调有 token 可用，且不新增密钥体系。
  Future<String> issueToken(String appId) async {
    final List<Map<String, Object?>> existing = await db.q(
        'SELECT token FROM app_tokens WHERE app_id = ? ORDER BY created_at LIMIT 1',
        [appId]);
    if (existing.isNotEmpty) return existing.first['token'] as String;
    final String token = _newToken();
    try {
      await db.exec('INSERT INTO app_tokens (app_id, token) VALUES (?, ?)', [appId, token]);
    } catch (_) {
      // 并发发放同 app 撞了：回读先插入的那条。
      final List<Map<String, Object?>> again = await db.q(
          'SELECT token FROM app_tokens WHERE app_id = ? ORDER BY created_at LIMIT 1',
          [appId]);
      if (again.isNotEmpty) return again.first['token'] as String;
      rethrow;
    }
    await db.audit('publisher', 'token.issue', appId);
    return token;
  }

  String _newToken() {
    final Random random = Random.secure();
    final List<int> bytes = List<int>.generate(24, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  // -------------------------------------------------------------------------
  // 模板登记（契约 §3.2）
  // -------------------------------------------------------------------------

  Future<Map<String, Object?>?> findTemplate(String appId, String templateId) async {
    final List<Map<String, Object?>> rows = await db.q(
        'SELECT template_id, app_id, name, fields_json FROM notify_templates '
        'WHERE template_id = ? AND app_id = ? LIMIT 1',
        [templateId, appId]);
    return rows.isEmpty ? null : rows.first;
  }

  /// 登记模板，幂等：同 app 同 name 返回已存在的 id；字段变更复用 id 并更新
  /// fields_json（契约 §3.2）。
  Future<String> registerTemplate(
      String appId, String name, List<Map<String, Object?>> fields) async {
    final String fieldsJson = jsonEncode(fields);
    return db.transaction<String>((DbTx tx) async {
      final List<Map<String, Object?>> existing = await tx.q(
          'SELECT template_id, fields_json FROM notify_templates '
          'WHERE app_id = ? AND name = ? LIMIT 1 FOR UPDATE',
          [appId, name]);
      if (existing.isNotEmpty) {
        final String templateId = existing.first['template_id'] as String;
        if ((existing.first['fields_json'] as String? ?? '') != fieldsJson) {
          await tx.exec('UPDATE notify_templates SET fields_json = ? WHERE template_id = ?',
              [fieldsJson, templateId]);
          await tx.audit('notify', 'template.update', '$appId $templateId');
        }
        return templateId;
      }
      final String templateId = templateIdFor(appId, name);
      // ON DUPLICATE KEY 覆盖「并发同名登记」：uk_app_name 命中时改写字段；
      // template_id 碰撞（同 app 内哈希撞车）概率可忽略，且 hash 含 appId。
      await tx.exec(
          'INSERT INTO notify_templates (template_id, app_id, name, fields_json) '
          'VALUES (?, ?, ?, ?) ON DUPLICATE KEY UPDATE fields_json = VALUES(fields_json)',
          [templateId, appId, name, fieldsJson]);
      final List<Map<String, Object?>> rows = await tx.q(
          'SELECT template_id FROM notify_templates WHERE app_id = ? AND name = ? LIMIT 1',
          [appId, name]);
      final String actual = rows.isEmpty ? templateId : rows.first['template_id'] as String;
      await tx.audit('notify', 'template.register', '$appId $actual $name');
      return actual;
    });
  }

  Future<List<Map<String, Object?>>> listTemplates(String appId) async {
    final List<Map<String, Object?>> rows = await db.q(
        'SELECT template_id, name, fields_json FROM notify_templates '
        'WHERE app_id = ? ORDER BY name',
        [appId]);
    return <Map<String, Object?>>[
      for (final Map<String, Object?> row in rows)
        <String, Object?>{
          'template_id': row['template_id'],
          'name': row['name'],
          'fields': decodeTemplateFields(row['fields_json']),
        },
    ];
  }

  // -------------------------------------------------------------------------
  // 发送（契约 §4.2 八步 + §4.2 同一事务）
  // -------------------------------------------------------------------------

  /// 发送一条通知。调用前 HTTP 层已完成：appId 合法性、token 鉴权（第 1 步）、
  /// 模板是否存在（第 2 步）。其余步骤全部在**同一事务**内按契约顺序判定，
  /// 通过后再落库 + 扣配额 + 写 audit。
  ///
  /// [argumentError] 是第 4 步（miniprogram_state / page）的字段名，故意不在
  /// HTTP 层短路，交给 [decideSend] 保证「data 错误先于参数错误」的顺序。
  Future<SendOutcome> send({
    required String appId,
    required String templateId,
    required Map<String, Object?> template,
    required Object? data,
    required String miniprogramState,
    required String? argumentError,
    String? page,
    String? dedupeKey,
  }) async {
    return db.transaction<SendOutcome>((DbTx tx) async {
      // 配额行加锁（第 6 步）：SELECT … FOR UPDATE 让同
      // (app, template, local) 的并发发送串行化，防超发。
      // 故意放在事务的第一条：先拿锁、再建立一致性读视图。若先做别的普通
      // SELECT 建了快照、再拿锁，MariaDB 在随后 UPDATE 这行时会报 Error 1020
      // "Record has changed since last read"（E2E 并发实测）。
      final int remain = await _lockedRemain(tx, appId, templateId);
      // 第 5 步：用户级/应用级总开关。缺行按开启处理。
      final bool prefsEnabled = await _prefsEnabled(tx, appId);
      // 第 8 步的幂等分支：同 app + dedupe_key 24h 内只落一条。
      // 先做一次普通查询快速返回；真正的并发保底靠 uk_app_dedupe 唯一索引 +
      // INSERT IGNORE（下面 affectedRows==0 即命中），避免「先查再插」的竞态。
      final String? key = (dedupeKey == null || dedupeKey.isEmpty) ? null : dedupeKey;
      final bool dedupeHit = key != null && await _dedupeHit(tx, appId, key);
      // 第 7 步：限流（每 app 每分钟 20 条、每日 200 条）。
      final bool rateLimited = await _rateLimited(tx, appId);

      final SendDecision decision = decideSend(
        tokenValid: true,
        template: template,
        data: data,
        argumentError: argumentError,
        prefsEnabled: prefsEnabled,
        remain: remain,
        rateLimited: rateLimited,
        dedupeHit: dedupeHit,
      );
      if (!decision.ok) {
        return SendOutcome(errcode: decision.errcode, errmsg: decision.errmsg);
      }
      if (decision.dedupe) {
        return const SendOutcome(errcode: 0, errmsg: 'ok', dedupe: true);
      }

      // 第 8 步：落 notify_messages + remain-1 + audit。
      final List<Map<String, Object?>> fields =
          decodeTemplateFields(template['fields_json']);
      final String title = messageTitle(template['name'] as String? ?? '');
      final String body = messageBody(fields, data);
      // INSERT IGNORE + 唯一索引：并发重试同一 dedupe_key 时只有一条能落库，
      // 另一条 affectedRows==0 按幂等命中处理（不扣配额、不重复写 audit）。
      final int inserted = await tx.execAffected(
          'INSERT IGNORE INTO notify_messages '
          '(app_id, template_id, title, body, page, miniprogram_state, dedupe_key) '
          'VALUES (?, ?, ?, ?, ?, ?, ?)',
          [appId, templateId, title, body, page, miniprogramState, key]);
      if (inserted == 0) {
        return const SendOutcome(errcode: 0, errmsg: 'ok', dedupe: true);
      }
      await tx.exec(
          'UPDATE notify_subscriptions SET remain = remain - 1, updated_at = CURRENT_TIMESTAMP '
          'WHERE app_id = ? AND template_id = ? AND user_id = "local"',
          [appId, templateId]);
      await tx.audit('notify', 'notify.send',
          '$appId $templateId remain ${remain - 1} state=$miniprogramState');
      return const SendOutcome(errcode: 0, errmsg: 'ok');
    });
  }

  // -------------------------------------------------------------------------
  // 宿主回执：订阅结果上报（契约 §3.4）
  // -------------------------------------------------------------------------

  /// accept → remain+1；reject → 只记 item_status，配额不动（契约 §3.4/§4.1）。
  /// 返回该 (app, template, local) 的最新 remain。
  Future<int> applyConsent(String appId, String templateId, String action) async {
    return db.transaction<int>((DbTx tx) async {
      if (action == 'accept') {
        await tx.exec(
            'INSERT INTO notify_subscriptions '
            '(app_id, template_id, user_id, remain, item_status) '
            'VALUES (?, ?, "local", 1, "accept") '
            'ON DUPLICATE KEY UPDATE remain = remain + 1, item_status = "accept", '
            'updated_at = CURRENT_TIMESTAMP',
            [appId, templateId]);
        await tx.audit('host', 'notify.consent', '$appId $templateId accept');
      } else {
        await tx.exec(
            'INSERT INTO notify_subscriptions '
            '(app_id, template_id, user_id, remain, item_status) '
            'VALUES (?, ?, "local", 0, "reject") '
            'ON DUPLICATE KEY UPDATE item_status = "reject", updated_at = CURRENT_TIMESTAMP',
            [appId, templateId]);
        await tx.audit('host', 'notify.consent', '$appId $templateId reject');
      }
      final List<Map<String, Object?>> rows = await tx.q(
          'SELECT remain FROM notify_subscriptions '
          'WHERE app_id = ? AND template_id = ? AND user_id = "local"',
          [appId, templateId]);
      return rows.isEmpty ? 0 : _int(rows.first['remain']) ?? 0;
    });
  }

  // -------------------------------------------------------------------------
  // 轮询 / 已读（契约 §3.3）
  // -------------------------------------------------------------------------

  /// id 单调递增；`since` 之后最多 50 条。保持旧实现的 id 倒序（客户端
  /// `notices.reversed` 逐条处理），新客户端可按需改成升序。
  Future<List<Map<String, Object?>>> poll(int since, {String? appId}) async {
    final List<Object?> args = <Object?>[since];
    String where = 'id > ?';
    if (appId != null) {
      where += ' AND app_id = ?';
      args.add(appId);
    }
    final List<Map<String, Object?>> rows = await db.q(
        'SELECT id, app_id, template_id, title, body, page, miniprogram_state, '
        'read_at, created_at FROM notify_messages WHERE $where '
        'ORDER BY id DESC LIMIT 50',
        args);
    return <Map<String, Object?>>[
      for (final Map<String, Object?> row in rows)
        <String, Object?>{
          'id': _int(row['id']),
          'appId': row['app_id'],
          'templateId': row['template_id'],
          'title': row['title'],
          'body': row['body'],
          'page': row['page'],
          'state': row['miniprogram_state'],
          'read': row['read_at'] != null,
          'ts': row['created_at'],
        },
    ];
  }

  /// 未读汇总（角标用）；给 appId 时按 app 统计。
  Future<int> unreadCount({String? appId}) async {
    final List<Map<String, Object?>> rows = appId == null
        ? await db.q('SELECT COUNT(*) AS n FROM notify_messages WHERE read_at IS NULL')
        : await db.q(
            'SELECT COUNT(*) AS n FROM notify_messages WHERE read_at IS NULL AND app_id = ?',
            [appId]);
    return rows.isEmpty ? 0 : _int(rows.first['n']) ?? 0;
  }

  /// 标记已读：`ids` 精确标记，或 `all + appId` 清未读（appId 省略 = 全清）。
  Future<int> markRead({List<int>? ids, bool all = false, String? appId}) async {
    if (all) {
      final List<Object?> args = <Object?>[];
      String where = 'read_at IS NULL';
      if (appId != null) {
        where += ' AND app_id = ?';
        args.add(appId);
      }
      await db.exec(
          'UPDATE notify_messages SET read_at = CURRENT_TIMESTAMP WHERE $where', args);
      return 1; // 调用方只需要「操作已执行」，具体条数无意义。
    }
    final List<int> effective = ids ?? const <int>[];
    if (effective.isEmpty) return 0;
    final String placeholders = List<String>.filled(effective.length, '?').join(', ');
    await db.exec(
        'UPDATE notify_messages SET read_at = CURRENT_TIMESTAMP '
        'WHERE read_at IS NULL AND id IN ($placeholders)',
        <Object?>[...effective]);
    return effective.length;
  }

  // -------------------------------------------------------------------------
  // 内部查询
  // -------------------------------------------------------------------------

  Future<bool> _prefsEnabled(DbTx tx, String appId) async {
    final List<Map<String, Object?>> rows = await tx.q(
        'SELECT enabled FROM notify_prefs WHERE scope IN ("global", ?)',
        ['app:$appId']);
    for (final Map<String, Object?> row in rows) {
      if ((_int(row['enabled']) ?? 1) == 0) return false;
    }
    return true;
  }

  Future<int> _lockedRemain(DbTx tx, String appId, String templateId) async {
    final List<Map<String, Object?>> rows = await tx.q(
        'SELECT remain FROM notify_subscriptions '
        'WHERE app_id = ? AND template_id = ? AND user_id = "local" FOR UPDATE',
        [appId, templateId]);
    return rows.isEmpty ? 0 : _int(rows.first['remain']) ?? 0;
  }

  /// 去重键是否已在 24h 窗口内落库。普通查询（不加锁）：并发下的漏网由
  /// uk_app_dedupe 唯一索引 + INSERT IGNORE 兜底，避免 FOR UPDATE 全表/范围
  /// 锁与落库插入互相等待造成死锁（E2E 并发实测 Error 1213）。
  Future<bool> _dedupeHit(DbTx tx, String appId, String dedupeKey) async {
    final List<Map<String, Object?>> rows = await tx.q(
        'SELECT id FROM notify_messages '
        'WHERE app_id = ? AND dedupe_key = ? '
        'AND created_at >= DATE_SUB(NOW(), INTERVAL 24 HOUR) '
        'ORDER BY id DESC LIMIT 1',
        [appId, dedupeKey]);
    return rows.isNotEmpty;
  }

  Future<bool> _rateLimited(DbTx tx, String appId) async {
    final List<Map<String, Object?>> rows = await tx.q(
        'SELECT '
        'COUNT(CASE WHEN created_at >= DATE_SUB(NOW(), INTERVAL 1 MINUTE) THEN 1 END) AS minute_n, '
        'COUNT(CASE WHEN created_at >= CURDATE() THEN 1 END) AS day_n '
        'FROM notify_messages WHERE app_id = ?',
        [appId]);
    if (rows.isEmpty) return false;
    final int minute = _int(rows.first['minute_n']) ?? 0;
    final int day = _int(rows.first['day_n']) ?? 0;
    return minute >= notifyRatePerMinute || day >= notifyRatePerDay;
  }
}
