/// 通知协议的**纯逻辑**：模板 id、模板字段/data 值格式校验（微信规则）、
/// miniprogram_state/page 参数校验、发送判定八步（契约 §4.2）。
///
/// 这里不碰数据库、HTTP、文件——notices.dart（HTTP 形状）与 notify_store.dart
/// （事务）共用同一套判定，tool/notify_selfcheck.dart 可以在没有 MariaDB 的
/// 机器上把判定与校验全跑一遍（契约 §5.4 要求可自检）。
library;

import 'dart:convert' show jsonDecode, utf8;

import 'package:crypto/crypto.dart' show sha256;

/// 微信 `subscribe/send` 模板 data 支持的键类型（值格式按微信文档口径）。
const Set<String> notifyFieldTypes = <String>{
  'thing',
  'number',
  'letter',
  'symbol',
  'character_string',
  'time',
  'date',
  'amount',
  'phone_number',
  'car_number',
  'name',
  'phrase',
};

/// `miniprogram_state` → AppHub 版本通道（契约 §2.3「↔ 换实现」）。
/// 键是微信取值，值是 AppHub 侧的版本通道语义；notify_messages 里存微信原值。
const Map<String, String> notifyVersionChannels = <String, String>{
  'formal': 'stable',
  'trial': 'trial',
  'developer': 'developer',
};

/// 限流口径（契约 §2.4 45009）：每 app 每分钟 20 条、每日 200 条。
/// 「每日」= 服务器本地自然日（CURDATE），不是滚动 24 小时。
const int notifyRatePerMinute = 20;
const int notifyRatePerDay = 200;

/// 去重窗口（契约 §7.5）：同 app + 同 dedupe_key 24 小时内只落一条。
const Duration notifyDedupeWindow = Duration(hours: 24);

/// 模板 id 形如 `tpl_<hash8>`（契约 §3.1）。含 appId 参与哈希，
/// 同 app 同名稳定（登记幂等），不同 app 不会拿到同一个 id。
String templateIdFor(String appId, String name) {
  final String digest = sha256.convert(utf8.encode('$appId\u0000$name')).toString();
  return 'tpl_${digest.substring(0, 8)}';
}

// ---------------------------------------------------------------------------
// 模板字段与 data 值校验
// ---------------------------------------------------------------------------

final RegExp _fieldKeyPattern = RegExp(r'^[a-z][a-z0-9_]{0,31}$');

/// 校验模板 `fields` 声明（契约 §3.2）。返回 null 表示合法，否则返回
/// 供 errmsg 使用的定位信息（如 `fields[1].type`）。
String? validateTemplateFields(Object? rawFields) {
  if (rawFields is! List) return 'fields';
  final Set<String> seen = <String>{};
  for (int i = 0; i < rawFields.length; i++) {
    final Object? item = rawFields[i];
    if (item is! Map) return 'fields[$i]';
    final Object? key = item['key'];
    final Object? type = item['type'];
    if (key is! String || !_fieldKeyPattern.hasMatch(key)) return 'fields[$i].key';
    if (type is! String || !notifyFieldTypes.contains(type)) return 'fields[$i].type';
    if (!seen.add(key)) return 'fields[$i].key';
  }
  return null;
}

/// 把 HTTP body 的 fields 归一化成 store 可用的形状。
/// 调用前必须先用 [validateTemplateFields] 校验。
List<Map<String, Object?>> normalizeTemplateFields(Object? rawFields) {
  if (rawFields is! List) return const <Map<String, Object?>>[];
  return <Map<String, Object?>>[
    for (final Object? item in rawFields)
      if (item is Map)
        <String, Object?>{'key': item['key'], 'type': item['type']},
  ];
}

/// 从 notify_templates.fields_json（TEXT）或已解析的 List 里取出字段声明。
List<Map<String, Object?>> decodeTemplateFields(Object? fieldsJson) {
  if (fieldsJson is List) {
    return <Map<String, Object?>>[
      for (final Object? item in fieldsJson)
        if (item is Map)
          <String, Object?>{'key': item['key'], 'type': item['type']},
    ];
  }
  if (fieldsJson is! String || fieldsJson.isEmpty) return const <Map<String, Object?>>[];
  try {
    return decodeTemplateFields(jsonDecode(fieldsJson));
  } catch (_) {
    return const <Map<String, Object?>>[];
  }
}

/// 字符串「显示宽度」：汉字算 2 个字符，其余算 1（微信 thing/name 口径）。
int weChatTextWidth(String value) {
  int width = 0;
  for (final int rune in value.runes) {
    width += _isCjkRune(rune) ? 2 : 1;
  }
  return width;
}

bool _isCjkRune(int rune) =>
    (rune >= 0x3400 && rune <= 0x4DBF) || // CJK 扩展 A
    (rune >= 0x4E00 && rune <= 0x9FFF) || // 基本汉字
    (rune >= 0xF900 && rune <= 0xFAFF); // 兼容汉字

bool _isOnlyCjk(String value) =>
    value.isNotEmpty && value.runes.every(_isCjkRune);

final RegExp _numberPattern = RegExp(r'^[0-9]{1,32}$');
final RegExp _letterPattern = RegExp(r'^[A-Za-z]{1,32}$');
final RegExp _characterStringPattern = RegExp(r'^[\x21-\x7E]{1,32}$');
final RegExp _timePattern = RegExp(r'^([01]?[0-9]|2[0-3]):[0-5][0-9]$');
final RegExp _datePatternChinese = RegExp(r'^(\d{4})年(\d{1,2})月(\d{1,2})日$');
final RegExp _datePatternNumeric = RegExp(r'^(\d{4})[-/](\d{1,2})[-/](\d{1,2})$');
final RegExp _amountPattern = RegExp(r'^[¥$€£]\d{1,10}(\.\d{1,2})?$');
final RegExp _phonePattern = RegExp(r'^[0-9]{1,17}$');
final RegExp _carNumberPattern = RegExp(r'^[A-Za-z0-9\u3400-\u9FFF]{1,8}$');
final RegExp _symbolForbidden = RegExp(r'[0-9A-Za-z\u3400-\u9FFF]');

/// 单个 data 值的格式校验（微信规则）。返回 null 合法，否则返回原因。
String? validateDataValue(String type, String value) {
  if (value.isEmpty) return 'must not be empty';
  switch (type) {
    case 'thing':
      // 20 个以内字符，汉字算 2 个字符。
      return weChatTextWidth(value) <= 20 ? null : 'at most 20 characters (a CJK char counts as 2)';
    case 'name':
      // 10 个以内字符，汉字算 2 个字符。
      return weChatTextWidth(value) <= 10 ? null : 'at most 10 characters (a CJK char counts as 2)';
    case 'phrase':
      return _isOnlyCjk(value) && value.runes.length <= 5
          ? null
          : 'at most 5 Chinese characters';
    case 'number':
      return _numberPattern.hasMatch(value) ? null : 'at most 32 digits';
    case 'letter':
      return _letterPattern.hasMatch(value) ? null : 'at most 32 letters';
    case 'symbol':
      return value.isNotEmpty &&
              value.runes.length <= 5 &&
              !_symbolForbidden.hasMatch(value)
          ? null
          : 'at most 5 symbols';
    case 'character_string':
      return _characterStringPattern.hasMatch(value) ? null : 'at most 32 printable ASCII characters';
    case 'time':
      // 24 小时制时间，如 15:01。
      return _timePattern.hasMatch(value) ? null : 'must be HH:MM in 24-hour form';
    case 'date':
      return _validDate(value) ? null : 'must be a year-month-day date';
    case 'amount':
      // 1 个币种符号 + 金额，如 ¥10.00。
      return _amountPattern.hasMatch(value) ? null : 'must be a currency symbol followed by an amount';
    case 'phone_number':
      return _phonePattern.hasMatch(value) ? null : 'at most 17 digits';
    case 'car_number':
      return _carNumberPattern.hasMatch(value) ? null : 'at most 8 letters/digits/CJK characters';
    default:
      return 'unsupported field type';
  }
}

bool _validDate(String value) {
  final RegExpMatch? match =
      _datePatternChinese.firstMatch(value) ?? _datePatternNumeric.firstMatch(value);
  if (match == null) return false;
  final int month = int.parse(match.group(2)!);
  final int day = int.parse(match.group(3)!);
  return month >= 1 && month <= 12 && day >= 1 && day <= 31;
}

/// 按模板字段顺序校验整个 `data`（契约 §4.2 第 3 步）。
/// 返回第一个不合格的字段名；全部合法返回 null。
/// 形状照微信：`{"thing01": {"value": "..."}}`。
String? validateDataValues(Object? data, List<Map<String, Object?>> fields) {
  if (data is! Map) return 'data';
  for (final Map<String, Object?> field in fields) {
    final String key = field['key'] as String? ?? '';
    final String type = field['type'] as String? ?? '';
    if (!data.containsKey(key)) return key;
    final Object? raw = data[key];
    if (raw is! Map) return key;
    final Object? value = raw['value'];
    if (value is! String) return key;
    if (validateDataValue(type, value) != null) return key;
  }
  return null;
}

/// 校验 `miniprogram_state`：缺省合法（按 formal 处理，与微信「默认为正式版」
/// 一致，契约 §2.2）；给了就必须是 formal / trial / developer。
bool isValidMiniprogramState(Object? value) =>
    value == null || (value is String && notifyVersionChannels.containsKey(value));

/// 校验 `page`：可为空；给了就必须是字符串、≤512 字符、不可是带协议的外链
/// （点击只在本小程序内跳转，契约 §2.2）。
bool isValidPage(Object? value) {
  if (value == null) return true;
  if (value is! String) return false;
  if (value.length > 512) return false;
  if (value.contains('://')) return false;
  return true;
}

/// 通知标题 = 模板名（人读名）。截到 128 字符以内。
String messageTitle(String templateName) => _truncate(templateName, 128);

/// 通知正文 = 按模板字段顺序拼各字段值（`a · b`）。截到 512 字符以内。
String messageBody(List<Map<String, Object?>> fields, Object? data) {
  if (data is! Map) return '';
  final List<String> parts = <String>[];
  for (final Map<String, Object?> field in fields) {
    final Object? raw = data[field['key']];
    if (raw is Map && raw['value'] is String) {
      final String value = raw['value'] as String;
      if (value.isNotEmpty) parts.add(value);
    }
  }
  return _truncate(parts.join(' · '), 512);
}

String _truncate(String value, int maxUnits) {
  if (value.runes.length <= maxUnits) return value;
  return String.fromCharCodes(value.runes.take(maxUnits));
}

/// 连接来源是否 loopback（契约 §3.4 宿主内部端点只认本机/同隧道）。
/// 兼容 IPv4 127.0.0.0/8、IPv6 ::1 与 IPv4-mapped `::ffff:127.x`。
bool isLoopbackAddress(String address) {
  final String value = address.trim().toLowerCase();
  if (value == '::1' || value == 'localhost') return true;
  final String ipv4 = value.startsWith('::ffff:') ? value.substring(7) : value;
  return RegExp(r'^127\.\d{1,3}\.\d{1,3}\.\d{1,3}$').hasMatch(ipv4);
}

// ---------------------------------------------------------------------------
// 发送判定（契约 §4.2 八步）
// ---------------------------------------------------------------------------

/// 判定结果。[dedupe] 为 true 表示 dedupe_key 幂等命中：返回 0 但没有落新行、
/// 不扣配额（重试不该重复扣费）。
class SendDecision {
  const SendDecision(this.errcode, this.errmsg, {this.dedupe = false});

  const SendDecision.ok({bool dedupe = false})
      : errcode = 0,
        errmsg = 'ok',
        dedupe = dedupe;

  final int errcode;
  final String errmsg;
  final bool dedupe;

  bool get ok => errcode == 0;

  /// 真正需要落库/扣配额？幂等命中时为 false。
  bool get sends => errcode == 0 && !dedupe;
}

/// 发送判定八步的纯函数版本（§4.2 顺序）：
///   1 token → 2 模板 → 3 data → 4 参数(miniprogram_state/page) →
///   5 偏好开关 → 6 配额 → 7 限流 → 8 落库（落库由 store 在本函数 ok 后做）。
///
/// 说明：第 8 步的 dedupe 幂等分支放在第 6/7 步之前评估——契约 §7.5 的意图是
/// 「重试拿到同样的 0」；若先判配额，首次发送已把 remain 用光后，重试会被误判
/// 43101，幂等就失效了。除此之外前七步严格按契约顺序返回第一个错误。
SendDecision decideSend({
  required bool tokenValid,
  required Map<String, Object?>? template,
  required Object? data,
  required bool prefsEnabled,
  required int remain,
  required bool rateLimited,
  String? argumentError,
  bool dedupeHit = false,
}) {
  // 1. token 校验
  if (!tokenValid) return const SendDecision(40001, 'invalid credential');
  // 2. 模板存在且属于该 app
  if (template == null) return const SendDecision(40002, 'template not registered');
  // 3. data 按键类型校验
  final List<Map<String, Object?>> fields = decodeTemplateFields(template['fields_json']);
  final String? badField = validateDataValues(data, fields);
  if (badField != null) return SendDecision(40003, 'data invalid: $badField');
  // 4. miniprogram_state / page 参数合法性
  if (argumentError != null) return SendDecision(47003, 'argument invalid: $argumentError');
  // 5. 用户级 / 应用级总开关
  if (!prefsEnabled) return const SendDecision(43101, 'user refuse to accept the msg');
  // 8(幂等分支). 同 app + dedupe_key 24h 内已发过 → 返回 0，不落库不扣配额
  if (dedupeHit) return const SendDecision.ok(dedupe: true);
  // 6. 一次性配额
  if (remain <= 0) return const SendDecision(43101, 'user refuse to accept the msg');
  // 7. 限流
  if (rateLimited) return const SendDecision(45009, 'rate limited');
  return const SendDecision.ok();
}
