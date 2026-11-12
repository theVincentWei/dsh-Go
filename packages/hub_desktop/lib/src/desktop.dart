// 「小程序」桌面的引擎画布:顶部搜索、固定最前的「最近使用」智能组、若干
// 用户分组,长按任意图标摇摆进整理模式:组内 / 跨组拖拽换位、新建 / 重命名
// / 删除分组、可卸载图标的「−」角标(点击直接上报宿主钩子;卸载弹窗等 UX
// 归宿主,桌面与市场详情页共用同一弹窗)。布局本机持久化(hubLayoutProvider),
// 目录与角标从宿主经 HubDesktopController 喂进的注册表读
// (hubTiles/hubBadges/hubSectionBadges),打开上报宿主 delegate,文案走宿主
// 注入的 strings;滚动视口与 ScrollController 自持在包内(宿主可注入
// controller)—— 这是后续拖拽边缘自动滚动的前提。
//
// 拖拽模型(Android Launcher 手感):按住 150ms 起拖——
// 1) 起拖记下基线分组表(_base,渲染几何)与同形的本地预演(_preview,落表
//    计算);渲染恒按基线槽位几何,预演差异用每格 AnimatedSlide 视觉偏移
//    表达(其他图标滑开让位),几何全程不 reflow。
// 2) 起拖的 post-frame(每组组尾预留空槽行的 reflow 落定后)量一次「槽位
//    矩形表」:组头 / 空组落区 / 每个槽位(含组尾预留槽)的内容坐标矩形,
//    内容坐标相对内容锚,滚动不改它;拖拽期间恒定。
// 3) 拖动中指针全局坐标换算回内容坐标,对矩形表取最近落区(整格命中,
//    16px 格距死区被最近格吸收):槽位 = 占住基线槽位上那颗的位置(前向
//    插目标后 / 后向插目标前,同一把尺子),组头 / 空组 / 预留槽 = 追加组尾。
// 4) 边缘自动滚动:指针距视口上/下缘 <48px 时按距离比例匀速 animateTo
//    (Timer 驱动,指针不动也滚);滚动只进换算不进表。
// 5) 松手才 assignSections 一把写回布局;松手位置矩形表内没有落区(或表
//    未就绪就松手)一律按非法落点弹回,不落库。
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

/// 矩形表的一条落区:第 [g] 个非智能组里,[slot] < 组内格数是普通槽位,
/// [slot] == 组内格数(组尾预留槽)或 -1(组头 / 空组落区)时语义是
/// 「追加到组尾」。矩形是内容坐标(相对内容锚),滚动不变。
class _HitRect {
  const _HitRect({required this.rect, required this.g, required this.slot});

  final Rect rect;
  final int g;
  final int slot;
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

  /// 非空表示正在拖:落表计算在本地预演([_preview])上做,渲染恒按起拖
  /// 时的基线([_base])槽位几何,落手才写回布局。
  List<_PreviewGroup>? _preview;

  /// 起拖瞬间的基线分组表(渲染几何),拖拽期间恒定。
  List<_PreviewGroup>? _base;
  String? _dragKey;

  /// 槽位矩形表:起拖的 post-frame(预留行 reflow 落定后)量一次,内容
  /// 坐标,拖拽期间恒定;边缘自动滚动只进换算不进表。null = 未就绪:
  /// 期间的指针移动只记坐标不算落点,自动滚动不启动,松手按非法弹回。
  List<_HitRect>? _hits;
  Size? _cellSize;

  /// 最后已知指针全局坐标(自动滚动靠它驱动,没有移动事件时也在滚)。
  Offset? _pointer;

  /// 拖拽期间的边缘自动滚动循环(表就绪那一拍才起,松手即停)。
  Timer? _scrollTimer;

  /// 量矩形用的键:内容锚(顶部占位盒,内容坐标原点)、滚动视口。槽位 /
  /// 组头 / 空组落区的键按需从 [_keyCache] 取(同一 id 恒同一把键):键的
  /// 生杀只在 LongPressDraggable 的 child 内部翻转,LongPress 元素本体
  /// 跨帧稳定 —— avatar 的回调闭包持有它的 State,本体一旦被重建换位,
  /// 闭包里的 mounted 永远是 false,拖动更新就全哑了。
  final GlobalKey _anchorKey = GlobalKey();
  final GlobalKey _scrollKey = GlobalKey();
  final Map<String, GlobalKey> _keyCache = <String, GlobalKey>{};

  GlobalKey _keyFor(String id) => _keyCache.putIfAbsent(id, GlobalKey.new);

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
    _scrollTimer?.cancel();
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

  /// 命中吸收半径:格与格 16px 的死区按最近格吸收,再远就不算落点。
  static const double _hitSlop = 16;

  /// 边缘自动滚动:距视口上/下缘 [kEdgeZone] 内触发,越近越快(线性),
  /// 最快 [kMaxScrollSpeed] 逻辑像素/秒。
  static const double kEdgeZone = 48;
  static const double _maxScrollSpeed = 700;

  void _startDrag(String key) {
    if (!_editing) return;
    final HubLayout layout = ref.read(hubLayoutProvider);
    final List<HubResolvedSection> resolved =
        resolveHubLayout(layout, _catalogKeys);
    final List<_PreviewGroup> base = <_PreviewGroup>[
      for (final HubResolvedSection r in resolved)
        if (!r.section.smart) _PreviewGroup(r.section.id, [...r.keys]),
    ];
    setState(() {
      _dragKey = key;
      // 基线与预演同源同形:渲染几何按基线(拖拽期间恒定),落表计算按
      // 预演;两者的差就是每格视觉偏移(让位动画)。
      _base = <_PreviewGroup>[
        for (final _PreviewGroup g in base) _PreviewGroup(g.id, [...g.keys]),
      ];
      _preview = base;
      _hits = null;
      _cellSize = null;
      _pointer = null;
    });
    // 预留槽行要一帧才进几何:矩形表等 reflow 落定后再量(post-frame),
    // 表就绪那一拍才允许计算落点与启动自动滚动。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _dragKey != null) _measureTable();
    });
  }

  /// 量槽位矩形表:相对内容锚(顶部占位盒)的内容坐标,滚动不改它。
  void _measureTable() {
    final List<_PreviewGroup>? base = _base;
    final RenderBox? anchor =
        _anchorKey.currentContext?.findRenderObject() as RenderBox?;
    if (base == null || anchor == null || !anchor.hasSize) return;
    final Offset origin = anchor.localToGlobal(Offset.zero);
    Rect? contentRect(GlobalKey? key) {
      final RenderBox? box = key?.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.attached || !box.hasSize) return null;
      return (box.localToGlobal(Offset.zero) - origin) & box.size;
    }

    final List<_HitRect> hits = <_HitRect>[];
    Size? cell;
    for (var g = 0; g < base.length; g++) {
      // 槽位先入表(含组尾预留槽):平局时优先选槽位而不是追加区。
      // 格尺寸取自真格,空组的预留槽量出来也一致。
      for (var i = 0; i <= base[g].keys.length; i++) {
        final Rect? rect = contentRect(_keyFor('slot:$g:$i'));
        if (rect == null) continue;
        hits.add(_HitRect(rect: rect, g: g, slot: i));
        if (i < base[g].keys.length) cell ??= rect.size;
      }
      // 组头 / 空组落区:语义都是追加到组尾。
      final Rect? head = contentRect(_keyFor('head:${base[g].id}'));
      if (head != null) hits.add(_HitRect(rect: head, g: g, slot: -1));
      final Rect? zone = contentRect(_keyFor('zone:${base[g].id}'));
      if (zone != null) hits.add(_HitRect(rect: zone, g: g, slot: -1));
    }
    if (hits.isEmpty) return;
    setState(() {
      _hits = hits;
      _cellSize = cell;
    });
    _startAutoScroll();
  }

  /// 拖到基线槽位 (g, slot):被拖 key 直投到这个槽位(指针在哪个格,它就
  /// 落哪个格,Launcher 手感),其余图标让位。预演已在该槽位时不动,防
  /// onMove / 自动滚动风暴反复 setState。
  void _moveToSlot(int g, int slot) {
    final List<_PreviewGroup>? preview = _preview;
    final String? drag = _dragKey;
    if (preview == null || drag == null) return;
    if (g < 0 || g >= preview.length || slot < 0) return;
    final int srcG = preview.indexWhere((_PreviewGroup p) => p.keys.contains(drag));
    if (srcG < 0) return;
    final int srcI = srcG == g ? preview[g].keys.indexOf(drag) : -1;
    final int landsAt = slot.clamp(0, preview[g].keys.length - (srcG == g ? 1 : 0));
    if (srcG == g && srcI == landsAt) return;
    setState(() {
      preview[srcG].keys.remove(drag);
      preview[g].keys.insert(landsAt, drag);
    });
  }

  /// 拖到分组头 / 空组 / 预留槽落点:追加到组尾(最近使用组不可落)。已在
  /// 该组组尾时不动,同上防风暴。
  void _moveToGroupEnd(String sectionId) {
    final List<_PreviewGroup>? preview = _preview;
    final String? drag = _dragKey;
    if (preview == null || drag == null) return;
    final int at = preview.indexWhere((_PreviewGroup g) => g.id == sectionId);
    if (at < 0) return;
    final int srcG = preview.indexWhere((_PreviewGroup g) => g.keys.contains(drag));
    if (srcG == at && preview[at].keys.isNotEmpty && preview[at].keys.last == drag) return;
    setState(() {
      for (final _PreviewGroup group in preview) {
        group.keys.remove(drag);
      }
      preview[at].keys.add(drag);
    });
  }

  /// 拖动中(LongPressDraggable.onDragUpdate 的裸指针全局坐标):记下指针,
  /// 表就绪才算落点——未就绪只记不算,自动滚动也不起。不用 DragTarget
  /// onMove 的 details.offset:那是 feedback 左上角(裸指针 − 起拖锚点),
  /// 恰好会落在格顶边上、与组头矩形平局。
  void _onDragUpdate(Offset global) {
    _pointer = global;
    if (_hits == null || _dragKey == null) return;
    _applyHitUnderPointer();
  }

  /// 指针落点 → 矩形表最近落区(整格命中):槽位 = 被拖 key 直投该槽,
  /// 组头 / 空组 / 预留槽 = 追加组尾。附近没有落区就保持上一个预演。
  void _applyHitUnderPointer() {
    final Offset? pointer = _pointer;
    final _HitRect? hit = pointer == null ? null : _hitAt(pointer);
    if (hit == null) return;
    final List<_PreviewGroup>? base = _base;
    if (base == null) return;
    if (hit.slot >= 0 && hit.slot < base[hit.g].keys.length) {
      _moveToSlot(hit.g, hit.slot);
    } else {
      _moveToGroupEnd(base[hit.g].id);
    }
  }

  /// 全局坐标 → 矩形表最近落区;[pointer] 位置超出所有落区 [_hitSlop] 外
  /// 返回 null(非法落点)。
  _HitRect? _hitAt(Offset pointer) {
    final List<_HitRect>? hits = _hits;
    final RenderBox? anchor =
        _anchorKey.currentContext?.findRenderObject() as RenderBox?;
    if (hits == null || anchor == null) return null;
    final Offset p = pointer - anchor.localToGlobal(Offset.zero);
    _HitRect? best;
    double bestD = double.infinity;
    for (final _HitRect h in hits) {
      final double d = _distanceSq(p, h.rect);
      // 严格更近才替换;恰好平局时槽位优先(表内槽位先入,追加区在后)。
      if (d < bestD) {
        bestD = d;
        best = h;
      }
    }
    if (best == null || bestD > _hitSlop * _hitSlop) return null;
    return best;
  }

  static double _distanceSq(Offset p, Rect r) {
    final double dx = p.dx.clamp(r.left, r.right).toDouble() - p.dx;
    final double dy = p.dy.clamp(r.top, r.bottom).toDouble() - p.dy;
    return dx * dx + dy * dy;
  }

  /// 松手:结束在合法落点上(松手位置矩形表内有落区)就整表落库,否则
  /// 弹回(丢弃预演)。表未就绪就松手一律按非法落点弹回;落库 / 弹回时
  /// 视觉偏移随预演一起清零(基线渲染恢复),不播反向动画。
  void _finishDrag({required bool assign}) {
    _scrollTimer?.cancel();
    _scrollTimer = null;
    final List<_PreviewGroup>? preview = _preview;
    final Offset? pointer = _pointer;
    final bool legal = switch ((_hits, pointer)) {
      (null, _) => false, // 表未就绪:安全默认,弹回不落库
      (_, null) => true, // 表就绪后原地松手:落回原位(预演 == 基线)
      (_, final Offset p?) => _hitAt(p) != null,
    };
    if (assign && legal && preview != null && _editing) {
      ref.read(hubLayoutProvider.notifier).assignSections(<({String id, List<String> keys})>[
        for (final _PreviewGroup group in preview) (id: group.id, keys: [...group.keys]),
      ]);
    }
    if (mounted) {
      setState(() {
        _preview = null;
        _base = null;
        _dragKey = null;
        _hits = null;
        _cellSize = null;
        _pointer = null;
      });
    }
  }

  // ---------- 边缘自动滚动 ----------

  void _startAutoScroll() {
    _scrollTimer?.cancel();
    _scrollTimer = Timer.periodic(const Duration(milliseconds: 16), (_) => _tickDrag());
  }

  /// 滚动循环的一拍:指针停在边缘不动也要滚(指针事件不再来),滚完顺手
  /// 用最后已知指针重算落点(手指不动、内容在动,目标会换)。
  void _tickDrag() {
    final Offset? pointer = _pointer;
    if (pointer == null || _dragKey == null) return;
    final RenderBox? box =
        _scrollKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return;
    final Rect viewport = box.localToGlobal(Offset.zero) & box.size;
    final double fromTop = pointer.dy - viewport.top;
    final double fromBottom = viewport.bottom - pointer.dy;
    double speed = 0;
    if (fromTop >= 0 && fromTop < kEdgeZone) {
      speed = -_maxScrollSpeed * (1 - fromTop / kEdgeZone);
    } else if (fromBottom >= 0 && fromBottom < kEdgeZone) {
      speed = _maxScrollSpeed * (1 - fromBottom / kEdgeZone);
    }
    if (speed != 0 && _scroll.hasClients) {
      final ScrollPosition position = _scroll.positions.first;
      if (position.hasContentDimensions && position.maxScrollExtent > 0) {
        final double target =
            (position.pixels + speed * 0.016).clamp(position.minScrollExtent, position.maxScrollExtent);
        if (target != position.pixels) {
          position.animateTo(target, duration: const Duration(milliseconds: 16), curve: Curves.linear);
        }
      }
    }
    _applyHitUnderPointer();
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
        HubIconPng(:final bytes) => Image.memory(
            bytes,
            width: IconTile.dimension,
            height: IconTile.dimension,
            fit: BoxFit.cover,
            gaplessPlayback: true,
          ),
        HubIconGlyph(:final glyphKey) =>
          widget.glyphBuilder?.call(glyphKey) ?? const SizedBox.shrink(),
      };

  /// glyph 档染实底瓷贴;widget/png 自带实底满铺,瓷贴保持默认淡染。
  Color? _chipColorFor(HubTile tile) => switch (tile.icon) {
        HubIconGlyph(:final color?) => color,
        _ => null,
      };

  /// 整理模式的摇摆 + 相位差(绕瓷贴自身中心旋转,不产生位移)。系统
  /// 「移除动画」/减弱动态时不摆:P5.2 实测静态相位角会让瓷贴绘制边界
  /// 偏移 ±2px 级(「有的左移有的不左移」的次级来源),直接归零。
  Widget _wiggleWrap(String key, Widget child) => AnimatedBuilder(
        animation: _wiggle,
        builder: (BuildContext context, Widget? child) {
          if (MediaQuery.of(context).disableAnimations) {
            return child!;
          }
          final double phase = (key.hashCode % 8) / 8;
          final double v = (_wiggle.value + phase) % 1.0;
          return Transform.rotate(angle: math.sin(v * 2 * math.pi) * 0.04, child: child);
        },
        child: child,
      );

  Widget _buildTile(
    HubTile tile, {
    required bool mirror,
    int? group,
    int? index,
  }) {
    final Widget core = IconTile(
      icon: _iconFor(tile),
      label: tile.name,
      enabled: tile.enabled,
      badge: _badgeFor(tile),
      chipColor: _chipColorFor(tile),
      labelDot: tile.labelDot,
      onTap: () => _open(tile),
      // 置灰瓷贴的点击也上报宿主(「本机不可用」类提示语义归宿主)。
      onDisabledTap: () => widget.delegate.onUnavailableTap(tile),
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

    // 结构:LongPressDraggable 元素本体必须跨帧稳定 —— avatar 的回调闭包
    // 持有它的 State,本体一旦因重建换位被拆掉,闭包里的 mounted 永远是
    // false,拖动更新(onDragUpdate)就全哑了。所以偏移层(基线槽位 →
    // 预演槽位的 AnimatedSlide,隐式动画让位;系统「移除动画」时瞬移)只
    // 放在 child 里,起拖 / 落手只是 child 换内容,LongPress 本体不重建。
    // 量矩形的 GlobalKey 挂在拖拽期渲染层上:框的布局位置就是基线槽位
    // (平移只在绘制 / 命中层),矩形表量出来恒是基线几何。
    final String key = tile.key;
    final int g = group ?? -1;
    final int i = index ?? -1;
    final bool draggingCell = g >= 0 && i >= 0 && _dragKey != null;
    final Duration slideDuration = MediaQuery.of(context).disableAnimations
        ? Duration.zero
        : const Duration(milliseconds: 180);
    final Offset slide = draggingCell ? _slideFor(g, i) : Offset.zero;
    final GlobalKey? cellKey = draggingCell ? _keyFor('slot:$g:$i') : null;
    Widget slideBox(Widget v, {required bool ghost}) {
      if (!draggingCell) return v;
      final Widget animated = AnimatedSlide(
        duration: slideDuration,
        curve: Curves.easeOutCubic,
        offset: slide,
        child: v,
      );
      return KeyedSubtree(
        key: cellKey,
        child: ghost ? Opacity(opacity: 0.25, child: animated) : animated,
      );
    }

    return LongPressDraggable<String>(
      data: key,
      delay: const Duration(milliseconds: 150),
      onDragStarted: () => _startDrag(key),
      // 裸指针全局坐标(全拖拽期间唯一可靠的落点来源)。
      onDragUpdate: (DragUpdateDetails details) => _onDragUpdate(details.globalPosition),
      onDragCompleted: () => _finishDrag(assign: true),
      onDraggableCanceled: (Velocity _, Offset _) => _finishDrag(assign: false),
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
      childWhenDragging: slideBox(visual, ghost: true),
      child: slideBox(visual, ghost: false),
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

  /// 一组格子。[group] 非空表示这是拖拽中的非智能组基线渲染:每格挂视觉
  /// 偏移,组尾加一格隐形预留槽(只在拖拽进行中出现,起止各一次单行
  /// reflow;矩形表量它,语义 = 追加到该组组尾)。
  Widget _grid(List<String> keys, {required bool mirror, int? group}) {
    final bool dragging = group != null && _dragKey != null;
    final List<Widget> cells = <Widget>[
      for (final (int i, String key) in keys.indexed)
        if (_byKey[key] case final HubTile tile?)
          _buildTile(tile, mirror: mirror, group: group, index: i),
    ];
    if (dragging) {
      cells.add(KeyedSubtree(
        key: _keyFor('slot:$group:${keys.length}'),
        child: ExcludeSemantics(
          child: IgnorePointer(
            child: Opacity(
              opacity: 0,
              // 隐形 dummy 与真格同几何(46 图块 + 一行名),行高不被压扁。
              child: IconTile(icon: const SizedBox.shrink(), label: '', onTap: () {}),
            ),
          ),
        ),
      ));
    }
    return TileGrid(columns: 4, spacing: 16, children: cells);
  }

  /// 基线槽 (g,i) 上的图标该滑到哪:这个 key 在预演里的槽位矩形 − 基线槽
  /// 位矩形(内容坐标差),换算成 AnimatedSlide 的 child 尺寸比例。表未就
  /// 绪(起拖第一帧)时全在原地。
  Offset _slideFor(int g, int i) {
    final List<_PreviewGroup>? base = _base;
    final List<_PreviewGroup>? preview = _preview;
    final List<_HitRect>? hits = _hits;
    final Size? cell = _cellSize;
    if (base == null || preview == null || hits == null || cell == null || cell.width <= 0 || cell.height <= 0) {
      return Offset.zero;
    }
    if (g >= base.length || i >= base[g].keys.length) return Offset.zero;
    final String key = base[g].keys[i];
    int pg = -1, pi = -1;
    for (final (int p, _PreviewGroup group) in preview.indexed) {
      final int at = group.keys.indexOf(key);
      if (at >= 0) {
        pg = p;
        pi = at;
      }
    }
    if (pg < 0 || pg >= base.length || pi > base[pg].keys.length) return Offset.zero;
    final Rect? from = _slotRect(hits, g, i);
    final Rect? to = _slotRect(hits, pg, pi);
    if (from == null || to == null) return Offset.zero;
    final Offset delta = to.topLeft - from.topLeft;
    return Offset(delta.dx / cell.width, delta.dy / cell.height);
  }

  Rect? _slotRect(List<_HitRect> hits, int g, int i) {
    for (final _HitRect h in hits) {
      if (h.g == g && h.slot == i) return h.rect;
    }
    return null;
  }

  /// 分组头:两态**同布局**(E2:进整理不得位移任何图标——旧整理态换成
  /// 带 48dp IconButton 的行,头一变高,组里图标整体下跳),编辑态只在
  /// 同一条头上用 Stack「浮」一颗不占布局的 ⋯(行高与普通态逐像素一致),
  /// 整条仍是「追加到组尾」落点(落点判定在矩形表,[dragGroup] 非空时挂
  /// 上量矩形的键)。
  Widget _header(HubSectionData section, {int? dragGroup}) {
    final HubDesktopStrings strings = widget.strings;
    final String name = section.name.isEmpty ? strings.defaultGroup : section.name;
    final HubBadge? badge = ref.watch(hubSectionBadgesProvider)[section.id];
    final bool pillVisible = (badge?.count ?? 0) > 0 || (badge?.text?.isNotEmpty ?? false);
    final Widget row;
    if (badge != null && pillVisible) {
      row = Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 16, 8),
        child: Row(
          children: <Widget>[
            Semantics(header: true, child: Text(name, style: hubGroupTitleStyle(context))),
            const SizedBox(width: 8),
            HubUnreadBadge(badge),
          ],
        ),
      );
    } else {
      row = FeatureGroupLabel(name);
    }
    if (!_editing) return row;
    final Widget editable = Stack(
      children: <Widget>[
        row,
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          child: Center(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => unawaited(_groupSheet(section)),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
                child: Icon(
                  Icons.more_horiz,
                  size: 20,
                  color: HubColors.of(context).textTertiary,
                ),
              ),
            ),
          ),
        ),
      ],
    );
    final GlobalKey? key = dragGroup == null ? null : _keyFor('head:${section.id}');
    if (key == null) return editable;
    return KeyedSubtree(key: key, child: editable);
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
      // 编辑提示行已删(E2):摇摆 + 右上圆键已足够表达,提示行一出现,
      // 下面的图标在进整理瞬间整体下移,违背「按住哪个图标,哪个不动」。
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
          // 最近使用组两态同款(E2:进整理不得位移任何图标——旧整理态
          // 强制出组头挂开关,组头一出,下面的图标整体往下跳):仅在有
          // 最近记录且未隐藏时显示,样式与普通组一致;隐藏开关移到编辑
          // 态右上角的钥匙(E4)。
          final List<String> recents = layout.recentsFor(_catalogKeys.toSet());
          if (!section.hidden && recents.isNotEmpty) {
            children.add(FeatureGroupLabel(strings.recentGroup));
            children.add(_grid(recents, mirror: true));
          }
          continue;
        }
        // 拖拽中渲染基线顺序(几何恒定,预演差异用视觉偏移表达),其余
        // 时候按布局。
        final int dragGroup = _dragKey != null
            ? (_base?.indexWhere((_PreviewGroup p) => p.id == section.id) ?? -1)
            : -1;
        final List<String> keys = dragGroup >= 0 ? _base![dragGroup].keys : r.keys;
        if (keys.isEmpty && !_editing) continue;
        children.add(_header(section, dragGroup: dragGroup >= 0 ? dragGroup : null));
        if (keys.isEmpty) {
          children.add(_dropZone(section.id, dragGroup: dragGroup >= 0 ? dragGroup : null));
        } else {
          children.add(_grid(keys, mirror: false, group: dragGroup >= 0 ? dragGroup : null));
        }
      }
      if (_editing) children.add(_newGroupButton());
    }

    // 全视口唯一 DragTarget:只做接落信号(保松手必触发 onDragCompleted,
    // 落点合法性由矩形表判定),不喂指针——onMove 的 offset 是 feedback
    // 左上角不是指针,指针从 LongPressDraggable.onDragUpdate 来。滚动轴与
    // 视口都在包内:内容首屏空出宿主壳的头部占位(HubPageInsets,没有——
    // 比如独立跑测试——就只空系统安全区),滚上来时从 pinned 标题底下经过、
    // 由宿主壳洗白;左右让出横屏的镜像侧缩进,宽窗口再收进阅读列(720)
    // 居中 —— 与宿主壳 AppPage 的 sideFor 同一公式,底部收尾同款。
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
    return DragTarget<String>(
      onWillAcceptWithDetails: (DragTargetDetails<String> _) => true,
      builder: (BuildContext context, _, _) => CustomScrollView(
        key: _scrollKey,
        controller: _scroll,
        // 整理模式锁掉用户滚动(E1):拖拽中的落点矩形表跟着滚就乱了,且
        // 摇摆图标随手势漂移;物理只关手势驱动,position.animateTo 这类
        // 程序驱动照常——拖拽贴上/下缘的边缘自动滚动(矩形表滚动补偿)
        // 不受影响。退出整理恢复。
        physics: _editing
            ? const NeverScrollableScrollPhysics()
            : HubMotion.scrollPhysics(context),
        slivers: <Widget>[
          // 内容锚:矩形表的内容坐标原点(它在内容顶上,随内容一起滚)。
          SliverToBoxAdapter(child: SizedBox(key: _anchorKey, height: top + header)),
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: side),
            sliver: SliverList.list(children: children),
          ),
          SliverToBoxAdapter(child: SizedBox(height: padding.bottom + 32)),
        ],
      ),
    );
  }

  Widget _dropZone(String sectionId, {int? dragGroup}) {
    final HubDesktopStrings strings = widget.strings;
    final Widget zone = Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      height: 62,
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor, width: 1.4),
        borderRadius: BorderRadius.circular(12),
      ),
      alignment: Alignment.center,
      child: Text(strings.dropHere, style: Theme.of(context).textTheme.bodySmall),
    );
    final GlobalKey? key = dragGroup == null ? null : _keyFor('zone:$sectionId');
    if (key == null) return zone;
    return KeyedSubtree(key: key, child: zone);
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
