/// autoSync 静默同步(万器扩展,bundle.json 顶层 `autoSync: true`):链路建立 /
/// 市场目录刷新时,对 autoSync 的 app 做「没装→静默装上、落后→静默升级」,
/// 不弹容器升级确认(原生 autoUpdate 旁路,见 DiminaPlugin 'sync' 通道)。
///
/// 结构:
///   * [planAutoSync] 纯函数(可单测):目录 + 本机已装 → 动作列表;
///   * [AutoSyncRunner] 执行器:拉目录 → 逐 app 查已装 → 执行 → 汇报,
///     单飞锁 + 每 (app, 目标版本) 10 分钟冷却,失败下次触发重试;
///   * [AutoSyncSettings]/[autoSyncSettingsProvider] 总开关,默认开(自用场景),
///     SharedPreferences 持久化('autosync.enabled')。
///
/// 瓷贴落位不在这里做:新装成功后 invalidate hubInstalledProvider,桌面目录
/// 随之刷新,app_desktop 的 absorbUnplaced(锚 feature:apphub-market)会把
/// 没有 placement 的 mini 垫进市场入口所在分组(既有行为,2026-11-10 落地)。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../notify/apphub_base.dart' show appHubBase;
import '../notify/apphub_proxy.dart' show appHubProxyBase;
import '../ui/applet/dimina/dimina_host.dart';

/// 上次尝试的标记:目标版本 + 时间(冷却用)。
class _Attempt {
  const _Attempt(this.versionCode, this.at);

  final int versionCode;
  final DateTime at;
}

/// 同一种动作。
enum AutoSyncActionKind { install, update }

/// 一条静默同步动作(planner 产物;runner 逐条执行)。
class AutoSyncAction {
  const AutoSyncAction({
    required this.appId,
    required this.name,
    required this.kind,
    required this.targetVersionCode,
    required this.updateManifestUrl,
    this.iconUrl,
  });

  final String appId;
  final String name;
  final AutoSyncActionKind kind;
  final int targetVersionCode;
  final String updateManifestUrl;
  final String? iconUrl;

  @override
  String toString() =>
      'AutoSyncAction($kind ${appId == '' ? '' : appId} v$targetVersionCode)';
}

/// 纯 planner:市场目录行 + 本机已装状态 → 动作列表。
///
///   * 只看 `autoSync == true` 的目录行(缺省/缺字段 = false = 不参与);
///   * 未装 → install;已装且目录 versionCode 更大 → update;
///   * 已装不落后 / 目录缺 versionCode → 跳过;
///   * [attempted] 记录 (appId → 上次尝试的目标版本):同目标本周期已试过就
///     跳过(执行器负责冷却过期清理),失败重试交给下一次触发;
///   * [enabled] = false → 空 plan(总开关)。
List<AutoSyncAction> planAutoSync({
  required List<Map<String, Object?>> catalog,
  required Map<String, Map<String, Object?>?> installed,
  required bool enabled,
  Map<String, int> attempted = const <String, int>{},
}) {
  if (!enabled) return const <AutoSyncAction>[];
  final List<AutoSyncAction> actions = <AutoSyncAction>[];
  for (final Map<String, Object?> app in catalog) {
    if (app['autoSync'] != true) continue;
    final String appId = app['appId'] as String? ?? '';
    if (appId.isEmpty) continue;
    final int? marketVersion =
        (app['versionCode'] as num?)?.toInt() ?? int.tryParse('${app['versionCode']}');
    if (marketVersion == null) continue;
    if (attempted[appId] == marketVersion) continue;
    final Map<String, Object?>? local = installed[appId];
    final bool isInstalled = local?['installed'] == true;
    if (isInstalled) {
      final int? localVersion = (local?['versionCode'] as num?)?.toInt();
      if (localVersion == null || localVersion >= marketVersion) continue;
      actions.add(AutoSyncAction(
        appId: appId,
        name: app['name'] as String? ?? appId,
        kind: AutoSyncActionKind.update,
        targetVersionCode: marketVersion,
        updateManifestUrl: '$appHubProxyBase/apps/$appId/manifest.json',
        iconUrl: app['iconUrl'] as String?,
      ));
    } else {
      actions.add(AutoSyncAction(
        appId: appId,
        name: app['name'] as String? ?? appId,
        kind: AutoSyncActionKind.install,
        targetVersionCode: marketVersion,
        updateManifestUrl: '$appHubProxyBase/apps/$appId/manifest.json',
        iconUrl: app['iconUrl'] as String?,
      ));
    }
  }
  return actions;
}

/// 一次执行的结果(日志/设置页摘要用)。
class AutoSyncOutcome {
  const AutoSyncOutcome({
    required this.appId,
    required this.kind,
    required this.ok,
    this.versionCode,
    this.detail,
  });

  final String appId;
  final AutoSyncActionKind kind;
  final bool ok;
  final int? versionCode;
  final String? detail;

  @override
  String toString() =>
      'AutoSyncOutcome($kind $appId ok=$ok v$versionCode${detail == null ? '' : ' $detail'})';
}

/// 执行器:单飞(并发触发只跑一次)+ 冷却。纯依赖注入(DiminaHost 是静态
/// 门面,测试里不执行 runner,只测 planner)。
class AutoSyncRunner {
  AutoSyncRunner._();

  static final AutoSyncRunner instance = AutoSyncRunner._();

  Future<void>? _inFlight;
  final Map<String, _Attempt> _attemptedAt = <String, _Attempt>{};
  DateTime _lastRunStart = DateTime.fromMillisecondsSinceEpoch(0);

  /// 同一目标版本的冷却窗:失败/网络抖动不会在每次目录刷新时重打。
  static const Duration attemptCooldown = Duration(minutes: 10);

  /// 两次 run 的最小间隔:桌面/市场页都可能频繁触发,目录 HTTP 拉取别跟着刷。
  static const Duration minRunInterval = Duration(seconds: 60);

  /// 是否到了可以再试的时候(测试可注入 now)。
  bool isDue(String appId, int targetVersionCode, {DateTime? now}) {
    final _Attempt? last = _attemptedAt[appId];
    if (last == null || last.versionCode != targetVersionCode) return true;
    return (now ?? DateTime.now()).difference(last.at) >= attemptCooldown;
  }

  /// 拉目录 → plan → 逐条执行。返回本轮流到的 outcomes(空 = 无事可做)。
  /// [force] 跳过最小运行间隔(设置开关等显式动作)。
  Future<List<AutoSyncOutcome>> run({bool force = false, bool enabled = true}) {
    if (!force && DateTime.now().difference(_lastRunStart) < minRunInterval) {
      return Future<List<AutoSyncOutcome>>.value(const <AutoSyncOutcome>[]);
    }
    // 单飞:进行中的触发直接并入,不叠加。
    final Future<void>? pending = _inFlight;
    if (pending != null) {
      return pending.then((_) => const <AutoSyncOutcome>[]);
    }
    _lastRunStart = DateTime.now();
    final Completer<void> gate = Completer<void>();
    _inFlight = gate.future;
    return _run(gate, force: force, enabled: enabled).whenComplete(() {
      _inFlight = null;
      gate.complete();
    });
  }

  Future<List<AutoSyncOutcome>> _run(
    Completer<void> gate, {
    required bool force,
    required bool enabled,
  }) async {
    if (!enabled) return const <AutoSyncOutcome>[];
    final List<Map<String, Object?>> catalog;
    try {
      final http.Response response = await http
          .get(Uri.parse('$appHubBase/api/v1/apps'))
          .timeout(const Duration(seconds: 8));
      final Object? body = jsonDecode(utf8.decode(response.bodyBytes));
      if (body is! Map || body['apps'] is! List) {
        return const <AutoSyncOutcome>[];
      }
      catalog = <Map<String, Object?>>[
        for (final dynamic app in body['apps'] as List<dynamic>)
          if (app is Map<String, Object?>) app,
      ];
    } catch (error) {
      debugPrint('[autoSync] catalog fetch failed: $error');
      return const <AutoSyncOutcome>[];
    }

    final Map<String, Map<String, Object?>?> installed =
        <String, Map<String, Object?>?>{};
    final Map<String, int> attempted = <String, int>{};
    for (final Map<String, Object?> app in catalog) {
      final String appId = app['appId'] as String? ?? '';
      if (appId.isEmpty) continue;
      final int? marketVersion =
          (app['versionCode'] as num?)?.toInt() ?? int.tryParse('${app['versionCode']}');
      if (marketVersion != null && !isDue(appId, marketVersion)) {
        attempted[appId] = marketVersion;
      }
      try {
        installed[appId] = await DiminaHost.installed(appId);
      } catch (_) {
        installed[appId] = null;
      }
    }

    final List<AutoSyncAction> actions = planAutoSync(
      catalog: catalog,
      installed: installed,
      enabled: enabled,
      attempted: attempted,
    );
    if (actions.isEmpty) return const <AutoSyncOutcome>[];

    final List<AutoSyncOutcome> outcomes = <AutoSyncOutcome>[];
    for (final AutoSyncAction action in actions) {
      _attemptedAt[action.appId] =
          _Attempt(action.targetVersionCode, DateTime.now());
      try {
        final Map<String, Object?>? result = await DiminaHost.sync(
          appId: action.appId,
          name: action.name,
          versionCode: action.targetVersionCode,
          updateManifestUrl: action.updateManifestUrl,
        );
        final String outcome =
            result?['outcome'] as String? ?? 'failed';
        final int? version = (result?['versionCode'] as num?)?.toInt();
        final bool ok = outcome == 'installed' || outcome == 'updated';
        outcomes.add(AutoSyncOutcome(
          appId: action.appId,
          kind: action.kind,
          ok: ok,
          versionCode: version,
          detail: outcome,
        ));
        debugPrint('[autoSync] $action → $outcome v$version');
        if (ok) {
          _attemptedAt.remove(action.appId); // 成功清冷却:下次目录对账无事可做
        }
      } catch (error) {
        outcomes.add(AutoSyncOutcome(
          appId: action.appId,
          kind: action.kind,
          ok: false,
          versionCode: action.targetVersionCode,
          detail: '$error',
        ));
        debugPrint('[autoSync] $action failed: $error');
      }
    }
    return outcomes;
  }
}

/// 总开关设置(默认开,自用场景;SharedPreferences 持久化)。
class AutoSyncSettings {
  const AutoSyncSettings({this.enabled = true, this.loaded = false});

  final bool enabled;

  /// 首次从 SharedPreferences 读回前为 false(UI 别拿默认值闪一下)。
  final bool loaded;

  AutoSyncSettings copyWith({bool? enabled, bool? loaded}) => AutoSyncSettings(
        enabled: enabled ?? this.enabled,
        loaded: loaded ?? this.loaded,
      );
}

const String _autoSyncEnabledKey = 'autosync.enabled';

/// 总开关 provider;`runIfDue` 是触发器(市场页加载/桌面目录落定时调用)。
final autoSyncProvider =
    NotifierProvider<AutoSyncController, AutoSyncSettings>(AutoSyncController.new);

class AutoSyncController extends Notifier<AutoSyncSettings> {
  Future<void>? _loaded;

  @override
  AutoSyncSettings build() {
    _loaded = _load();
    return const AutoSyncSettings();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // 缺键 = 默认开(setBool 只在用户显式关过时写入 false)。
      final bool? stored = prefs.getBool(_autoSyncEnabledKey);
      if (!ref.mounted) return;
      state = AutoSyncSettings(enabled: stored ?? true, loaded: true);
    } catch (_) {
      if (ref.mounted) state = state.copyWith(loaded: true);
    }
  }

  Future<void> setEnabled(bool on) async {
    await _loaded;
    if (!ref.mounted || state.enabled == on) return;
    state = state.copyWith(enabled: on);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_autoSyncEnabledKey, on);
    } catch (_) {
      // 持久化失败只影响下次冷启,本次内存态已生效。
    }
  }

  /// 触发一轮静默同步(单飞 + 冷却在 runner 内)。不 await:触发方继续渲染。
  /// [onApplied] 在有成功装/升时回调一次(UI 侧用它 invalidate 已装清单;
  /// 依赖注入避免 state 层反向依赖 widget)。
  void runIfDue({void Function()? onApplied}) {
    final AutoSyncSettings settings = state;
    if (!settings.enabled) return;
    unawaited(AutoSyncRunner.instance
        .run(enabled: settings.enabled)
        .then((List<AutoSyncOutcome> outcomes) {
      if (outcomes.any((AutoSyncOutcome o) => o.ok)) {
        onApplied?.call();
      }
    }));
  }
}
