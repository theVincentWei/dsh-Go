/// AppHub 平台侧通知（契约唯一依据：docs 里的 dimina-notify-contract v1）：
///
///   POST /api/v1/apps/<appId>/notify            后端发送（微信兼容请求体，§2.2）
///   POST /api/v1/apps/<appId>/notify/templates  模板登记（§3.2）
///   GET  /api/v1/apps/<appId>/notify/templates  模板列表（§3.2）
///   GET  /api/v1/notices?since=&appId=          宿主轮询（含 unread，§3.3）
///   POST /api/v1/notices/read                   标已读（ids / all+appId，§3.3）
///   POST /api/v1/notices/consent                宿主订阅回执（仅 loopback，§3.4）
///   POST /api/v1/apps/<appId>/notify/token      发放 app token（发布者密钥，§5.4）
///
/// 边界：本文件只做 HTTP 形状与参数边界；纯校验/判定在 notify_logic.dart，
/// SQL 与「判定+落库同一事务」在 notify_store.dart。
library;

import 'dart:convert';
import 'dart:io' show HttpConnectionInfo;

import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf_router/shelf_router.dart' as shelf_router;

import 'config.dart';
import 'db.dart';
import 'notify_logic.dart';
import 'notify_store.dart';
import 'store.dart' show isValidAppId;

const Map<String, String> _jsonHeaders = <String, String>{
  'content-type': 'application/json; charset=utf-8',
};

shelf.Response _json(int status, Object? body) =>
    shelf.Response(status, body: jsonEncode(body), headers: _jsonHeaders);

/// 成功响应：契约 §2.2 的 `{"errcode": 0, "errmsg": "ok"}`（可带附加字段）。
shelf.Response _ok([Map<String, Object?> extra = const <String, Object?>{}]) =>
    _json(200, <String, Object?>{'errcode': 0, 'errmsg': 'ok', ...extra});

/// 错误响应：errcode/errmsg 严格按契约 §2.4。
shelf.Response _errcode(int errcode, String errmsg) =>
    _json(_httpStatusFor(errcode), <String, Object?>{'errcode': errcode, 'errmsg': errmsg});

/// errcode → HTTP 状态（响应体始终带 errcode，客户端按微信习惯读 errcode 即可）。
///
/// 注意：不能给 40002 用 404——bin/apphub.dart 的 Cascade 把 404 当「本路由不
/// 认识」，会继续落到网关 catch-all 变成 `not found` 文本，客户端就拿不到
/// errcode 了（E2E 实测）。业务错误统一 400/401/403/429。
int _httpStatusFor(int errcode) {
  switch (errcode) {
    case 0:
      return 200;
    case 40001:
      return 401;
    case 43101:
      return 403;
    case 45009:
      return 429;
    default: // 40002 / 40003 / 47003
      return 400;
  }
}

class Notices {
  Notices(this.cfg, Db db) : store = NotifyStore(db);

  final AppConfig cfg;
  final NotifyStore store;

  shelf_router.Router get router {
    return shelf_router.Router()
      ..post('/api/v1/apps/<appId>/notify', (shelf.Request request, String appId) =>
          _guard(() => _send(request, appId)))
      ..post('/api/v1/apps/<appId>/notify/templates',
          (shelf.Request request, String appId) =>
              _guard(() => _registerTemplate(request, appId)))
      ..get('/api/v1/apps/<appId>/notify/templates',
          (shelf.Request request, String appId) =>
              _guard(() => _listTemplates(request, appId)))
      ..post('/api/v1/apps/<appId>/notify/token',
          (shelf.Request request, String appId) =>
              _guard(() => _issueToken(request, appId)))
      ..get('/api/v1/notices', (shelf.Request request) => _guard(() => _poll(request)))
      ..post('/api/v1/notices/read', (shelf.Request request) => _guard(() => _read(request)))
      ..post('/api/v1/notices/consent',
          (shelf.Request request) => _guard(() => _consent(request)));
  }

  // -------------------------------------------------------------------------
  // 后端发送（契约 §2.2 + §4.2）
  // -------------------------------------------------------------------------

  Future<shelf.Response> _send(shelf.Request request, String appId) async {
    if (!isValidAppId(appId)) return _errcode(47003, 'argument invalid: appId');
    // 第 1 步：token 校验（app_tokens 的 per-app token，Bearer）。
    if (!await _authorized(request, appId)) return _errcode(40001, 'invalid credential');
    final Map<String, Object?>? body = await _readBody(request);
    if (body == null) return _errcode(47003, 'argument invalid: body');

    // 第 2 步：模板存在且属于该 app（template_id 缺失算参数错误）。
    final Object? rawTemplateId = body['template_id'];
    if (rawTemplateId is! String || rawTemplateId.isEmpty) {
      return _errcode(47003, 'argument invalid: template_id');
    }
    final Map<String, Object?>? template = await store.findTemplate(appId, rawTemplateId);
    if (template == null) return _errcode(40002, 'template not registered');

    // 🔇 微信兼容字段（契约 §2.3 铁律）：`touser`(openid) 与 `lang` **收下但
    // 不生效**——dsh-go 是单机单用户、界面语言跟系统，它们没有可落地的语义。
    // 不校验、不报错，只在调试日志里显式标注「已忽略」，禁止假装支持。
    if (body.containsKey('touser') || body.containsKey('lang')) {
      print('[notify] compat fields ignored: '
          'touser=${body['touser'] != null} lang=${body['lang'] != null} app=$appId');
    }

    // 第 4 步（参数校验）与第 3 步（data）的顺序由 decideSend 保证：data 错
    // 必须先于参数错返回，所以这里只收集错误、不短路。
    final Object? state = body['miniprogram_state'];
    final String? stateError = isValidMiniprogramState(state) ? null : 'miniprogram_state';
    final String? pageError = isValidPage(body['page']) ? null : 'page';
    final String? argumentError = stateError ?? pageError;
    // 缺省走正式版通道（契约 §2.2：miniprogram_state 非必填，缺省 formal）。
    final String miniprogramState = state is String ? state : 'formal';

    // dedupe_key 是契约 §7.5 的后端自由填扩展（同 app + 同 key 24h 幂等）。
    final Object? rawDedupeKey = body['dedupe_key'];
    if (rawDedupeKey != null &&
        (rawDedupeKey is! String || rawDedupeKey.isEmpty || rawDedupeKey.length > 128)) {
      return _errcode(47003, 'argument invalid: dedupe_key');
    }

    final SendOutcome outcome = await store.send(
      appId: appId,
      templateId: rawTemplateId,
      template: template,
      data: body['data'],
      miniprogramState: miniprogramState,
      argumentError: argumentError,
      page: body['page'] is String ? body['page'] as String : null,
      dedupeKey: rawDedupeKey as String?,
    );
    return _errcode(outcome.errcode, outcome.errmsg);
  }

  // -------------------------------------------------------------------------
  // 模板登记（契约 §3.2）
  // -------------------------------------------------------------------------

  Future<shelf.Response> _registerTemplate(shelf.Request request, String appId) async {
    if (!isValidAppId(appId)) return _errcode(47003, 'argument invalid: appId');
    if (!await _authorized(request, appId)) return _errcode(40001, 'invalid credential');
    final Map<String, Object?>? body = await _readBody(request);
    if (body == null) return _errcode(47003, 'argument invalid: body');

    final Object? rawName = body['name'];
    final String name = rawName is String ? rawName.trim() : '';
    if (name.isEmpty || name.length > 64) return _errcode(47003, 'argument invalid: name');

    final Object? rawFields = body['fields'] ?? const <Object?>[];
    final String? fieldsError = validateTemplateFields(rawFields);
    if (fieldsError != null) return _errcode(47003, 'argument invalid: $fieldsError');

    final String templateId =
        await store.registerTemplate(appId, name, normalizeTemplateFields(rawFields));
    return _ok(<String, Object?>{'template_id': templateId});
  }

  Future<shelf.Response> _listTemplates(shelf.Request request, String appId) async {
    if (!isValidAppId(appId)) return _errcode(47003, 'argument invalid: appId');
    // 鉴权：GET 是「宿主内部只读元数据」，不是小程序 API——订阅面板由 dsh-go
    // 宿主弹出，宿主需要模板 name 渲染面板，而宿主不持有小程序后端的 app
    // token（那是后端凭证，不该下放给宿主）。因此放行两种调用方：
    //   (a) 合法的 app token（后端自查/联调用）；
    //   (b) loopback 来源（与 consent 端点同一套 loopback 判定，不新增密钥）。
    // 写入（POST）仍然只认 app token，见 [_registerTemplate]（契约 §3.2）。
    if (!await _authorized(request, appId) && !_isLoopback(request)) {
      return _errcode(40001, 'invalid credential');
    }
    return _ok(<String, Object?>{'templates': await store.listTemplates(appId)});
  }

  // -------------------------------------------------------------------------
  // 宿主轮询 / 已读（契约 §3.3）
  // -------------------------------------------------------------------------

  /// 设备侧轮询与旧实现一样不做 token 鉴权（§9.2 要求补鉴权的是发送端点，
  /// 见 [_send]）；AppHub 只在局域网/隧道内可达，这是既有 M1 的信任模型。
  Future<shelf.Response> _poll(shelf.Request request) async {
    final int since = int.tryParse(request.url.queryParameters['since'] ?? '') ?? 0;
    final String? appId = request.url.queryParameters['appId'];
    if (appId != null && !isValidAppId(appId)) {
      return _errcode(47003, 'argument invalid: appId');
    }
    final List<Map<String, Object?>> notices = await store.poll(since, appId: appId);
    final int unread = await store.unreadCount(appId: appId);
    return _ok(<String, Object?>{'notices': notices, 'unread': unread});
  }

  /// POST /api/v1/notices/read — `{"ids":[...]}` 或 `{"all":true,"appId":"..."}`。
  Future<shelf.Response> _read(shelf.Request request) async {
    final Map<String, Object?>? body = await _readBody(request);
    if (body == null) return _errcode(47003, 'argument invalid: body');

    final Object? rawIds = body['ids'];
    if (rawIds is List) {
      final List<int> ids = <int>[
        for (final Object? raw in rawIds)
          if (raw is num) raw.toInt(),
      ];
      if (ids.isEmpty) return _errcode(47003, 'argument invalid: ids');
      final int updated = await store.markRead(ids: ids);
      return _ok(<String, Object?>{'updated': updated});
    }

    final String? appId = body['appId'] is String ? body['appId'] as String : null;
    if (appId != null && !isValidAppId(appId)) {
      return _errcode(47003, 'argument invalid: appId');
    }
    if (body['all'] == true) {
      final int unread = await store.unreadCount(appId: appId);
      await store.markRead(all: true, appId: appId);
      return _ok(<String, Object?>{'updated': unread});
    }
    return _errcode(47003, 'argument invalid: ids');
  }

  // -------------------------------------------------------------------------
  // 宿主订阅回执（契约 §3.4）— 仅 loopback
  // -------------------------------------------------------------------------

  Future<shelf.Response> _consent(shelf.Request request) async {
    // 鉴权不引入新密钥：只认连接来源是 loopback（设备上的宿主与 AppHub 同机/
    // 同隧道）。这是「宿主内部 API」与「小程序 API」的鉴权分界。
    if (!_isLoopback(request)) {
      return _errcode(47003, 'argument invalid: source (loopback only)');
    }
    final Map<String, Object?>? body = await _readBody(request);
    if (body == null) return _errcode(47003, 'argument invalid: body');

    final String appId = body['appId'] is String ? body['appId'] as String : '';
    if (!isValidAppId(appId)) return _errcode(47003, 'argument invalid: appId');
    final String templateId =
        body['templateId'] is String ? body['templateId'] as String : '';
    if (templateId.isEmpty) return _errcode(47003, 'argument invalid: templateId');
    if (await store.findTemplate(appId, templateId) == null) {
      return _errcode(40002, 'template not registered');
    }
    final String action = body['action'] is String ? body['action'] as String : '';
    if (action != 'accept' && action != 'reject') {
      return _errcode(47003, 'argument invalid: action');
    }
    final int remain = await store.applyConsent(appId, templateId, action);
    return _ok(<String, Object?>{'remain': remain});
  }

  // -------------------------------------------------------------------------
  // app token 发放（发布者密钥）
  // -------------------------------------------------------------------------

  /// `app_tokens` 原来只有建表、没有发放流程；P2 的发送鉴权需要 per-app
  /// token，这里补一个发布者密钥保护的管理入口（apphubctl token 调用）。
  Future<shelf.Response> _issueToken(shelf.Request request, String appId) async {
    if (!_publisher(request)) return _errcode(40001, 'invalid credential');
    if (!isValidAppId(appId)) return _errcode(47003, 'argument invalid: appId');
    final String token = await store.issueToken(appId);
    return _ok(<String, Object?>{'appId': appId, 'token': token});
  }

  // -------------------------------------------------------------------------
  // 基础设施
  // -------------------------------------------------------------------------

  /// 发布者密钥（与 gateway/market 同一套，不新增密钥体系）。
  bool _publisher(shelf.Request request) {
    final String key = cfg.publisherKey;
    return key.isNotEmpty && (request.headers['authorization'] ?? '') == 'Bearer $key';
  }

  String? _bearer(shelf.Request request) {
    final String raw = request.headers['authorization'] ?? '';
    if (!raw.startsWith('Bearer ')) return null;
    final String token = raw.substring('Bearer '.length).trim();
    return token.isEmpty ? null : token;
  }

  Future<bool> _authorized(shelf.Request request, String appId) async {
    final String? token = _bearer(request);
    if (token == null) return false;
    return store.tokenBelongsTo(token, appId);
  }

  bool _isLoopback(shelf.Request request) {
    final Object? info = request.context['shelf.io.connection_info'];
    if (info is! HttpConnectionInfo) return false;
    return isLoopbackAddress(info.remoteAddress.address);
  }

  Future<Map<String, Object?>?> _readBody(shelf.Request request) async {
    final Object? decoded;
    try {
      decoded = jsonDecode(await request.readAsString());
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    return decoded.cast<String, Object?>();
  }

  Future<shelf.Response> _guard(Future<shelf.Response> Function() run) async {
    try {
      return await run();
    } catch (error) {
      print('[notices] internal error: $error');
      return _json(500, <String, Object?>{'errcode': -1, 'errmsg': 'internal error'});
    }
  }
}
