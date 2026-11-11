// 桌面目录与角标的宿主注册者:引擎(HubDesktopController)只认 key,这里
// 把 dsh-go 的三个源翻译并整批同步进去 ——
// - 目录:minis + 市场入口 + 桌面工具 + feature 组(含插件面板)→ 全量
//   幂等 upsertTiles(锚点 = 市场入口,新 key 垫锚点组尾,即 absorbUnplaced
//   语义);目录缩编的 key removeTile(槽位保留,重装原位恢复);
// - 角标:ds-bot 未读 → setBadge('feature:ds-bot'),小程序通知未读计数 →
//   setBadge('mini:<id>', count)(瓷贴角,读过即消);「有更新/新装未打开」
//   指示走名字点(labelDot,iOS 式),瓷贴角不再挂 dot——两个指示器各管各的,
//   同一颗 mini 可同时有角上未读计数 + 名字点;AppHub 组头未读 → 对「装着
//   小程序或市场入口的非智能组」整批 setSectionBadge/clearSectionBadge
//   (按内容匹配,组名命中分支已废——改名叫 AppHub 但没装小程序的组不该亮
//   未读);
// - 卸载钩子:mini: → [miniAppUninstallerProvider](经根 navigator 弹共用
//   卸载弹窗 + 整包编排;市场详情页同弹窗同编排、不经此 provider)。
//
// keep-alive(非 autoDispose):由 DshApp 根装配处 ref.watch 一次养活,
// 应用生命周期存活——桌面页不在场(push/本地通知路径)角标也在线,免掉
// 每次进 tab 的补同步抖动。每次源变化全量重算,对引擎注册表的「现状」
// (read,不 watch——引擎状态是本同步的输出,watch 会成环)做差量清理;
// 所有写入都是幂等的,重复推同一批目录不产生任何额外落位或存储写入。
// 首装迁移(ensureSeeded)与 autoSync 静默同步仍归桌面页编排,不在本文
// 件——它们依赖 BuildContext 文案与页面时序。

import 'dart:async';

import 'package:flutter/material.dart'
    show BuildContext;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hub_desktop/hub_desktop.dart'
    show
        HubBadge,
        HubDesktopController,
        HubResolvedSection,
        HubTile,
        hubDesktopControllerProvider,
        hubLayoutProvider,
        hubSectionBadgesProvider,
        hubTilesProvider,
        resolveHubLayout;
import 'package:shared_preferences/shared_preferences.dart';

import '../ui/applet/apphub_uninstall_dialog.dart'
    show runWholeUninstall, showAppUninstallDialog;
import '../ui/applet/hub_apps_group.dart'
    show HubInstalledApp, hubInstalledProvider;
import '../ui/features/feature_catalog.dart'
    show FeatureSection, featureSectionsProvider;
import '../ui/shell/root_navigator_key.dart' show rootNavigatorKey;
import '../ui/hub/hub_apps_catalog.dart'
    show
        FeatureAppRef,
        HubAppRef,
        HubCatalog,
        MiniAppRef,
        buildHubCatalog,
        hubMarketFeatureId,
        hubTileOf;
import 'apphub_notices_state.dart'
    show appHubNoticesProvider, appHubUnreadByAppProvider;
import 'bots_state.dart' show dsBotInboxProvider;
import 'hub_layout_state.dart' show HubLayout;
import 'sessions_state.dart' show currentSessionProvider;
import 'terminal_state.dart' show terminalBackendProvider;

/// 小程序卸载执行函数(收敛点):桌面引擎钩子与市场详情页共用 —— 卸载
/// 「新装未打开」的小程序名字点(iOS 式):[hubNewMinisProvider] 的值 =
/// 当前亮着点的小程序 key 集(prefs `hub.new-minis`,跨重启保持);内部另
/// 持「见过的 key 全集」(prefs `hub.seen-minis`,只增)——清单里首次出现
/// (不在 seen)的 key 才点亮,防止重启后把老应用误判为新装。
class HubNewMinisController extends Notifier<Set<String>> {
  static const _newKey = 'hub.new-minis';
  static const _seenKey = 'hub.seen-minis';

  bool _loaded = false;
  Set<String> _seen = const <String>{};

  @override
  Set<String> build() {
    _load();
    return const <String>{};
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted) return;
      _seen = (prefs.getStringList(_seenKey) ?? const <String>[]).toSet();
      _loaded = true;
      state = (prefs.getStringList(_newKey) ?? const <String>[]).toSet();
    } catch (_) {
      // 没有 prefs 后端(测试外环境异常):不亮任何「新装点」,更新点照常。
      _loaded = true;
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_newKey, state.toList()..sort());
      await prefs.setStringList(_seenKey, _seen.toList()..sort());
    } catch (_) {
      // 只留这轮。
    }
  }

  /// 打开过一次 → 熄灭(无变化不通知,防与注册者的重推成环)。
  void markOpened(String key) {
    if (!_loaded || !state.contains(key)) return;
    state = <String>{...state}..remove(key);
    _persist();
  }

  /// 清单里首次出现的 key 记为「新装未打开」并点亮;seen 已见过的忽略。
  /// 无新增不赋值 state(幂等,防与注册者的重推成环)。
  void noteNew(Iterable<String> keys) {
    if (!_loaded) return; // prefs 未就绪:不判定不点亮,就绪后的重推会补
    final List<String> fresh = <String>[
      for (final String key in keys)
        if (!_seen.contains(key)) key,
    ];
    if (fresh.isEmpty) return;
    _seen.addAll(keys);
    state = <String>{...state, ...fresh};
    _persist();
  }
}

final hubNewMinisProvider =
    NotifierProvider<HubNewMinisController, Set<String>>(HubNewMinisController.new);


/// 桌面小程序卸载入口(引擎钩子的注入口):经根 navigator 打开共用卸载
/// 弹窗(purge 勾选是产品定案,引擎不再自带确认框,避免双重确认),确认
/// 后走整包卸载编排(先主机 wanqi bundle remove 后本机 DiminaHost.uninstall;
/// 主机不可达降级仅本机并 SnackBar 提示),返回是否真的卸了——布局槽位
/// 保留,重装原位恢复;已装清单在编排里失效重查(目录缩编 → sync 自动
/// removeTile)。市场详情页入口不经这里,直接 showAndRunAppUninstall
/// (同一弹窗、同一编排)。做成 provider:钩子闭包从 keep-alive 注册者
/// 这里 read,拿到的函数应用生命周期稳定。
final miniAppUninstallerProvider = Provider<Future<bool> Function(HubTile tile)>((ref) {
  return (HubTile tile) async {
    final BuildContext? context = rootNavigatorKey.currentContext;
    if (context == null) return false; // 根导航未挂(如测试环境):不可卸
    final String appId =
        tile.key.startsWith('mini:') ? tile.key.substring('mini:'.length) : tile.key;
    final (bool, bool)? decision =
        await showAppUninstallDialog(context, name: tile.name);
    if (decision == null || !decision.$1 || !context.mounted) return false;
    final String? sessionId = ref.read(currentSessionProvider);
    return runWholeUninstall(
      context: context,
      appId: appId,
      purge: decision.$2,
      backend:
          sessionId == null ? null : ref.read(terminalBackendProvider(sessionId)),
      invalidate: () => ref.invalidate(hubInstalledProvider),
    );
  };
});

/// 目录与角标的整批同步(keep-alive;激活方式见文件头)。
///
/// body 只跑一次:对每个源 ref.listen 常驻监听(通知阶段立即调度,不依赖
/// 有人再读本 provider——Riverpod 3 的依赖失效是惰性重建,没人读就永远
/// 不推,keep-alive 注册者必须用 listen 主动驱动),推送本体延后到微任务
/// ([_push]):Riverpod 3 禁止 provider 在自身 build 期间修改其他 provider,
/// 而同步的输出正是引擎侧那批 provider。
final hubDesktopSyncProvider = Provider<void>((ref) {
  bool scheduled = false;
  void schedule() {
    if (scheduled) return;
    scheduled = true;
    scheduleMicrotask(() {
      scheduled = false;
      if (!ref.mounted) return;
      _push(ref);
    });
  }

  ref.listen(hubInstalledProvider, (_, _) => schedule());
  ref.listen(featureSectionsProvider, (_, _) => schedule());
  ref.listen(currentSessionProvider, (_, _) => schedule());
  ref.listen(dsBotInboxProvider.select((inbox) => inbox.total), (_, _) => schedule());
  ref.listen(appHubNoticesProvider.select((s) => s.unread), (_, _) => schedule());
  ref.listen(appHubUnreadByAppProvider, (_, _) => schedule());
  ref.listen(hubLayoutProvider, (_, _) => schedule());
  // 名字点集变化(新装点亮 / 打开熄灭)→ 重发瓷贴;noteNew 幂等守卫防环。
  ref.listen(hubNewMinisProvider, (_, _) => schedule());
  // 初始一轮(listen 只报变化,首次的现状靠这里);同一轮多源齐变只推一次。
  schedule();
});

/// 一轮整批同步:读源现状 + 引擎注册表现状(read,不 watch——引擎状态是
/// 本同步的输出,watch 会成环),幂等地差量推送。
void _push(Ref ref) {
  final HubDesktopController hub = ref.read(hubDesktopControllerProvider);
  final AsyncValue<List<HubInstalledApp>> minis = ref.read(hubInstalledProvider);
  final List<FeatureSection> sections = ref.read(featureSectionsProvider);
  final String? sessionId = ref.read(currentSessionProvider);
  final int dsBotUnread = ref.read(dsBotInboxProvider).total;
  final int appHubUnread = ref.read(appHubNoticesProvider).unread;
  final Map<String, int> unreadByApp = ref.read(appHubUnreadByAppProvider);
  final HubLayout layout = ref.read(hubLayoutProvider);

  // 卸载钩子:幂等注册(重推覆盖同前缀)。执行经共用弹窗 + 整包编排。
  hub.registerUninstallHook('mini:', ref.read(miniAppUninstallerProvider));

  // ── 目录 ──
  final HubCatalog catalog = buildHubCatalog(
    minis: minis.value ?? const <HubInstalledApp>[],
    sections: sections,
    settled: !minis.isLoading,
  );
  // 目录分两把喂:小程序带锚点落位(= P1「新装小程序垫进市场入口所在
  // 分组」的编排,unplaced 只含 items 里没有的 mini);其余(市场入口、
  // 桌面工具、feature 组)不带锚点——它们的未安置项由解析垫在默认组尾,
  // 用户拖过的位置引擎永远不动。注册表序保持 minis 在前(= P1 目录序)。
  const String marketKey = 'feature:$hubMarketFeatureId';
  final Set<String> newMinis = ref.read(hubNewMinisProvider);
  hub.upsertTiles(<HubTile>[
    for (final HubAppRef app in catalog.apps)
      if (app is MiniAppRef)
        hubTileOf(app,
            enabled: true,
            labelDot: app.updateAvailable || newMinis.contains('mini:${app.app.appId}')),
  ], anchorKey: marketKey);
  hub.upsertTiles(<HubTile>[
    for (final HubAppRef app in catalog.apps)
      if (app is! MiniAppRef)
        hubTileOf(app, enabled: switch (app) {
          // MiniAppRef 已被上面过滤,这里只为穷尽 sealed 类。
          MiniAppRef() => true,
          FeatureAppRef(:final item) => !item.needsSession || sessionId != null,
        }),
  ]);
  // 缩编:注册表里有、目录里已没有的 key 撤下(市场没连上时目录不缩——
  // settled 为 false 的 loading 期不视为「已卸载」)。
  if (!minis.isLoading) {
    final Set<String> present =
        <String>{for (final HubAppRef app in catalog.apps) app.key};
    for (final String key in ref.read(hubTilesProvider).keys.toList()) {
      if (!present.contains(key)) hub.removeTile(key);
    }
  }

  // ── ds-bot 未读 ──
  const String dsBotKey = 'feature:ds-bot';
  if (dsBotUnread > 0) {
    hub.setBadge(dsBotKey, HubBadge(count: dsBotUnread));
  } else {
    hub.clearBadge(dsBotKey);
  }

  // ── 小程序瓷贴角标:通知未读计数 ──
  // 未读收件箱(契约 §6.1)按 appId 折叠出计数,读过即消。「有更新/新装
  // 未打开」指示已迁名字点(labelDot),瓷贴角不再挂 dot(用户裁决:更新
  // 不再回瓷贴角)——同一颗 mini 可以同时有角上未读计数 + 名字点,iOS 同款。
  for (final HubInstalledApp app in minis.value ?? const <HubInstalledApp>[]) {
    final String key = 'mini:${app.appId}';
    final int unread = unreadByApp[app.appId] ?? 0;
    if (unread > 0) {
      hub.setBadge(key, HubBadge(count: unread));
    } else {
      hub.clearBadge(key);
    }
  }

  // 「新装未打开」检测:清单(非 loading)里首次出现的 mini key 记入
  // hubNewMinis(点亮名字点);seen 已见过的忽略,幂等无新增不通知。
  if (!minis.isLoading) {
    ref.read(hubNewMinisProvider.notifier).noteNew(<String>[
      for (final HubInstalledApp app in minis.value ?? const <HubInstalledApp>[])
        'mini:${app.appId}',
    ]);
  }

  // ── AppHub 组头未读(整批同步)──
  final List<String> catalogKeys =
      <String>[for (final HubAppRef app in catalog.apps) app.key];
  final Map<String, HubBadge> desired = <String, HubBadge>{};
  if (appHubUnread > 0) {
    for (final HubResolvedSection r in resolveHubLayout(layout, catalogKeys)) {
      if (r.section.smart) continue;
      final bool appHubGroup = r.keys.any((String key) =>
          key.startsWith('mini:') || key == 'feature:$hubMarketFeatureId');
      if (appHubGroup) desired[r.section.id] = HubBadge(count: appHubUnread);
    }
  }
  // 对不再匹配的组先清(集合与 desired 不相交,先后无谓),再整批 set。
  for (final String id in ref.read(hubSectionBadgesProvider).keys.toList()) {
    if (!desired.containsKey(id)) hub.clearSectionBadge(id);
  }
  desired.forEach(hub.setSectionBadge);
}
