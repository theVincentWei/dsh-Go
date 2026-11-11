/// 通知协议纯逻辑自检（契约 dimina-notify-contract §5.4）。
///
/// 不依赖 MariaDB、不依赖 package:test：只 import 纯逻辑 notify_logic.dart，
/// 把「模板登记幂等、data 各类型校验、发送判定八步顺序、配额耗尽 43101、
/// 去重幂等」在内存里跑一遍。
///
/// 运行：cd apphub && dart run tool/notify_selfcheck.dart
/// 退出码 0 = 全过，1 = 有失败。
library;

import 'dart:io' show exitCode;

import 'package:apphub/notify_logic.dart';

int _passed = 0;
final List<String> _failures = <String>[];

void check(String label, Object? actual, Object? expected) {
  if ('$actual' == '$expected') {
    _passed++;
  } else {
    _failures.add('$label: expected <$expected>, got <$actual>');
  }
}

void checkTrue(String label, bool condition) => check(label, condition, true);

void section(String title) => print('\n[$title]');

// 供 data 校验用例复用：合法的微信形状。
Object goodData() => <String, Object?>{
      'thing01': <String, Object?>{'value': '订单已发货'},
      'time2': <String, Object?>{'value': '15:01'},
    };

Map<String, Object?> templateWithFields(List<Map<String, Object?>> fields) =>
    <String, Object?>{
      'template_id': 'tpl_1a2b3c4d',
      'app_id': 'wx5b8e2f4a9c1d7e60',
      'name': '订单状态',
      'fields_json': '[{"key":"thing01","type":"thing"},{"key":"time2","type":"time"}]',
    };

Future<void> main() async {
  _templateRegistration();
  _templateFields();
  _dataValidation();
  _eightStepOrder();
  _quotaExhausted();
  _dedupeIdempotency();
  _argumentsAndHelpers();

  print('\n${_passed + _failures.length} checks, $_passed passed, ${_failures.length} failed');
  if (_failures.isNotEmpty) {
    print('\nFAILURES:');
    for (final String failure in _failures) {
      print('  - $failure');
    }
    exitCode = 1;
    return;
  }
  print('OK — notify pure logic self-check passed');
}

// ---------------------------------------------------------------------------
// 1. 模板登记幂等（契约 §3.2）
// ---------------------------------------------------------------------------
void _templateRegistration() {
  section('模板登记幂等');

  final String first = templateIdFor('wx5b8e2f4a9c1d7e60', '订单状态');
  final String again = templateIdFor('wx5b8e2f4a9c1d7e60', '订单状态');
  check('同 app 同名 id 稳定', again, first);
  checkTrue('id 形如 tpl_<hash8>', RegExp(r'^tpl_[0-9a-f]{8}$').hasMatch(first));
  check('不同 app 不同 id', templateIdFor('wxb6f8f4a9c1d7e611', '订单状态') == first, false);
  check('不同 name 不同 id', templateIdFor('wx5b8e2f4a9c1d7e60', '支付结果') == first, false);

  // 模拟登记表：同 name 重复登记返回已存在 id（幂等），字段变更复用 id。
  final Map<String, String> registry = <String, String>{};
  String register(String name) =>
      registry.putIfAbsent(name, () => templateIdFor('wx5b8e2f4a9c1d7e60', name));
  final String registered = register('订单状态');
  final String registeredAgain = register('订单状态');
  check('重复登记返回同一 id', registeredAgain, registered);
  check('登记表只有一条', registry.length, 1);
  check('字段变更复用 id', templateIdFor('wx5b8e2f4a9c1d7e60', '订单状态'), registered);
}

// ---------------------------------------------------------------------------
// 2. 模板 fields 声明校验
// ---------------------------------------------------------------------------
void _templateFields() {
  section('模板 fields 校验');

  check(
      '合法声明',
      validateTemplateFields(<Object?>[
        <String, Object?>{'key': 'thing01', 'type': 'thing'},
        <String, Object?>{'key': 'time2', 'type': 'time'},
      ]),
      null);
  check('空数组合法', validateTemplateFields(<Object?>[]), null);
  check('非数组', validateTemplateFields('x'), 'fields');
  check('条目不是对象', validateTemplateFields(<Object?>['thing01']), 'fields[0]');
  check('key 非法（大写/空格）',
      validateTemplateFields(<Object?>[<String, Object?>{'key': 'Thing 1', 'type': 'thing'}]),
      'fields[0].key');
  check('type 非微信类型',
      validateTemplateFields(<Object?>[<String, Object?>{'key': 'thing01', 'type': 'rich'}]),
      'fields[0].type');
  check(
      'key 重复',
      validateTemplateFields(<Object?>[
        <String, Object?>{'key': 'thing01', 'type': 'thing'},
        <String, Object?>{'key': 'thing01', 'type': 'thing'},
      ]),
      'fields[1].key');
}

// ---------------------------------------------------------------------------
// 3. data 各类型校验（微信规则）
// ---------------------------------------------------------------------------
void _dataValidation() {
  section('data 值格式校验');

  String? v(String type, String value) => validateDataValue(type, value);

  check('thing 20 个 ASCII 合法', v('thing', 'a' * 20), null);
  check('thing 21 个 ASCII 超限', v('thing', 'a' * 21) == null, false);
  check('thing 10 个汉字（宽 20）合法', v('thing', '字' * 10), null);
  check('thing 11 个汉字（宽 22）超限', v('thing', '字' * 11) == null, false);
  check('thing 空串非法', v('thing', ''), 'must not be empty');

  check('number 32 位合法', v('number', '12345678901234567890123456789012'), null);
  check('number 33 位超限', v('number', '1' * 33) == null, false);
  check('number 含字母非法', v('number', '12a') == null, false);

  check('letter 32 位合法', v('letter', 'a' * 32), null);
  check('letter 含数字非法', v('letter', 'abc1') == null, false);

  check('symbol 5 个以内合法', v('symbol', '...'), null);
  check('symbol 6 个超限', v('symbol', '......') == null, false);
  check('symbol 含字母非法', v('symbol', 'a') == null, false);

  check('character_string 合法', v('character_string', 'ABC-123_45'), null);
  check('character_string 33 位超限', v('character_string', 'a' * 33) == null, false);

  check('time 00:00 合法', v('time', '00:00'), null);
  check('time 23:59 合法', v('time', '23:59'), null);
  check('time 9:05 合法（省略前导 0）', v('time', '9:05'), null);
  check('time 24:00 非法', v('time', '24:00') == null, false);
  check('time 15:60 非法', v('time', '15:60') == null, false);

  check('date 年月日合法', v('date', '2026年11月10日'), null);
  check('date 连字符合法', v('date', '2026-11-10'), null);
  check('date 斜杠合法', v('date', '2026/11/10'), null);
  check('date 月份越界非法', v('date', '2026-13-01') == null, false);
  check('date 缺日非法', v('date', '2026-11') == null, false);

  check('amount 币种+金额合法', v('amount', '¥10.00'), null);
  check('amount 缺币种非法', v('amount', '10.00') == null, false);
  check('amount 小数三位非法', v('amount', '¥10.001') == null, false);

  check('phone_number 17 位合法', v('phone_number', '1' * 17), null);
  check('phone_number 18 位超限', v('phone_number', '1' * 18) == null, false);

  check('car_number 合法', v('car_number', '粤B12345'), null);
  check('car_number 超 8 位非法', v('car_number', '粤B123456789') == null, false);

  check('name 5 个汉字（宽 10）合法', v('name', '字' * 5), null);
  check('name 6 个汉字（宽 12）超限', v('name', '字' * 6) == null, false);

  check('phrase 4 个汉字合法', v('phrase', '你好世界'), null);
  check('phrase 5 个汉字合法', v('phrase', '你好世界啊'), null);
  check('phrase 6 个汉字超限', v('phrase', '你好世界啊呀') == null, false);
  check('phrase 非汉字非法', v('phrase', 'ab') == null, false);

  check('未知类型非法', v('rich', 'x') == null, false);

  // 整个 data 对象校验（契约 §4.2 第 3 步）
  final List<Map<String, Object?>> fields = <Map<String, Object?>>[
    <String, Object?>{'key': 'thing01', 'type': 'thing'},
    <String, Object?>{'key': 'time2', 'type': 'time'},
  ];
  check('data 全合法', validateDataValues(goodData(), fields), null);
  check('data 键缺失',
      validateDataValues(<String, Object?>{'thing01': <String, Object?>{'value': '已发货'}}, fields),
      'time2');
  check(
      'data 值形状不是 {value}',
      validateDataValues(<String, Object?>{
        'thing01': '已发货',
        'time2': <String, Object?>{'value': '15:01'},
      }, fields),
      'thing01');
  check(
      'data value 非字符串',
      validateDataValues(<String, Object?>{
        'thing01': <String, Object?>{'value': 1},
        'time2': <String, Object?>{'value': '15:01'},
      }, fields),
      'thing01');
  check('data 不是对象', validateDataValues('x', fields), 'data');
}

// ---------------------------------------------------------------------------
// 4. 发送判定八步顺序（契约 §4.2）
// ---------------------------------------------------------------------------
void _eightStepOrder() {
  section('发送判定八步顺序');

  final Map<String, Object?> template = templateWithFields(const <Map<String, Object?>>[]);
  final Object? badData = <String, Object?>{
    'thing01': <String, Object?>{'value': ''}, // thing 空串 → data invalid
    'time2': <String, Object?>{'value': '15:01'},
  };

  SendDecision decide({
    bool tokenValid = true,
    Map<String, Object?>? tmpl,
    Object? data,
    String? argumentError,
    bool prefsEnabled = true,
    int remain = 1,
    bool rateLimited = false,
    bool dedupeHit = false,
  }) =>
      decideSend(
        tokenValid: tokenValid,
        template: tmpl,
        data: data ?? goodData(),
        argumentError: argumentError,
        prefsEnabled: prefsEnabled,
        remain: remain,
        rateLimited: rateLimited,
        dedupeHit: dedupeHit,
      );

  // 1. token 最先
  final SendDecision tokenFirst = decide(
      tokenValid: false, tmpl: null, data: badData, prefsEnabled: false, remain: 0, rateLimited: true);
  check('第 1 步 token 无效 → 40001', tokenFirst.errcode, 40001);
  check('第 1 步 errmsg', tokenFirst.errmsg, 'invalid credential');

  // 2. 模板先于 data
  final SendDecision templateFirst =
      decide(tmpl: null, data: badData, argumentError: 'miniprogram_state', prefsEnabled: false);
  check('第 2 步 模板未登记 → 40002', templateFirst.errcode, 40002);
  check('第 2 步 errmsg', templateFirst.errmsg, 'template not registered');

  // 3. data 先于参数/开关/配额/限流
  final SendDecision dataFirst = decide(
      tmpl: template, data: badData, argumentError: 'miniprogram_state', prefsEnabled: false, remain: 0, rateLimited: true);
  check('第 3 步 data 非法 → 40003', dataFirst.errcode, 40003);
  check('第 3 步 errmsg 带字段名', dataFirst.errmsg, 'data invalid: thing01');

  // 4. 参数错误先于开关/配额/限流
  final SendDecision argFirst = decide(
      tmpl: template, argumentError: 'miniprogram_state', prefsEnabled: false, remain: 0, rateLimited: true);
  check('第 4 步 参数非法 → 47003', argFirst.errcode, 47003);
  check('第 4 步 errmsg', argFirst.errmsg, 'argument invalid: miniprogram_state');

  // 5. 开关关闭先于配额/限流
  final SendDecision prefsFirst =
      decide(tmpl: template, prefsEnabled: false, remain: 0, rateLimited: true);
  check('第 5 步 总开关关闭 → 43101', prefsFirst.errcode, 43101);
  check('第 5 步 errmsg', prefsFirst.errmsg, 'user refuse to accept the msg');

  // 6. 配额先于限流
  final SendDecision quotaFirst =
      decide(tmpl: template, remain: 0, rateLimited: true);
  check('第 6 步 配额耗尽 → 43101（先于 45009）', quotaFirst.errcode, 43101);

  // 7. 限流
  final SendDecision rateFirst = decide(tmpl: template, remain: 1, rateLimited: true);
  check('第 7 步 限流 → 45009', rateFirst.errcode, 45009);
  check('第 7 步 errmsg', rateFirst.errmsg, 'rate limited');

  // 8. 全通过
  final SendDecision allowed = decide(tmpl: template, remain: 1);
  check('第 8 步 全通过 → 0', allowed.errcode, 0);
  checkTrue('全通过需要落库', allowed.sends);
  check('ok errmsg', allowed.errmsg, 'ok');
}

// ---------------------------------------------------------------------------
// 5. 配额耗尽 43101（契约 §4.1/§4.2）
// ---------------------------------------------------------------------------
void _quotaExhausted() {
  section('配额耗尽 43101');

  final Map<String, Object?> template = templateWithFields(const <Map<String, Object?>>[]);
  for (final int remain in <int>[0, -1]) {
    final SendDecision decision = decideSend(
      tokenValid: true,
      template: template,
      data: goodData(),
      prefsEnabled: true,
      remain: remain,
      rateLimited: false,
    );
    check('remain=$remain → 43101', decision.errcode, 43101);
    check('remain=$remain 不落库', decision.sends, false);
  }
}

// ---------------------------------------------------------------------------
// 6. 去重幂等（契约 §7.5：同 app + 同 dedupe_key 24h 只落一条）
// ---------------------------------------------------------------------------
void _dedupeIdempotency() {
  section('去重幂等');

  final Map<String, Object?> template = templateWithFields(const <Map<String, Object?>>[]);
  int remain = 2;
  int rows = 0;
  final Set<String> seenKeys = <String>{};

  SendDecision send(String? key) {
    final bool hit = key != null && seenKeys.contains(key);
    final SendDecision decision = decideSend(
      tokenValid: true,
      template: template,
      data: goodData(),
      prefsEnabled: true,
      remain: remain,
      rateLimited: false,
      dedupeHit: hit,
    );
    if (decision.sends) {
      rows++;
      remain--;
      if (key != null) seenKeys.add(key);
    }
    return decision;
  }

  final SendDecision first = send('order:42');
  check('首次发送成功', first.errcode, 0);
  check('首次发送落一条', rows, 1);
  check('首次发送扣一次配额', remain, 1);

  final SendDecision retry = send('order:42');
  check('同 key 重试返回 0（幂等）', retry.errcode, 0);
  checkTrue('重试标记 dedupe', retry.dedupe);
  check('重试不新增行', rows, 1);
  check('重试不扣配额', remain, 1);

  // 配额用光后，同 key 重试仍必须幂等返回 0（不能被误判 43101）。
  final SendDecision second = send('order:43');
  check('第二条发送成功', second.errcode, 0);
  check('配额已用光', remain, 0);
  final SendDecision retryAfterQuota = send('order:43');
  check('配额用光后同 key 重试仍幂等返回 0', retryAfterQuota.errcode, 0);
  check('配额用光后重试不新增行', rows, 2);

  final SendDecision exhausted = send('order:44');
  check('新 key 配额耗尽 → 43101', exhausted.errcode, 43101);
}

// ---------------------------------------------------------------------------
// 7. 参数与辅助函数
// ---------------------------------------------------------------------------
void _argumentsAndHelpers() {
  section('参数与辅助函数');

  check('miniprogram_state formal', isValidMiniprogramState('formal'), true);
  check('miniprogram_state trial', isValidMiniprogramState('trial'), true);
  check('miniprogram_state developer', isValidMiniprogramState('developer'), true);
  check('miniprogram_state 非法', isValidMiniprogramState('beta'), false);
  check('miniprogram_state 缺失', isValidMiniprogramState(null), true);
  check('版本通道映射 formal→stable', notifyVersionChannels['formal'], 'stable');

  check('page 缺省合法', isValidPage(null), true);
  check('page 普通路径合法', isValidPage('pages/order/index?foo=bar'), true);
  check('page 非字符串非法', isValidPage(1), false);
  check('page 外链非法', isValidPage('https://evil.example/x'), false);

  check('loopback 127.0.0.1', isLoopbackAddress('127.0.0.1'), true);
  check('loopback 127.1.2.3', isLoopbackAddress('127.1.2.3'), true);
  check('loopback ::1', isLoopbackAddress('::1'), true);
  check('loopback ipv4-mapped', isLoopbackAddress('::ffff:127.0.0.1'), true);
  check('非 loopback 局域网 IP', isLoopbackAddress('192.168.1.23'), false);
  check('非 loopback 公网 IP', isLoopbackAddress('8.8.8.8'), false);

  final List<Map<String, Object?>> fields = <Map<String, Object?>>[
    <String, Object?>{'key': 'thing01', 'type': 'thing'},
    <String, Object?>{'key': 'time2', 'type': 'time'},
  ];
  check('title 取模板名', messageTitle('订单状态'), '订单状态');
  check('body 按字段顺序拼值', messageBody(fields, goodData()), '订单已发货 · 15:01');
  checkTrue('body 截断到 512 字符以内', messageBody(fields, <String, Object?>{
    'thing01': <String, Object?>{'value': '长' * 300},
    'time2': <String, Object?>{'value': '15:01'},
  }).length <= 512);
  check('限流口径 20/分钟', notifyRatePerMinute, 20);
  check('限流口径 200/天', notifyRatePerDay, 200);

  // 契约 §2.3 铁律提醒：touser/lang 是 🔇 空转字段，逻辑层不提供任何开关，
  // 只能被「收下但不生效」——这里用注释固化，不需要可执行断言。
}
