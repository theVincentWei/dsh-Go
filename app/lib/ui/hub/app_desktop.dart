// 「小程序」Tab 的桌面:一张可整理的应用画布 —— 顶部搜索、固定最前的
// 「最近使用」智能组、若干用户分组(首装迁移自原静态目录),长按任意图标
// 摇摆进整理模式:组内 / 跨组拖拽换位、新建 / 重命名 / 删除分组、小程序
// 「−」角标卸载。布局本机持久化(hub_layout_state),打开动作记进最近使用。
//
// 拖拽模型:按住 150ms 起拖,整张分组表在页面本地预演(_preview),落在
// 哪个槽位就把被拖 key 插到目标 key 前(同组)或目标组该位置(跨组),分组
// 头 / 空组落点 = 追加到组尾;松手才 assignSections 一把写回布局。
library;

import 'dart:async';
import 'dart:typed_data';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../notify/apphub_proxy.dart' show appHubProxyBase;
import '../../state/bots_state.dart' show dsBotInboxProvider;
import '../../state/apphub_notices_state.dart' show appHubNoticesProvider;
import '../../state/auto_sync_state.dart' show autoSyncProvider;
import '../../state/hub_layout_state.dart';
import '../../state/sessions_state.dart' show currentSessionProvider;
import '../applet/apphub_uninstall_dialog.dart' show showAndRunAppUninstall;
import '../applet/dimina/dimina_host.dart';
import '../applet/hub_app_icon.dart'
    show HubAppIcon, hubAppHasIcon, hubAppIconSpec;
import '../applet/hub_apps_group.dart'
    show HubInstalledApp, hubAppGlyph, hubInstalledProvider;
import '../applet/hub_icon_cache.dart'
    show HubBundleIcon, hubIconCache;
import '../bots/bots_page.dart' show UnreadBadge;
import '../common/app_sheet.dart' show kSheetGutter, groupTitleStyle, showAppSheet;
import '../common/feature_tile.dart' show FeatureTile;
import '../common/list_page_row.dart' show ListPageCard, ListPageRow;
import '../common/search_capsule.dart' show SearchCapsule;
import '../common/sheet_title_bar.dart' show SheetTitleBar;
import '../common/tile_grid.dart' show FeatureGroupLabel, IconTile, TileGrid;
import '../features/all_features_page.dart' show dshWebOpenerProvider;
import '../features/feature_catalog.dart';
import '../shell/page_frame.dart' show AppPage;
import '../theme/theme.dart' show DshColors;
import 'hub_apps_catalog.dart';

/// 拖拽预演里的一条分组(可变;最近使用组永不进预演)。
class _PreviewGroup {
  _PreviewGroup(this.id, this.keys);

  final String id;
  final List<String> keys;
}

/// 桌面页。[sections] 仅供测试喂假目录;生产读 [featureSectionsProvider]。
class HubDesktopPage extends ConsumerStatefulWidget {
  const HubDesktopPage({super.key, this.sections});

  final List<FeatureSection>? sections;

  @override
  ConsumerState<HubDesktopPage> createState() => _HubDesktopPageState();
}

class _HubDesktopPageState extends ConsumerState<HubDesktopPage>
    with SingleTickerProviderStateMixin {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  /// 编辑态的唯一事实源是 [hubEditingProvider](shell 的返回键分支也要读):
  /// 这里用 getter 让 build 订阅、手势回调里读取。
  bool get _editing => ref.watch(hubEditingProvider);

  /// 整理模式的摇摆钟摆;图标按 key 加相位差,不必整齐划一。
  late final AnimationController _wiggle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  /// 非空表示正在拖:整张分组表以预演为准渲染。落手才写回布局。
  List<_PreviewGroup>? _preview;
  String? _dragKey;

  /// 本次拖拽是否结束在合法落点上(决定松手时落表还是弹回)。
  bool _dropped = false;

  /// build 时的目录快照,拖拽回调里用。
  Map<String, HubAppRef> _byKey = const <String, HubAppRef>{};
  List<String> _catalogKeys = const <String>[];

  @override
  void dispose() {
    _wiggle.dispose();
    _search.dispose();
    super.dispose();
  }

  // ---------- 整理模式 ----------

  void _enterEdit() {
    if (_editing) return;
    ref.read(hubEditingProvider.notifier).set(true);
  }

  void _exitEdit() {
    if (!_editing) return;
    ref.read(hubEditingProvider.notifier).set(false);
  }

  // ---------- 拖拽预演 ----------

  void _startDrag(String key) {
    if (!_editing) return;
    final HubLayout layout = ref.read(hubLayoutProvider);
    final List<HubResolvedSection> resolved =
        resolveHubLayout(layout, _catalogKeys);
    setState(() {
      _dropped = false;
      _dragKey = key;
      _preview = <_PreviewGroup>[
        for (final HubResolvedSection r in resolved)
          if (!r.section.smart) _PreviewGroup(r.section.id, [...r.keys]),
      ];
    });
  }

  /// 拖到某图标上:被拖 key 占住目标槽位,其余图标让位(先摘出,再插到目标
  /// 原索引;前向 = 插到目标后面,后向 = 插到目标前面,同一把尺子)。
  void _moveOver(String targetKey) {
    final List<_PreviewGroup>? preview = _preview;
    final String? drag = _dragKey;
    if (preview == null || drag == null || drag == targetKey) return;
    int srcG = -1, srcI = -1, tgtG = -1, tgtI = -1;
    for (final (int g, _PreviewGroup group) in preview.indexed) {
      final int si = group.keys.indexOf(drag);
      if (si >= 0) {
        srcG = g;
        srcI = si;
      }
      final int ti = group.keys.indexOf(targetKey);
      if (ti >= 0) {
        tgtG = g;
        tgtI = ti;
      }
    }
    if (tgtG < 0 || srcG < 0) return;
    setState(() {
      preview[srcG].keys.removeAt(srcI);
      preview[tgtG].keys.insert(tgtI, drag);
    });
  }

  /// 拖到分组头 / 空组落点:追加到组尾(最近使用组不可落)。
  void _moveToGroupEnd(String sectionId) {
    final List<_PreviewGroup>? preview = _preview;
    final String? drag = _dragKey;
    if (preview == null || drag == null) return;
    final int at = preview.indexWhere((_PreviewGroup g) => g.id == sectionId);
    if (at < 0) return;
    for (final _PreviewGroup group in preview) {
      group.keys.remove(drag);
    }
    setState(() => preview[at].keys.add(drag));
  }

  /// 松手:结束在合法落点上就整表落库,否则弹回(丢弃预演)。
  void _finishDrag({required bool assign}) {
    final List<_PreviewGroup>? preview = _preview;
    if (assign && preview != null && _editing) {
      ref.read(hubLayoutProvider.notifier).assignSections(<({String id, List<String> keys})>[
        for (final _PreviewGroup group in preview) (id: group.id, keys: [...group.keys]),
      ]);
    }
    if (mounted) {
      setState(() {
        _preview = null;
        _dragKey = null;
        _dropped = false;
      });
    }
  }

  // ---------- 打开与卸载 ----------

  void _touch(String key) =>
      ref.read(hubLayoutProvider.notifier).touch(key);

  void _openFeature(FeatureItem item) {
    final String? sessionId = ref.read(currentSessionProvider);
    if (item.native case final page?) {
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page(sessionId)));
    } else if (item.action case final action?) {
      unawaited(Future.sync(() => action(context, ref, sessionId)));
    } else if (item.web case final web?) {
      ref.read(dshWebOpenerProvider)(context, ref, item.webFor(sessionId) ?? web);
    }
  }

  Future<void> _open(HubAppRef app) async {
    switch (app) {
      case FeatureAppRef(:final item):
        _touch(app.key);
        _openFeature(item);
      case final MiniAppRef mini:
        // async gap 前取齐主题值,免 BuildContext 跨 await。
        final Color iconColor = Theme.of(context).colorScheme.primary;
        // bundle 图标优先直通原生;没有再按 key 栅格化。
        final Uint8List? bundlePng = await hubIconCache.load(
          mini.app.appId,
          mini.app.installedVersionCode ?? mini.app.marketVersionCode,
          mini.app.iconUrl,
        );
        final bool ok = await DiminaHost.open(
          appId: mini.app.appId,
          name: mini.app.name,
          // 菜单弹层头部图标:与桌面格子同款(bundle 图标或图标库栅格)。
          iconKey: mini.app.iconKey,
          iconColor: iconColor,
          iconPng: bundlePng,
          // 未装 = manifest 首装;已装旧版 = 后台拉新包自动升级。
          // 固定端口反代:原生容器拿到 URL 后才发请求,动态隧道端口可能
          // 已被重连换掉(见 apphub_proxy.dart)。
          updateManifestUrl:
              '$appHubProxyBase/apps/${mini.app.appId}/manifest.json',
          // autoSync 包:升级跳过容器确认弹窗(发布侧已表达确认语义)。
          autoUpdate: mini.app.autoSync,
        );
        if (ok) {
          _touch(mini.key);
          // 升级/兜底首装后版本号变了:重查已装清单,更新角标随之准确。
          // 落沙盒要一点时间,延迟复核一次(与市场页同款)。
          ref.invalidate(hubInstalledProvider);
          Timer(const Duration(seconds: 6), () {
            if (mounted) ref.invalidate(hubInstalledProvider);
          });
        }
    }
  }

  Future<void> _confirmUninstall(MiniAppRef app) async {
    if (!mounted) return;
    // 整包卸载语义(规范 §6):弹窗新文案 + 「同时清除主机数据」勾选;
    // 编排 = 先主机 remove(引擎终端通道)后本机卸载,主机不可达降级仅本机,
    // 失败信息走 SnackBar;布局槽位保留(重装原位恢复),已装清单在编排里
    // 失效重查。
    await showAndRunAppUninstall(context, ref,
        appId: app.app.appId, name: app.app.name);
  }

  // ---------- 分组管理 ----------

  Future<String?> _promptName(String title, String initial) {
    final TextEditingController controller = TextEditingController(text: initial);
    final L10n l10n = context.l10n;
    return showDialog<String>(
      context: context,
      builder: (BuildContext dialog) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          onSubmitted: (String value) => Navigator.of(dialog).pop(value),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(dialog).pop(), child: Text(l10n.commonCancel)),
          FilledButton(
            onPressed: () => Navigator.of(dialog).pop(controller.text),
            child: Text(l10n.commonSave),
          ),
        ],
      ),
    );
  }

  Future<void> _newGroup() async {
    final L10n l10n = context.l10n;
    final String? name = await _promptName(l10n.hubNewGroup, '');
    if (name == null) return;
    ref.read(hubLayoutProvider.notifier).createGroup(name);
  }

  Future<void> _renameGroup(HubSectionData section) async {
    final L10n l10n = context.l10n;
    final String? name = await _promptName(l10n.hubRename, section.name);
    if (name == null) return;
    ref.read(hubLayoutProvider.notifier).renameGroup(section.id, name);
  }

  Future<void> _groupSheet(HubSectionData section) async {
    final L10n l10n = context.l10n;
    final HubLayoutController notifier = ref.read(hubLayoutProvider.notifier);
    await showAppSheet(
      context,
      heightFactor: 0.5,
      builder: (BuildContext sheet) => Padding(
        padding: const EdgeInsets.all(kSheetGutter),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SheetTitleBar(section.name.isEmpty ? l10n.hubDefaultGroup : section.name),
            ListPageCard(
              children: <Widget>[
                ListPageRow(
                  leading: const Icon(Icons.edit_outlined),
                  leadingWidth: 40,
                  title: l10n.hubRename,
                  onTap: () {
                    Navigator.of(sheet).pop();
                    unawaited(_renameGroup(section));
                  },
                ),
                ListPageRow(
                  leading: const Icon(Icons.arrow_upward),
                  leadingWidth: 40,
                  title: l10n.hubMoveUp,
                  onTap: () {
                    Navigator.of(sheet).pop();
                    notifier.moveGroup(section.id, -1);
                  },
                ),
                ListPageRow(
                  leading: const Icon(Icons.arrow_downward),
                  leadingWidth: 40,
                  title: l10n.hubMoveDown,
                  onTap: () {
                    Navigator.of(sheet).pop();
                    notifier.moveGroup(section.id, 1);
                  },
                ),
                if (!section.locked)
                  ListPageRow(
                    leading: Icon(Icons.delete_outline, color: Theme.of(sheet).colorScheme.error),
                    leadingWidth: 40,
                    title: l10n.hubDeleteGroup,
                    subtitle: l10n.hubDeleteGroupBody(l10n.hubDefaultGroup),
                    onTap: () {
                      Navigator.of(sheet).pop();
                      notifier.deleteGroup(section.id);
                    },
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ---------- 渲染 ----------

  // 图标渲染顺序:bundle 图标(包内 main/icon.png,铺满瓷贴)> 图标库
  // 实底彩块字形 + 实底瓷贴 > 万能单色字形。三档同一颗语义。
  Widget _iconFor(HubAppRef app, BuildContext context) => switch (app) {
        MiniAppRef(:final app) when app.iconUrl != null => HubBundleIcon(
            appId: app.appId,
            versionCode: app.installedVersionCode ?? app.marketVersionCode,
            url: app.iconUrl,
            size: IconTile.dimension,
            fallback: _libraryIcon(app, context),
          ),
        MiniAppRef(:final app) => _libraryIcon(app, context),
        FeatureAppRef(:final item) => switch (item.tile) {
            final kind? => FeatureTile(kind, size: 30),
            null => Icon(item.icon, size: 20, color: Theme.of(context).colorScheme.primary),
          },
      };

  /// 图标库兜底:库内键实底彩块白字形(瓷贴底色由 _chipColorFor 染),
  /// 库外落万能单色字形(老行为)。
  Widget _libraryIcon(HubInstalledApp app, BuildContext context) =>
      hubAppHasIcon(app.iconKey)
          ? HubAppIcon(iconKey: app.iconKey, size: IconTile.dimension, tiled: false)
          : Icon(hubAppGlyph(app.iconKey),
              size: 20, color: Theme.of(context).colorScheme.primary);

  /// 小程序瓷贴底色:库内键且没有 bundle 图标时染实底;bundle 图标自带
  /// 实底满铺,瓷贴保持默认淡染。
  Color? _chipColorFor(HubAppRef app) => switch (app) {
        MiniAppRef(:final app) when app.iconUrl == null && hubAppHasIcon(app.iconKey) =>
          hubAppIconSpec(app.iconKey)!.color,
        _ => null,
      };

  /// 整理模式的摇摆 + 相位差。
  Widget _wiggleWrap(String key, Widget child) => AnimatedBuilder(
        animation: _wiggle,
        builder: (BuildContext context, Widget? child) {
          final double phase = (key.hashCode % 8) / 8;
          final double v = (_wiggle.value + phase) % 1.0;
          return Transform.rotate(angle: math.sin(v * 2 * math.pi) * 0.04, child: child);
        },
        child: child,
      );

  Widget _buildTile(
    HubAppRef app, {
    required bool enabled,
    required bool mirror,
  }) {
    final Widget core = IconTile(
      icon: _iconFor(app, context),
      label: app.name,
      enabled: enabled,
      badge: _badgeFor(app),
      chipColor: _chipColorFor(app),
      onTap: () => unawaited(_open(app)),
    );

    if (!_editing) {
      // 常驻:长按即进整理模式。
      return GestureDetector(onLongPress: _enterEdit, child: core);
    }

    // 整理模式:图标摇摆;小程序挂「−」卸载角标。最近使用组里的是镜像
    // (真身在自己分组),不参与拖拽,卸载也回真身那里做。
    Widget visual = _wiggleWrap(app.key, core);
    if (!mirror && app is MiniAppRef) {
      final ColorScheme scheme = Theme.of(context).colorScheme;
      visual = Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          visual,
          Positioned(
            left: -2,
            top: -2,
            child: GestureDetector(
              onTap: () => unawaited(_confirmUninstall(app)),
              child: Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(color: scheme.error, shape: BoxShape.circle),
                child: Icon(Icons.remove, size: 13, color: scheme.onError),
              ),
            ),
          ),
        ],
      );
    }
    if (mirror) return visual;

    // 结构:LongPressDraggable 在外(管起拖),DragTarget 在内(管接落);
    // builder 只渲染视觉件,绝不能把含 DragTarget 自身的变量塞回去(自引用)。
    final String key = app.key;
    return LongPressDraggable<String>(
      data: key,
      delay: const Duration(milliseconds: 150),
      onDragStarted: () => _startDrag(key),
      onDragCompleted: () => _finishDrag(assign: true),
      onDraggableCanceled: (Velocity _, Offset __) => _finishDrag(assign: _dropped),
      feedback: Material(
        type: MaterialType.transparency,
        child: Transform.scale(
          scale: 1.08,
          child: IconTile(
            icon: _iconFor(app, context),
            label: app.name,
            chipColor: _chipColorFor(app),
            onTap: () {},
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.25, child: visual),
      child: DragTarget<String>(
        onWillAcceptWithDetails: (DragTargetDetails<String> _) => true,
        onMove: (DragTargetDetails<String> details) => _moveOver(key),
        onAcceptWithDetails: (DragTargetDetails<String> _) => _dropped = true,
        builder: (BuildContext context, _, _) => visual,
      ),
    );
  }

  Widget? _badgeFor(HubAppRef app) {
    if (app is FeatureAppRef && app.item.id == 'ds-bot') {
      final int unread = ref.watch(dsBotInboxProvider.select((inbox) => inbox.total));
      if (unread > 0) {
        final ThemeData theme = Theme.of(context);
        return Container(
          width: 16,
          height: 16,
          alignment: Alignment.center,
          decoration: ShapeDecoration(
            color: theme.colorScheme.error,
            shape: const CircleBorder(),
          ),
          child: Text(
            unread > 99 ? '99+' : '$unread',
            style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onError, fontSize: 9, height: 1),
          ),
        );
      }
    }
    // 有更新:主色小点(与红色未读计数同一槽位,计数优先)。
    if (app is MiniAppRef && app.updateAvailable) {
      final ColorScheme scheme = Theme.of(context).colorScheme;
      return Container(
        key: const ValueKey('hub-update-dot'),
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: scheme.primary,
          shape: BoxShape.circle,
          border: Border.all(color: scheme.surface, width: 1.5),
        ),
      );
    }
    return null;
  }

  Widget _grid(List<String> keys, {required bool mirror, required String? sessionId}) => TileGrid(
        columns: 4,
        spacing: 16,
        children: <Widget>[
          for (final String key in keys)
            if (_byKey[key] case final HubAppRef app?)
              _buildTile(
                app,
                enabled: app is! FeatureAppRef ||
                    !app.item.needsSession ||
                    sessionId != null,
                mirror: mirror,
              ),
        ],
      );

  /// 分组头:常驻是老样式;整理模式挂 ⋯ 菜单,且整条是「追加到组尾」落点。
  /// [appHubUnread] 只给 AppHub 组:未读小程序通知的角标(契约 §6.1)。
  Widget _header(HubSectionData section, {int appHubUnread = 0}) {
    if (!_editing) {
      final L10n l10n = context.l10n;
      final String name = section.name.isEmpty ? l10n.hubDefaultGroup : section.name;
      if (appHubUnread <= 0) return FeatureGroupLabel(name);
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 16, 8),
        child: Row(
          children: <Widget>[
            Semantics(header: true, child: Text(name, style: groupTitleStyle(context))),
            const SizedBox(width: 8),
            UnreadBadge(appHubUnread),
          ],
        ),
      );
    }
    final L10n l10n = context.l10n;
    final Widget row = Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 16, 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              section.name.isEmpty ? l10n.hubDefaultGroup : section.name,
              style: groupTitleStyle(context),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.more_horiz, size: 20),
            onPressed: () => unawaited(_groupSheet(section)),
          ),
        ],
      ),
    );
    return DragTarget<String>(
      onWillAcceptWithDetails: (DragTargetDetails<String> _) => true,
      onMove: (DragTargetDetails<String> _) => _moveToGroupEnd(section.id),
      onAcceptWithDetails: (DragTargetDetails<String> _) => _dropped = true,
      builder: (BuildContext context, _, _) => row,
    );
  }

  @override
  Widget build(BuildContext context) {
    final L10n l10n = context.l10n;
    // 编辑态进出场:摇摆钟摆随 provider 启停(系统「移除动画」时不摇摆,
    // 测试环境同样走这条,可 pumpAndSettle)。
    ref.listen(hubEditingProvider, (bool? _, bool editing) {
      if (editing && !MediaQuery.of(context).disableAnimations) {
        _wiggle.repeat();
      } else if (!editing) {
        _wiggle
          ..stop()
          ..value = 0;
      }
    });
    final HubLayout layout = ref.watch(hubLayoutProvider);
    final AsyncValue<List<HubInstalledApp>> minis = ref.watch(hubInstalledProvider);
    final List<FeatureSection> sections =
        widget.sections ?? ref.watch(featureSectionsProvider);
    final HubCatalog catalog = buildHubCatalog(
      minis: minis.value ?? const <HubInstalledApp>[],
      sections: sections,
      settled: !minis.isLoading,
    );
    _byKey = <String, HubAppRef>{for (final HubAppRef app in catalog.apps) app.key: app};
    _catalogKeys = <String>[for (final HubAppRef app in catalog.apps) app.key];

    // 首装迁移:等布局读好、动态源落定,再把原静态目录原样转成用户分组。
    if (layout.loaded && !layout.seeded && catalog.settled && catalog.apps.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(ref
            .read(hubLayoutProvider.notifier)
            .ensureSeeded(catalog.seedGroups, defaultGroupName: l10n.hubDefaultGroup));
      });
    }

    // 新装小程序自动进 AppHub 组:布局种好、市场源落定后,把 items 里还没
    // 有位置的小程序垫进市场入口所在分组(absorbUnplaced)。迁移种子本来就
    // 会带上当时已装的小程序,这里只接「装在迁移之后」的;市场没连上时
    // (settled 为 true 但清单为空)目录里没有 mini,自然也不接。
    if (layout.loaded && layout.seeded && catalog.settled) {
      final List<String> unplacedMinis = <String>[
        for (final HubAppRef app in catalog.apps)
          if (app is MiniAppRef && !layout.items.containsKey(app.key)) app.key,
      ];
      if (unplacedMinis.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          ref.read(hubLayoutProvider.notifier).absorbUnplaced(
                unplacedMinis,
                anchorKey: 'feature:$hubMarketFeatureId',
              );
        });
      }
      // autoSync 静默同步:链路/目录落定时触发(单飞+冷却在 runner 内)。
      // 没装的 autoSync 应用静默装上、落后的静默升级;装/升成功后重查已装
      // 清单,新瓷贴走上面的 absorbUnplaced 自动落位。总开关:设置 → 通用。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.read(autoSyncProvider.notifier).runIfDue(onApplied: () {
          if (!mounted) return;
          ref.invalidate(hubInstalledProvider);
          Timer(const Duration(seconds: 6), () {
            if (mounted) ref.invalidate(hubInstalledProvider);
          });
        });
      });
    }

    final List<HubResolvedSection> resolved = resolveHubLayout(layout, _catalogKeys);
    final bool previewing = _preview != null;
    final String? sessionId = ref.watch(currentSessionProvider);

    final List<Widget> children = <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: SearchCapsule(
          controller: _search,
          hint: l10n.apphubSearchHint,
          onChanged: (String text) => setState(() {
            _query = text.trim().toLowerCase();
            if (_query.isNotEmpty) _exitEdit();
          }),
          onClear: () {
            _search.clear();
            setState(() => _query = '');
          },
        ),
      ),
      // 编辑态提示行:「完成」已上标题行右端,这里只留一句怎么用的说明。
      if (_editing)
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              l10n.hubEditing,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: DshColors.of(context).textTertiary,
                  ),
            ),
          ),
        ),
    ];

    if (_query.isNotEmpty) {
      // 搜索:平铺结果,不带分组头。
      final List<String> matches = <String>[
        for (final HubAppRef app in catalog.apps)
          if (app.name.toLowerCase().contains(_query) || app.key.contains(_query)) app.key,
      ];
      children.addAll(<Widget>[
        if (matches.isEmpty)
          Padding(
            padding: const EdgeInsets.all(28),
            child: Text(
              l10n.hubNoMatch(_query),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          )
        else
          _grid(matches, mirror: false, sessionId: sessionId),
      ]);
    } else {
      for (final HubResolvedSection r in resolved) {
        final HubSectionData section = r.section;
        if (section.smart) {
          final List<String> recents = layout.recentsFor(_catalogKeys.toSet());
          if (_editing) {
            children.add(_recentsHeader(section));
            if (!section.hidden && recents.isNotEmpty) {
              children.add(_grid(recents, mirror: true, sessionId: sessionId));
            }
          } else if (!section.hidden && recents.isNotEmpty) {
            children.add(FeatureGroupLabel(l10n.hubRecentGroup));
            children.add(_grid(recents, mirror: true, sessionId: sessionId));
          }
          continue;
        }
        // 拖拽中显示预演的组内顺序,其余时候按布局。
        final List<String> keys = previewing
            ? (_preview!.firstWhere((_PreviewGroup g) => g.id == section.id).keys)
            : r.keys;
        if (keys.isEmpty && !_editing) continue;
        // AppHub 组（装着小程序/市场入口的那组）挂未读通知角标。
        final bool appHubGroup = section.name == l10n.catalogAppHubSection ||
            r.keys.any((String key) => key.startsWith('mini:') || key == 'feature:apphub-market');
        children.add(_header(section,
            appHubUnread: appHubGroup ? ref.watch(appHubNoticesProvider.select((s) => s.unread)) : 0));
        if (keys.isEmpty) {
          children.add(_dropZone(section.id));
        } else {
          children.add(_grid(keys, mirror: false, sessionId: sessionId));
        }
      }
      if (_editing) children.add(_newGroupButton());
    }

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        AppPage.list(
          title: l10n.tabMiniApps,
          children: children,
        ),
        // 编辑态「完成」长在大标题行右端(与 iOS 桌面编辑同款):根路由没有
        // 浮动栏(page_frame 的 compact 态),叠加是唯一的出处,固定不随滚动。
        if (_editing)
          Positioned(
            top: MediaQuery.paddingOf(context).top + 10,
            right: 24,
            child: FilledButton.tonalIcon(
              onPressed: _exitEdit,
              icon: const Icon(Icons.check, size: 17),
              label: Text(l10n.commonDone),
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ),
      ],
    );
  }

  /// 最近使用组头:常驻就是普通组名(组空则整组不显示);整理模式永远显示,
  /// 右侧挂隐藏开关,方便再打开。
  Widget _recentsHeader(HubSectionData section) {
    final L10n l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 16, 8),
      child: Row(
        children: <Widget>[
          Expanded(child: Text(l10n.hubRecentGroup, style: groupTitleStyle(context))),
          Switch(
            value: !section.hidden,
            onChanged: (bool visible) =>
                ref.read(hubLayoutProvider.notifier).setRecentsHidden(!visible),
          ),
        ],
      ),
    );
  }

  Widget _dropZone(String sectionId) {
    final L10n l10n = context.l10n;
    return DragTarget<String>(
      onWillAcceptWithDetails: (DragTargetDetails<String> _) => true,
      onMove: (DragTargetDetails<String> _) => _moveToGroupEnd(sectionId),
      onAcceptWithDetails: (DragTargetDetails<String> _) => _dropped = true,
      builder: (BuildContext context, _, _) => Container(
        margin: const EdgeInsets.fromLTRB(16, 4, 16, 0),
        height: 62,
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).dividerColor, width: 1.4),
          borderRadius: BorderRadius.circular(12),
        ),
        alignment: Alignment.center,
        child: Text(l10n.hubDropHere, style: Theme.of(context).textTheme.bodySmall),
      ),
    );
  }

  Widget _newGroupButton() {
    final L10n l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
      child: OutlinedButton.icon(
        onPressed: () => unawaited(_newGroup()),
        icon: const Icon(Icons.add, size: 18),
        label: Text(l10n.hubNewGroup),
      ),
    );
  }
}
