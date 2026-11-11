// 「小程序」桌面的引擎画布:顶部搜索、固定最前的「最近使用」智能组、若干
// 用户分组,长按任意图标摇摆进整理模式:组内 / 跨组拖拽换位、新建 / 重命名
// / 删除分组、可卸载图标的「−」角标(点击直接上报宿主钩子;卸载弹窗等 UX
// 归宿主,桌面与市场详情页共用同一弹窗)。布局本机持久化(hubLayoutProvider),
// 目录与角标从宿主经 HubDesktopController 喂进的注册表读
// (hubTiles/hubBadges/hubSectionBadges),打开上报宿主 delegate,文案走宿主
// 注入的 strings;滚动视口与 ScrollController 自持在包内(宿主可注入
// controller)—— 这是后续拖拽边缘自动滚动的前提。
//
// 拖拽模型:按住 150ms 起拖,整张分组表在页面本地预演(_preview),落在
// 哪个槽位就把被拖 key 插到目标 key 前(同组)或目标组该位置(跨组),分组
// 头 / 空组落点 = 追加到组尾;松手才 assignSections 一把写回布局。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'controller.dart';
import 'delegate.dart';
import 'layout.dart';
import 'model.dart';
import 'strings.dart';
import 'theme.dart';
import 'widgets/list_page_row.dart' show HubUnreadBadge, ListPageCard, ListPageRow;
import 'widgets/search_capsule.dart' show SearchCapsule;
import 'widgets/sheet.dart' show kSheetGutter, showHubSheet;
import 'widgets/sheet_title_bar.dart' show SheetTitleBar;
import 'widgets/tile_grid.dart' show FeatureGroupLabel, IconTile, TileGrid;

/// 宿主壳交给画布的头部占位:内容首屏空出「顶部安全区(+浮栏)+ 大标题
/// 高度」,滚上来时才能像壳自带滚动一样从 pinned 标题底下经过。宿主适配层
/// 从壳的 PageBodyInsets 翻译注入;树上没有它(独立跑、测试)时画布只空
/// 系统安全区。
class HubPageInsets extends InheritedWidget {
  const HubPageInsets({
    super.key,
    required this.top,
    required this.headerHeight,
    required super.child,
  });

  /// 顶部安全区 + 浮栏高度(compact 页浮栏为 0)。
  final double top;

  /// 已量得的大标题高度;没有头部时为 0。
  final double headerHeight;

  static HubPageInsets? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HubPageInsets>();

  @override
  bool updateShouldNotify(HubPageInsets oldWidget) =>
      oldWidget.top != top || oldWidget.headerHeight != headerHeight;
}

/// 拖拽预演里的一条分组(可变;最近使用组永不进预演)。
class _PreviewGroup {
  _PreviewGroup(this.id, this.keys);

  final String id;
  final List<String> keys;
}

/// 桌面画布。目录与角标读宿主经 [HubDesktopController] 喂进的注册表
/// ([hubTilesProvider] / [hubBadgesProvider] / [hubSectionBadgesProvider],
/// 有序:默认组未安置的按注册表序排);[controller] 可注入(宿主想共享
/// 滚动轴时),默认自建。
class HubDesktopView extends ConsumerStatefulWidget {
  const HubDesktopView({
    super.key,
    required this.delegate,
    required this.strings,
    this.controller,
    this.glyphBuilder,
  });

  final HubDesktopDelegate delegate;
  final HubDesktopStrings strings;

  /// 注入的滚动控制器;null = 自建(包内自持视口)。
  final ScrollController? controller;

  /// glyph 档的字形内容构建:引擎不认识任何图标库,宿主把「图标库键 →
  /// 白色字形小件」的映射挂进来;实底彩块由引擎按 HubIconGlyph.color 画。
  final Widget Function(String glyphKey)? glyphBuilder;

  @override
  ConsumerState<HubDesktopView> createState() => _HubDesktopViewState();
}

class _HubDesktopViewState extends ConsumerState<HubDesktopView>
    with SingleTickerProviderStateMixin {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  /// 注入的控制器归宿主管;自建的归这里。
  ScrollController? _ownController;
  ScrollController get _scroll => widget.controller ?? _ownController!;

  /// 编辑态的唯一事实源是 [hubEditingProvider](宿主壳的返回键分支、
  /// 「完成」按钮也读它):这里用 getter 让 build 订阅、手势回调里读取。
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
  Map<String, HubTile> _byKey = const <String, HubTile>{};
  List<String> _catalogKeys = const <String>[];

  @override
  void initState() {
    super.initState();
    if (widget.controller == null) _ownController = ScrollController();
  }

  @override
  void didUpdateWidget(HubDesktopView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == null && widget.controller != null) {
      _ownController?.dispose();
      _ownController = null;
    } else if (oldWidget.controller != null && widget.controller == null) {
      _ownController = ScrollController();
    }
  }

  @override
  void dispose() {
    _wiggle.dispose();
    _search.dispose();
    _ownController?.dispose();
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

  void _open(HubTile tile) {
    widget.delegate.onOpen(tile);
  }

  /// 卸载入口的双条件:tile 自己声明可卸 + key 命中宿主注册的钩子;
  /// 不挂钩子的命名空间(如自带功能)永远不出「−」。
  bool _canUninstall(HubTile tile) {
    final Map<String, HubUninstallHook> hooks = ref.watch(hubUninstallHooksProvider);
    return tile.uninstallable && hubUninstallHookFor(hooks, tile.key) != null;
  }

  /// 「−」点击:直接上报宿主钩子。卸载 UX(确认弹窗 + purge 勾选)归宿主
  /// ——桌面与市场详情页共用同一弹窗,引擎再弹自带确认框就是双重确认。
  /// 返回值不进引擎面(清单刷新是宿主编排,槽位由布局层保留)。
  Future<void> _uninstall(HubTile tile) async {
    final HubUninstallHook? hook =
        hubUninstallHookFor(ref.read(hubUninstallHooksProvider), tile.key);
    if (hook == null) return;
    await hook(tile);
  }

  // ---------- 分组管理 ----------

  Future<String?> _promptName(String title, String initial) {
    final TextEditingController controller = TextEditingController(text: initial);
    final HubDesktopStrings strings = widget.strings;
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
          TextButton(onPressed: () => Navigator.of(dialog).pop(), child: Text(strings.cancel)),
          FilledButton(
            onPressed: () => Navigator.of(dialog).pop(controller.text),
            child: Text(strings.save),
          ),
        ],
      ),
    );
  }

  Future<void> _newGroup() async {
    final HubDesktopStrings strings = widget.strings;
    final String? name = await _promptName(strings.newGroup, '');
    if (name == null) return;
    ref.read(hubLayoutProvider.notifier).createGroup(name);
  }

  Future<void> _renameGroup(HubSectionData section) async {
    final HubDesktopStrings strings = widget.strings;
    final String? name = await _promptName(strings.rename, section.name);
    if (name == null) return;
    ref.read(hubLayoutProvider.notifier).renameGroup(section.id, name);
  }

  Future<void> _groupSheet(HubSectionData section) async {
    final HubDesktopStrings strings = widget.strings;
    final HubLayoutController notifier = ref.read(hubLayoutProvider.notifier);
    await showHubSheet(
      context,
      heightFactor: 0.5,
      builder: (BuildContext sheet) => Padding(
        padding: const EdgeInsets.all(kSheetGutter),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SheetTitleBar(
              section.name.isEmpty ? strings.defaultGroup : section.name,
              closeTooltip: strings.closeLabel,
            ),
            ListPageCard(
              children: <Widget>[
                ListPageRow(
                  leading: const Icon(Icons.edit_outlined),
                  leadingWidth: 40,
                  title: strings.rename,
                  onTap: () {
                    Navigator.of(sheet).pop();
                    unawaited(_renameGroup(section));
                  },
                ),
                ListPageRow(
                  leading: const Icon(Icons.arrow_upward),
                  leadingWidth: 40,
                  title: strings.moveUp,
                  onTap: () {
                    Navigator.of(sheet).pop();
                    notifier.moveGroup(section.id, -1);
                  },
                ),
                ListPageRow(
                  leading: const Icon(Icons.arrow_downward),
                  leadingWidth: 40,
                  title: strings.moveDown,
                  onTap: () {
                    Navigator.of(sheet).pop();
                    notifier.moveGroup(section.id, 1);
                  },
                ),
                if (!section.locked)
                  ListPageRow(
                    leading: Icon(Icons.delete_outline, color: Theme.of(sheet).colorScheme.error),
                    leadingWidth: 40,
                    title: strings.deleteGroup,
                    subtitle: strings.deleteGroupBody(strings.defaultGroup),
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

  /// 图标渲染顺序(按 HubIcon 档):widget 直通;png 铺满瓷贴;glyph 档 =
  /// 实底彩块(chipColor 由 HubIconGlyph.color 染)+ 宿主构建的白色字形。
  Widget _iconFor(HubTile tile) => switch (tile.icon) {
        HubIconWidget(:final child) => child,
        HubIconPng(:final bytes) => ClipRRect(
            borderRadius: BorderRadius.circular(IconTile.radius),
            child: Image.memory(
              bytes,
              width: IconTile.dimension,
              height: IconTile.dimension,
              fit: BoxFit.cover,
              gaplessPlayback: true,
            ),
          ),
        HubIconGlyph(:final glyphKey) =>
          widget.glyphBuilder?.call(glyphKey) ?? const SizedBox.shrink(),
      };

  /// glyph 档染实底瓷贴;widget/png 自带实底满铺,瓷贴保持默认淡染。
  Color? _chipColorFor(HubTile tile) => switch (tile.icon) {
        HubIconGlyph(:final color?) => color,
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
    HubTile tile, {
    required bool mirror,
  }) {
    final Widget core = IconTile(
      icon: _iconFor(tile),
      label: tile.name,
      enabled: tile.enabled,
      badge: _badgeFor(tile),
      chipColor: _chipColorFor(tile),
      onTap: () => _open(tile),
    );

    if (!_editing) {
      // 常驻:长按即进整理模式。
      return GestureDetector(onLongPress: _enterEdit, child: core);
    }

    // 整理模式:图标摇摆;可卸载且挂了钩子的挂「−」卸载角标。最近使用
    // 组里的是镜像(真身在自己分组),不参与拖拽,卸载也回真身那里做。
    Widget visual = _wiggleWrap(tile.key, core);
    if (!mirror && _canUninstall(tile)) {
      final ColorScheme scheme = Theme.of(context).colorScheme;
      visual = Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          visual,
          Positioned(
            left: -2,
            top: -2,
            child: GestureDetector(
              onTap: () => unawaited(_uninstall(tile)),
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
    final String key = tile.key;
    return LongPressDraggable<String>(
      data: key,
      delay: const Duration(milliseconds: 150),
      onDragStarted: () => _startDrag(key),
      onDragCompleted: () => _finishDrag(assign: true),
      onDraggableCanceled: (Velocity _, Offset _) => _finishDrag(assign: _dropped),
      feedback: Material(
        type: MaterialType.transparency,
        child: Transform.scale(
          scale: 1.08,
          child: IconTile(
            icon: _iconFor(tile),
            label: tile.name,
            chipColor: _chipColorFor(tile),
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

  /// 声明式角标 → 瓷贴右上角的小件。计数/文本(计数优先)= 红圈 16;
  /// 小点 = 主色 10 带表面色描边(「有更新」)。count/text/dot 同挂时
  /// count 优先,其次 text。
  Widget? _badgeFor(HubTile tile) {
    final HubBadge? badge = ref.watch(hubBadgesProvider)[tile.key];
    if (badge == null) return null;
    final ThemeData theme = Theme.of(context);
    final int? count = badge.count;
    final String? text = badge.text;
    if ((count != null && count > 0) || (text != null && text.isNotEmpty)) {
      final Color color = badge.color ?? theme.colorScheme.error;
      final Color onColor = badge.color == null ? theme.colorScheme.onError : Colors.white;
      final String label = count != null && count > 0
          ? (count > 99 ? '99+' : '$count')
          : text!;
      return Container(
        width: 16,
        height: 16,
        alignment: Alignment.center,
        decoration: ShapeDecoration(color: color, shape: const CircleBorder()),
        child: Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(color: onColor, fontSize: 9, height: 1),
        ),
      );
    }
    if (badge.dot) {
      final ColorScheme scheme = Theme.of(context).colorScheme;
      return Container(
        key: const ValueKey('hub-update-dot'),
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: badge.color ?? scheme.primary,
          shape: BoxShape.circle,
          border: Border.all(color: scheme.surface, width: 1.5),
        ),
      );
    }
    return null;
  }

  Widget _grid(List<String> keys, {required bool mirror}) => TileGrid(
        columns: 4,
        spacing: 16,
        children: <Widget>[
          for (final String key in keys)
            if (_byKey[key] case final HubTile tile?)
              _buildTile(tile, mirror: mirror),
        ],
      );

  /// 分组头:常驻是老样式(宿主给该组 setSectionBadge 过就在名旁加胶丸);
  /// 整理模式挂 ⋯ 菜单,且整条是「追加到组尾」落点。
  Widget _header(HubSectionData section) {
    final HubDesktopStrings strings = widget.strings;
    final String name = section.name.isEmpty ? strings.defaultGroup : section.name;
    if (!_editing) {
      final HubBadge? badge = ref.watch(hubSectionBadgesProvider)[section.id];
      final bool pillVisible = (badge?.count ?? 0) > 0 || (badge?.text?.isNotEmpty ?? false);
      if (badge == null || !pillVisible) return FeatureGroupLabel(name);
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 16, 8),
        child: Row(
          children: <Widget>[
            Semantics(header: true, child: Text(name, style: hubGroupTitleStyle(context))),
            const SizedBox(width: 8),
            HubUnreadBadge(badge),
          ],
        ),
      );
    }
    final Widget row = Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 16, 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(name, style: hubGroupTitleStyle(context)),
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
    final HubDesktopStrings strings = widget.strings;
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
    _byKey = ref.watch(hubTilesProvider);
    _catalogKeys = _byKey.keys.toList(growable: false);

    final List<HubResolvedSection> resolved = resolveHubLayout(layout, _catalogKeys);
    final bool previewing = _preview != null;

    final List<Widget> children = <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: SearchCapsule(
          controller: _search,
          hint: strings.searchHint,
          clearLabel: strings.clearLabel,
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
      // 编辑态提示行:「完成」由宿主壳叠在大标题行右端,这里只留一句怎么用
      // 的说明。
      if (_editing)
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              strings.editingHint,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: HubColors.of(context).textTertiary,
                  ),
            ),
          ),
        ),
    ];

    if (_query.isNotEmpty) {
      // 搜索:平铺结果,不带分组头;名字 / key / 别名命中都算。
      final List<String> matches = <String>[
        for (final HubTile tile in _byKey.values)
          if (tile.name.toLowerCase().contains(_query) ||
              tile.key.contains(_query) ||
              tile.searchAliases.any((String alias) => alias.toLowerCase().contains(_query)))
            tile.key,
      ];
      children.addAll(<Widget>[
        if (matches.isEmpty)
          Padding(
            padding: const EdgeInsets.all(28),
            child: Text(
              strings.noMatch(_query),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          )
        else
          _grid(matches, mirror: false),
      ]);
    } else {
      for (final HubResolvedSection r in resolved) {
        final HubSectionData section = r.section;
        if (section.smart) {
          final List<String> recents = layout.recentsFor(_catalogKeys.toSet());
          if (_editing) {
            children.add(_recentsHeader(section));
            if (!section.hidden && recents.isNotEmpty) {
              children.add(_grid(recents, mirror: true));
            }
          } else if (!section.hidden && recents.isNotEmpty) {
            children.add(FeatureGroupLabel(strings.recentGroup));
            children.add(_grid(recents, mirror: true));
          }
          continue;
        }
        // 拖拽中显示预演的组内顺序,其余时候按布局。
        final List<String> keys = previewing
            ? (_preview!.firstWhere((_PreviewGroup g) => g.id == section.id).keys)
            : r.keys;
        if (keys.isEmpty && !_editing) continue;
        children.add(_header(section));
        if (keys.isEmpty) {
          children.add(_dropZone(section.id));
        } else {
          children.add(_grid(keys, mirror: false));
        }
      }
      if (_editing) children.add(_newGroupButton());
    }

    // 视口与滚动都在包内:内容首屏空出宿主壳的头部占位(HubPageInsets,
    // 没有——比如独立跑测试——就只空系统安全区),滚上来时从 pinned 标题
    // 底下经过、由宿主壳洗白;左右让出横屏的镜像侧缩进,宽窗口再收进阅读
    // 列(720)居中 —— 与宿主壳 AppPage 的 sideFor 同一公式,底部收尾同款。
    final MediaQueryData media = MediaQuery.of(context);
    final EdgeInsets padding = media.padding;
    final double side = math.max(
      math.max(padding.left, padding.right),
      ((media.size.width - 720) / 2).floorToDouble(),
    );
    final (double top, double header) = switch (HubPageInsets.maybeOf(context)) {
      HubPageInsets(:final top, :final headerHeight) => (top, headerHeight),
      null => (padding.top, 0.0),
    };
    return CustomScrollView(
      controller: _scroll,
      physics: HubMotion.scrollPhysics(context),
      slivers: <Widget>[
        SliverToBoxAdapter(child: SizedBox(height: top + header)),
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: side),
          sliver: SliverList.list(children: children),
        ),
        SliverToBoxAdapter(child: SizedBox(height: padding.bottom + 32)),
      ],
    );
  }

  /// 最近使用组头:常驻就是普通组名(组空则整组不显示);整理模式永远显示,
  /// 右侧挂隐藏开关,方便再打开。
  Widget _recentsHeader(HubSectionData section) {
    final HubDesktopStrings strings = widget.strings;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 16, 8),
      child: Row(
        children: <Widget>[
          Expanded(child: Text(strings.recentGroup, style: hubGroupTitleStyle(context))),
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
    final HubDesktopStrings strings = widget.strings;
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
        child: Text(strings.dropHere, style: Theme.of(context).textTheme.bodySmall),
      ),
    );
  }

  Widget _newGroupButton() {
    final HubDesktopStrings strings = widget.strings;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
      child: OutlinedButton.icon(
        onPressed: () => unawaited(_newGroup()),
        icon: const Icon(Icons.add, size: 18),
        label: Text(strings.newGroup),
      ),
    );
  }
}
