/// 静默同步(万器扩展):链路建立 / 市场目录刷新 / 桌面注册者重推时跑——
/// **已安装**的 app 检测到新版本直接静默升级(2026-11-11 起全自动免确认,
/// 不再看 bundle.json 的 autoSync 标志);**没装的也一律静默装上桌面**
/// (2026-11-12 拍板「server 装了前端配套装」:目录里出现的新小程序直接
/// 装,不再要求 bundle.json 标 autoSync,该字段就此退役)。升级走原生
/// autoUpdate 旁路,容器不再弹「发现新版本」确认(DiminaPlugin 'sync'
/// 通道)。装好/升好的告知由 UI 层编排(§6.4):升级完成走容器的 applied
/// 事件,首装完成走 [AutoSyncRunner.installApplied]。
///
/// 结构:
///   * [planAutoSync] 纯函数(可单测):目录 + 本机已装 → 动作列表;
///   * [AutoSyncRunner] 执行器:拉目录 → 逐 app 查已装 → 执行 → 汇报,
///     单飞锁 + 每 (app, 目标版本) 10 分钟冷却,失败下次触发重试;
///   * **本机卸载豁免**(prefs `autosync.uninstalled-apps`):用户卸载(不
///     purge)的小程序不再被静默装回——否则「未装恒装」会把卸载语义吃掉;
///     手动从市场装回(执行器查到已装)或 purge 整包删除后豁免清除,重新
///     上架/重装恢复正常跟随;
///   * [AutoSyncSettings]/[autoSyncSettingsProvider] 总开关,默认开(自用场景),
///     SharedPreferences 持久化('autosync.enabled')。
///
/// 瓷贴落位不在这里做:新装成功后 invalidate hubInstalledProvider,桌面目录
/// 随之刷新,app_desktop 的 absorbUnplaced(锚 feature:apphub-market)会把
/// 没有 placement 的 mini 垫进市场入口所在分组(既有行为,2026-11-10 落地)。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
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
///   * 升级全自动(2026-11-11 拍板):**已安装**的 app 只要目录版本更高就
///     静默升级,不再看 autoSync 标志、不再弹容器确认;
///   * 首装全自动(2026-11-12 拍板「server 装了前端配套装」):目录里没装的
///     app 一律静默装上桌面——bundle.json 的 autoSync 字段就此退役(缺省
///     曾经 false = 只在市场出现,用户手动装);
///   * 已装不落后 / 目录缺 versionCode → 跳过;
///   * [attempted] 记录 (appId → 上次尝试的目标版本):同目标本周期已试过就
///     跳过(执行器负责冷却过期清理),失败重试交给下一次触发;
///   * [enabled] = false → 空 plan(总开关)。
List<AutoSyncAction> planAutoSync({
  required List<Map<String, Object?>> catalog,
  required Map<String, Map<String, Object?>?> installed,
  required bool enabled,
  Map<String, int> attempted = const <String, int>{},
  Set<String> excluded = const <String>{},
}) {
  if (!enabled) return const <AutoSyncAction>[];
  final List<AutoSyncAction> actions = <AutoSyncAction>[];
  for (final Map<String, Object?> app in catalog) {
    final String appId = app['appId'] as String? ?? '';
    if (appId.isEmpty) continue;
    final int? marketVersion =
        (app['versionCode'] as num?)?.toInt() ?? int.tryParse('${app['versionCode']}');
    if (marketVersion == null) continue;
    if (attempted[appId] == marketVersion) continue;
    final Map<String, Object?>? local = installed[appId];
    final bool isInstalled = local?['installed'] == true;
    // 卸载豁免:用户明确卸掉(未 purge)的本机未装 app 不再自动装回;
    // 已装 app 不受影响(升级是用户装过的延续)。
    if (!isInstalled && excluded.contains(appId)) continue;
    if (isInstalled) {
      final int? localVersion = (local?['versionCode'] as num?)?.toInt();
      if (localVersion == null || localVersion >= marketVersion) continue;
    }
    actions.add(AutoSyncAction(
      appId: appId,
      name: app['name'] as String? ?? appId,
      kind: isInstalled ? AutoSyncActionKind.update : AutoSyncActionKind.install,
      targetVersionCode: marketVersion,
      updateManifestUrl: '$appHubProxyBase/apps/$appId/manifest.json',
      iconUrl: app['iconUrl'] as String?,
    ));
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

  /// 首装完成事件广播(§6.4 首装修订,2026-11-12):静默同步真正装上一个
  /// 目录里的新小程序时发(UI 层订阅后落告知,与升级的容器 applied 事件
  /// 同轨)。只在静默同步装上时发——用户手动从市场首装不发(人就在市场
  /// 页,刚看着它装完,再告知一遍是噪音)。
  static final StreamController<AutoSyncOutcome> _installApplied =
      StreamController<AutoSyncOutcome>.broadcast();

  static Stream<AutoSyncOutcome> get installApplied => _installApplied.stream;

  /// 测试注入:直接向广播流发一条首装完成(widget 测试不走真网络/通道,
  /// 仿 onUpdateEvent 用 handlePlatformMessage 注入的玩法)。
  @visibleForTesting
  static void debugEmitInstallApplied(AutoSyncOutcome outcome) =>
      _installApplied.add(outcome);

  /// 本机卸载豁免表(prefs `autosync.uninstalled-apps`),语义见 library 头
  /// 注释:卸载(未 purge)→ 豁免不再自动装回;手动装回 / purge → 清除。
  static const String _excludedKey = 'autosync.uninstalled-apps';

  static Future<Set<String>> _loadExcluded() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      return (prefs.getStringList(_excludedKey) ?? const <String>[]).toSet();
    } catch (_) {
      // 没有 prefs 后端(测试外环境异常):不豁免,静默同步照常。
      return const <String>{};
    }
  }

  static Future<void> _saveExcluded(Set<String> excluded) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_excludedKey, excluded.toList()..sort());
    } catch (_) {
      // 持久化失败只影响下次冷启,本轮 plan 已经拿到内存态。
    }
  }

  /// 用户卸载(未 purge)时记豁免:静默同步不再自动装回(卸载编排
  /// runWholeUninstall 调,桌面钩子与市场详情页两个入口都会经过)。
  static Future<void> noteUninstalled(String appId) async {
    if (appId.isEmpty) return;
    final Set<String> excluded = await _loadExcluded();
    excluded.add(appId);
    await _saveExcluded(excluded);
  }

  /// purge 整包删除后清豁免:服务端 bundle 已删,以后重新上架同一 appId
  /// 应恢复自动跟随。
  static Future<void> notePurged(String appId) async {
    if (appId.isEmpty) return;
    final Set<String> excluded = await _loadExcluded();
    if (excluded.remove(appId)) await _saveExcluded(excluded);
  }

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
    final Set<String> excluded = await _loadExcluded();
    bool excludedDirty = false;
    for (final Map<String, Object?> app in catalog) {
      final String appId = app['appId'] as String? ?? '';
      if (appId.isEmpty) continue;
      final int? marketVersion =
          (app['versionCode'] as num?)?.toInt() ?? int.tryParse('${app['versionCode']}');
      if (marketVersion != null && !isDue(appId, marketVersion)) {
        attempted[appId] = marketVersion;
      }
      try {
        final Map<String, Object?>? local = await DiminaHost.installed(appId);
        installed[appId] = local;
        // 查到已装 = 用户手动装回了(或从没卸干净):清豁免,恢复自动跟随。
        if (local?['installed'] == true && excluded.remove(appId)) {
          excludedDirty = true;
        }
      } catch (_) {
        installed[appId] = null;
      }
    }
    if (excludedDirty) unawaited(_saveExcluded(excluded));

    final List<AutoSyncAction> actions = planAutoSync(
      catalog: catalog,
      installed: installed,
      enabled: enabled,
      attempted: attempted,
      excluded: excluded,
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
          if (action.kind == AutoSyncActionKind.install) {
            _installApplied.add(AutoSyncOutcome(
              appId: action.appId,
              kind: action.kind,
              ok: true,
              versionCode: version,
              detail: outcome,
            ));
          }
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
