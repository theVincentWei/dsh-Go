// 「小程序」桌面引擎画布的 widget 测试:目录经 HubDesktopController.upsertTiles
// 喂进注册表,断言分组渲染、搜索平铺、长按整理模式、组内 / 跨组拖拽落库、
// 新建 / 删除分组、卸载双条件(钩子未注册不出「−」;点击直接上报钩子,弹窗
// 归宿主)、声明式角标、组头角标、置灰与最近使用。控制器纯逻辑(upsert 幂等 /
// 锚点落位 / removeTile 保槽)在 controller_test;依赖宿主的用例(shell 返回键
// 分支、目录翻译、absorb 编排、完成按钮与大标题的对齐、注册者迁移回归、卸载
// 弹窗接线)留在 app/test/hub。字体由 flutter_test_config 统一加载;动画关闭时
// 摇摆不转,可 pumpAndSettle。

import 'dart:convert';
import 'dart:typed_data';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hub_desktop/hub_desktop.dart';
import 'package:shared_preferences/shared_preferences.dart';

const HubDesktopStrings strings = HubDesktopStrings(
  searchHint: '搜索小程序',
  recentGroup: '最近使用',
  defaultGroup: '应用',
  newGroup: '新建分组',
  rename: '重命名',
  moveUp: '上移',
  moveDown: '下移',
  deleteGroup: '删除分组',
  deleteGroupBody: _deleteGroupBody,
  dropHere: '拖到这里',
  noMatch: _noMatch,
  cancel: '取消',
  save: '保存',
  clearLabel: '清除',
  closeLabel: '关闭',
);

String _deleteGroupBody(String group) => '「$group」组里的应用回到「应用」组,应用本身不受影响。';
String _noMatch(String query) => '没有匹配「$query」的应用';

/// 记录打开上报的假 delegate(卸载走钩子表,不走 delegate)。
class _RecordingDelegate implements HubDesktopDelegate {
  final List<String> opened = <String>[];
  final List<String> unavailableTapped = <String>[];

  @override
  void onOpen(HubTile tile) => opened.add(tile.key);

  @override
  void onUnavailableTap(HubTile tile) => unavailableTapped.add(tile.key);
}

HubTile _tile(
  String id,
  String name, {
  bool enabled = true,
  bool uninstallable = false,
  bool labelDot = false,
  List<String> aliases = const <String>[],
}) =>
    HubTile(
      key: 'feature:$id',
      name: name,
      icon: const HubIcon.widget(Icon(Icons.circle, size: 20)),
      enabled: enabled,
      uninstallable: uninstallable,
      searchAliases: aliases,
      labelDot: labelDot,
    );

HubTile _miniTile(String appId, String name, {bool uninstallable = true}) => HubTile(
      key: 'mini:$appId',
      name: name,
      icon: const HubIcon.widget(Icon(Icons.circle, size: 20)),
      uninstallable: uninstallable,
    );

List<HubTile> _catalogTiles() => <HubTile>[
      _tile('jia', '甲'),
      _tile('yi', '乙'),
      _tile('bing', '丙'),
      _tile('ding', '丁'),
    ];

/// 种子分组:组A 3 个、组B 1 个,默认组收尾。
List<({String title, List<String> keys})> get _twoGroups =>
    <({String title, List<String> keys})>[
      (title: '组A', keys: <String>['feature:jia', 'feature:yi', 'feature:bing']),
      (title: '组B', keys: <String>['feature:ding']),
    ];

/// Phone surface: 390×844 logical at DPR 2, with Android-ish system bar insets.
void usePhoneSurface(WidgetTester tester) {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = const Size(390 * 2, 844 * 2);
  tester.view.padding = const FakeViewPadding(top: 32 * 2, bottom: 24 * 2);
  tester.view.viewPadding = const FakeViewPadding(top: 32 * 2, bottom: 24 * 2);
  addTearDown(tester.view.reset);
}

class _Harness extends StatelessWidget {
  const _Harness({required this.container, required this.delegate, this.scrollController});

  final ProviderContainer container;
  final HubDesktopDelegate delegate;

  /// 边缘自动滚动测试用:注入滚动轴,断言 offset 增长。
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF4C7DD0)),
          useMaterial3: true,
        ),
        // Freeze the wiggle on a still frame (as the app's golden harness does).
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: UncontrolledProviderScope(
          container: container,
          child: Scaffold(
            body: HubDesktopView(
              delegate: delegate,
              strings: strings,
              controller: scrollController,
            ),
          ),
        ),
      );
}

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  List<HubTile> Function()? tiles,
  Map<String, HubBadge> badges = const <String, HubBadge>{},
  Map<String, HubBadge> sectionBadges = const <String, HubBadge>{},
  HubUninstallHook? uninstallHook,
  _RecordingDelegate? delegate,
  ScrollController? scrollController,
}) async {
  final ProviderContainer container = ProviderContainer();
  addTearDown(container.dispose);
  usePhoneSurface(tester);
  final _RecordingDelegate d = delegate ?? _RecordingDelegate();
  // 迁移种子直接种进布局(宿主编排不在引擎的面里)。
  await container
      .read(hubLayoutProvider.notifier)
      .ensureSeeded(_twoGroups, defaultGroupName: '应用');
  // 目录与角标经控制器喂进注册表(与生产宿主同一条路)。
  final HubDesktopController hub = container.read(hubDesktopControllerProvider);
  hub.upsertTiles(tiles?.call() ?? _catalogTiles());
  badges.forEach(hub.setBadge);
  sectionBadges.forEach(hub.setSectionBadge);
  if (uninstallHook != null) hub.registerUninstallHook('mini:', uninstallHook);
  await tester.pumpWidget(
    _Harness(container: container, delegate: d, scrollController: scrollController),
  );
  await tester.pumpAndSettle();
  return container;
}

/// 从 [from] 拖到 [to]:过 150ms 起拖延迟后分步插值移动(喂 onDragUpdate
/// 的裸指针路径),松手落库。
Future<void> _drag(WidgetTester tester, Offset from, Offset to) async {
  final TestGesture gesture = await tester.startGesture(from);
  await tester.pump(const Duration(milliseconds: 300));
  const int steps = 8;
  for (var i = 1; i <= steps; i++) {
    await gesture.moveTo(Offset.lerp(from, to, i / steps)!);
    await tester.pump(const Duration(milliseconds: 30));
  }
  await gesture.up();
  await tester.pumpAndSettle();
}

/// 滚到 [finder] 可见(惰性列表里没构建的部件,finder 是找不到的)。
Future<void> _reveal(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(finder, 120, scrollable: find.byType(Scrollable).first);
  await Scrollable.ensureVisible(tester.element(finder), alignment: 0.5);
  await tester.pump();
}

/// 进整理模式(宿主的「完成」按钮不在引擎面里,直接看组头菜单)。标签有
/// 重名(如最近使用镜像)时取第一颗:常驻态每颗图标都挂「长按进整理」。
Future<void> _enterEdit(WidgetTester tester, String anyTileLabel) async {
  await tester.longPress(find.text(anyTileLabel).first);
  await tester.pumpAndSettle();
  expect(find.byIcon(Icons.more_horiz), findsWidgets);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('按种子布局渲染分组与图标,没有打开记录时不显示最近使用', (tester) async {
    await _pump(tester);

    expect(find.text('组A'), findsOneWidget);
    expect(find.text('组B'), findsOneWidget);
    expect(find.text('甲'), findsOneWidget);
    expect(find.text('最近使用'), findsNothing);
    expect(find.text('新建分组'), findsNothing); // 默认不在整理模式
  });

  testWidgets('打开动作由宿主 touch 后,桌面出现最近使用镜像格', (tester) async {
    final ProviderContainer container = await _pump(tester);
    // 宿主在打开成功后调 touch(引擎只上报,不自己记)。
    container.read(hubLayoutProvider.notifier).touch('feature:jia');
    await tester.pumpAndSettle();

    expect(find.text('最近使用'), findsOneWidget);
    expect(find.text('甲'), findsNWidgets(2)); // 镜像 + 组内真身
  });

  testWidgets('进整理模式零位移:任一图标中心逐字节不变(E2)', (tester) async {
    // 摇摆是绕自身中心的旋转反馈,顶角随相位动是设计内的;「位置不动」
    // 断的是中心点:提示行已删、最近使用组头两态同款、分组头等高,中心
    // 逐字节相等。
    await _pump(tester);
    final Finder jia = find.widgetWithText(IconTile, '甲').first;
    final Finder ding = find.widgetWithText(IconTile, '丁').first;
    final Offset jiaCenter = tester.getCenter(jia);
    final Offset dingCenter = tester.getCenter(ding);

    await tester.longPress(find.text('甲').first);
    await tester.pumpAndSettle();

    expect(tester.getCenter(jia), jiaCenter);
    expect(tester.getCenter(ding), dingCenter);
  });

  testWidgets('编辑态锁用户滚动(E1),程序驱动滚动不受物理限制', (tester) async {
    // 注意:物理切换会让 Scrollable 重建 ScrollPosition(旧引用被 detach
    // + dispose,keepScrollOffset 保住像素位置),断言一律用「当下」的
    // position 再取,不跨阶段持引用。
    await _pump(tester);
    // 压矮视口让内容可滚(本 fixture 内容 ~420 逻辑高)。
    tester.view.physicalSize = const Size(390 * 2, 260 * 2);
    await tester.pumpAndSettle();
    ScrollPosition position =
        tester.state<ScrollableState>(find.byType(Scrollable).first).position;

    // 普通态:手势滚动有效。
    await tester.fling(find.byType(Scrollable).first, const Offset(0, -200), 3000);
    await tester.pumpAndSettle();
    expect(position.maxScrollExtent, greaterThan(0));
    expect(position.pixels, greaterThan(0));

    // 编辑态:手势滚动被物理锁死,位置一像素不动。
    await tester.longPress(find.text('甲').first);
    await tester.pumpAndSettle();
    position = tester.state<ScrollableState>(find.byType(Scrollable).first).position;
    final double lockedAt = position.pixels;
    await tester.fling(find.byType(Scrollable).first, const Offset(0, -200), 3000);
    await tester.pumpAndSettle();
    expect(position.pixels, lockedAt);

    // 程序驱动(边缘自动滚动走的 position.animateTo)照常工作:回到顶部。
    // 不能 await——测试体在 FakeAsync 区,真实时钟不走,动画永不结束;
    // 排后台用 pumpAndSettle 推时钟(引擎边缘滚动测试同款做法)。
    unawaited(position.animateTo(0, duration: const Duration(milliseconds: 200), curve: Curves.easeOut));
    await tester.pumpAndSettle();
    expect(position.pixels, 0);
  });

  testWidgets('搜索:平铺结果,分组头消失;无结果给提示', (tester) async {
    await _pump(tester);

    await tester.enterText(find.byType(TextField), '甲');
    await tester.pumpAndSettle();
    expect(find.text('组A'), findsNothing);
    expect(find.text('组B'), findsNothing);
    expect(find.widgetWithText(IconTile, '甲'), findsOneWidget);
    expect(find.widgetWithText(IconTile, '乙'), findsNothing);

    await tester.enterText(find.byType(TextField), '不存在');
    await tester.pumpAndSettle();
    expect(find.text('没有匹配「不存在」的应用'), findsOneWidget);
  });

  testWidgets('搜索命中别名', (tester) async {
    await _pump(tester, tiles: () => <HubTile>[
          _tile('jia', '甲', aliases: <String>['记']),
          _tile('yi', '乙'),
        ]);

    await tester.enterText(find.byType(TextField), '记');
    await tester.pumpAndSettle();
    expect(find.widgetWithText(IconTile, '甲'), findsOneWidget);
    expect(find.widgetWithText(IconTile, '乙'), findsNothing);
  });

  testWidgets('长按任意图标进整理模式,退出后组头菜单消失', (tester) async {
    final ProviderContainer container = await _pump(tester);
    await _enterEdit(tester, '甲');
    await _reveal(tester, find.text('新建分组'));
    expect(find.text('新建分组'), findsOneWidget);

    // 退出走 provider(宿主「完成」按钮写的就是它)。
    container.read(hubEditingProvider.notifier).set(false);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.more_horiz), findsNothing);
  });

  testWidgets('整理模式:新建分组', (tester) async {
    await _pump(tester);
    await _enterEdit(tester, '甲');

    await _reveal(tester, find.text('新建分组'));
    await tester.tap(find.text('新建分组'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '收藏');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.text('收藏'), findsOneWidget);
  });

  testWidgets('整理模式:删除分组后应用回「应用」组,不卸载', (tester) async {
    final ProviderContainer container = await _pump(tester);
    await _enterEdit(tester, '甲');

    // 分组头从上到下:组A、组B、应用;组A 的菜单是第 0 个。
    await tester.tap(find.byIcon(Icons.more_horiz).at(0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除分组'));
    await tester.pumpAndSettle();

    expect(find.text('组A'), findsNothing);
    expect(find.text('甲'), findsOneWidget); // 落回「应用」组,只是换组不卸载
    expect(container.read(hubLayoutProvider).section('seed:组A'), isNull);
  });

  testWidgets('组内拖拽换位并落库', (tester) async {
    final ProviderContainer container = await _pump(tester);
    await _enterEdit(tester, '甲');

    final Offset from = tester.getCenter(find.text('甲'));
    final TestGesture gesture = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 300)); // 过 LongPress 的 delay
    await gesture.moveBy(const Offset(24, 0));
    await tester.pump(const Duration(milliseconds: 60));
    await gesture.moveBy(const Offset(56, 0)); // 落到「乙」的槽位(约 78px 一格)
    await tester.pump(const Duration(milliseconds: 60));
    await gesture.up();
    await tester.pumpAndSettle();

    final HubLayout layout = container.read(hubLayoutProvider);
    expect(layout.items['feature:jia']!.sectionId, 'seed:组A');
    expect(layout.items['feature:jia']!.order, 1);
    expect(layout.items['feature:yi']!.order, 0);
    expect(
      tester.getCenter(find.text('甲')).dx,
      greaterThan(tester.getCenter(find.text('乙')).dx),
    );
  });

  testWidgets('跨组拖拽:甲从组A落到组B的丁前', (tester) async {
    final ProviderContainer container = await _pump(tester);
    // 844 高的画布上「组B」会落到折叠线以下(拖动落点在视口外就收不到
    // onMove)。这条测的是跨组落表,用更高的画布让起点与落点同屏。
    tester.view.physicalSize = const Size(390 * 2, 1000 * 2);
    await tester.pumpAndSettle();
    await _enterEdit(tester, '甲');

    final Offset from = tester.getCenter(find.text('甲'));
    final Offset to = tester.getCenter(find.text('丁'));
    final TestGesture gesture = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 300));
    const int steps = 14;
    for (var i = 1; i <= steps; i++) {
      await gesture.moveTo(Offset.lerp(from, to, i / steps)!);
      await tester.pump(const Duration(milliseconds: 30));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    final HubLayout layout = container.read(hubLayoutProvider);
    expect(layout.items['feature:jia']!.sectionId, 'seed:组B');
    expect(find.text('甲'), findsOneWidget);
  });

  testWidgets('双条件:uninstallable 但命名空间没挂钩子,不出「−」', (tester) async {
    await _pump(tester, tiles: () => <HubTile>[..._catalogTiles(), _miniTile('wx1', '记账本')]);

    await _enterEdit(tester, '甲');
    expect(find.byIcon(Icons.remove), findsNothing);
  });

  testWidgets('整理模式下挂了钩子的图标出「−」,点击直接上报钩子(UX 归宿主)', (tester) async {
    final List<String> uninstalled = <String>[];
    await _pump(
      tester,
      tiles: () => <HubTile>[..._catalogTiles(), _miniTile('wx1', '记账本')],
      uninstallHook: (HubTile tile) async {
        uninstalled.add(tile.key);
        return true;
      },
    );

    expect(find.byIcon(Icons.remove), findsNothing); // 常驻模式没有卸载入口
    await _enterEdit(tester, '甲');
    expect(find.byIcon(Icons.remove), findsOneWidget);

    // 没有引擎确认框:tap「−」直接调钩子(弹窗与 purge 勾选在宿主共用
    // 弹窗里,引擎面不出现对话框)。
    await tester.tap(find.byIcon(Icons.remove));
    await tester.pumpAndSettle();
    expect(uninstalled, <String>['mini:wx1']);
    expect(find.text('卸载 记账本'), findsNothing);
  });

  testWidgets('声明式角标:计数挂红圈、有更新挂主色小点,同挂计数优先', (tester) async {
    await _pump(tester, badges: <String, HubBadge>{
      'feature:jia': const HubBadge(count: 3),
      'feature:yi': const HubBadge(dot: true),
      'feature:bing': const HubBadge(count: 2, dot: true),
    });

    expect(find.text('3'), findsOneWidget);
    expect(find.byKey(const ValueKey('hub-update-dot')), findsOneWidget);
    expect(find.text('99+'), findsNothing);
    // 计数优先:丙格 count+dot 同挂,只显示红圈——全场仍只有乙一颗小点。
    expect(find.byKey(const ValueKey('hub-update-dot')), findsOneWidget);
  });

  testWidgets('名字点:labelDot 在名字行尾挂 4px 主色点,无点不占位', (tester) async {
    await _pump(tester, tiles: () => <HubTile>[
          _tile('jia', '甲', labelDot: true),
          _tile('yi', '乙'),
        ]);

    // 甲:名字行尾有点;乙:无点不占位。
    expect(find.byKey(const ValueKey('hub-label-dot')), findsOneWidget);
    final Offset dot = tester.getCenter(find.byKey(const ValueKey('hub-label-dot')));
    expect(dot.dx, greaterThan(tester.getCenter(find.text('甲')).dx)); // 名字右侧
    expect(dot.dy, tester.getCenter(find.text('甲')).dy); // 同一行
  });

  testWidgets('瓷贴内容层统一显示时裁切:icon 槽包 ClipRRect(圆角 14)', (tester) async {
    // 满铺方图(png 档)由 IconTile 内容层的 ClipRRect 裁成瓷贴形状;
    // glyph/widget 档居中不溢出,裁切无视觉差异但同一层兜底。
    const String redDot1x1PngBase64 =
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
    final Uint8List pngBytes = base64Decode(redDot1x1PngBase64);
    await _pump(tester, tiles: () => <HubTile>[
          HubTile(
            key: 'mini:png',
            name: '方图',
            icon: HubIcon.png(pngBytes),
          ),
          _tile('yi', '乙'),
        ]);

    // 每颗瓷贴的 icon 内容层都在 ClipRRect(半径=瓷贴圆角 14)内。
    final List<Widget> tiles = tester.widgetList<Widget>(find.byType(IconTile)).toList();
    expect(tiles, hasLength(2));
    for (final Widget tile in tiles) {
      final Finder inTile = find.descendant(
        of: find.byWidgetPredicate((Widget w) => identical(w, tile)),
        matching: find.byType(ClipRRect),
      );
      expect(inTile, findsWidgets, reason: '瓷贴内容层应有 ClipRRect');
      final ClipRRect clip = tester.widget<ClipRRect>(inTile.first);
      expect(clip.borderRadius, BorderRadius.circular(IconTile.radius));
    }
  });

  testWidgets('计数封顶 99+', (tester) async {
    await _pump(tester, badges: <String, HubBadge>{'feature:jia': const HubBadge(count: 120)});

    expect(find.text('99+'), findsOneWidget);
  });

  testWidgets('enabled:false 整块置灰不可开,点击转交 onUnavailableTap;enabled 的可点并上报', (tester) async {
    final _RecordingDelegate delegate = _RecordingDelegate();
    await _pump(
      tester,
      tiles: () => <HubTile>[_tile('jia', '甲'), _tile('yi', '乙', enabled: false)],
      delegate: delegate,
    );

    IconTile tile(String label) => tester.widget<IconTile>(find.widgetWithText(IconTile, label));
    expect(tile('甲').enabled, isTrue);
    expect(tile('乙').enabled, isFalse);

    await tester.tap(find.text('乙'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('甲'));
    await tester.pumpAndSettle();
    expect(delegate.opened, <String>['feature:jia']);
    // 置灰瓷贴的点击语义归宿主(「本机不可用」类提示)。
    expect(delegate.unavailableTapped, <String>['feature:yi']);
  });

  testWidgets('组头角标:setSectionBadge 的组挂胶丸,别的组不挂', (tester) async {
    await _pump(tester, sectionBadges: <String, HubBadge>{'seed:组A': const HubBadge(count: 2)});

    // 「2」只出现在组A 头旁(图标格没有计数)。
    expect(find.text('2'), findsOneWidget);
  });

  testWidgets('组内前向挤位:甲拖到丙槽位,落位插丙后(逐位断言)', (tester) async {
    final ProviderContainer container = await _pump(tester);
    await _enterEdit(tester, '甲');

    await _drag(tester, tester.getCenter(find.text('甲')), tester.getCenter(find.text('丙')));

    final HubLayout layout = container.read(hubLayoutProvider);
    expect(layout.items['feature:jia']!.sectionId, 'seed:组A');
    expect(layout.items['feature:jia']!.order, 2);
    expect(layout.items['feature:yi']!.order, 0);
    expect(layout.items['feature:bing']!.order, 1);
  });

  testWidgets('组内后向挤位:丙拖到甲槽位,落位插甲前(逐位断言)', (tester) async {
    final ProviderContainer container = await _pump(tester);
    await _enterEdit(tester, '甲');

    await _drag(tester, tester.getCenter(find.text('丙')), tester.getCenter(find.text('甲')));

    final HubLayout layout = container.read(hubLayoutProvider);
    expect(layout.items['feature:bing']!.sectionId, 'seed:组A');
    expect(layout.items['feature:bing']!.order, 0);
    expect(layout.items['feature:jia']!.order, 1);
    expect(layout.items['feature:yi']!.order, 2);
  });

  testWidgets('组头落点:甲拖到组B 头,追加到组尾(丁后)', (tester) async {
    final ProviderContainer container = await _pump(tester);
    await _enterEdit(tester, '甲');

    await _drag(tester, tester.getCenter(find.text('甲')), tester.getCenter(find.text('组B')));

    final HubLayout layout = container.read(hubLayoutProvider);
    expect(layout.items['feature:jia']!.sectionId, 'seed:组B');
    expect(layout.items['feature:jia']!.order, 1); // 丁(0)后面
    expect(layout.items['feature:ding']!.order, 0);
    expect(layout.items['feature:yi']!.order, 0); // 组A 收紧
    expect(layout.items['feature:bing']!.order, 1);
  });

  testWidgets('空组落点:新建空分组后把甲拖进它的拖放区', (tester) async {
    final ProviderContainer container = await _pump(tester);
    await _enterEdit(tester, '甲');
    // 与分组菜单同一条路建一个空组(排默认组前,所以「拖到这里」第一条是它)。
    container.read(hubLayoutProvider.notifier).createGroup('收藏');
    await tester.pumpAndSettle();

    await _drag(tester, tester.getCenter(find.text('甲')), tester.getCenter(find.text('拖到这里').first));

    final HubLayout layout = container.read(hubLayoutProvider);
    final String id =
        layout.sections.firstWhere((HubSectionData s) => s.name == '收藏').id;
    expect(layout.items['feature:jia']!.sectionId, id);
    expect(layout.items['feature:jia']!.order, 0);
    expect(layout.items['feature:yi']!.order, 0);
    expect(layout.items['feature:bing']!.order, 1);
  });

  testWidgets('非法落点弹回:松手在搜索框上,布局不动', (tester) async {
    final ProviderContainer container = await _pump(tester);
    await _enterEdit(tester, '甲');

    final Offset from = tester.getCenter(find.text('甲'));
    final Offset to = tester.getTopLeft(find.byType(TextField)) + const Offset(20, 10);
    await _drag(tester, from, to);

    final HubLayout layout = container.read(hubLayoutProvider);
    expect(layout.items['feature:jia']!.sectionId, 'seed:组A');
    expect(layout.items['feature:jia']!.order, 0); // 弹回:布局回到种子态
    expect(layout.items['feature:yi']!.order, 1);
    expect(layout.items['feature:bing']!.order, 2);
    expect(layout.items['feature:ding']!.order, 0);
  });

  testWidgets('拖拽中接近下缘自动滚动:offset 增长', (tester) async {
    final ScrollController scroll = ScrollController();
    addTearDown(scroll.dispose);
    await _pump(tester, scrollController: scroll);
    // 压矮视口,种子内容(搜索+组A+组B+默认组+新建分组)足够滚。
    tester.view.physicalSize = const Size(390 * 2, 560 * 2);
    await tester.pumpAndSettle();
    await _enterEdit(tester, '甲');
    expect(scroll.position.maxScrollExtent, greaterThan(0));

    final TestGesture gesture = await tester.startGesture(tester.getCenter(find.text('甲')));
    await tester.pump(const Duration(milliseconds: 300));
    // 指针停在下缘 48px 带内,推时钟:自动滚动 Timer 驱动 animateTo。
    await gesture.moveTo(const Offset(195, 560 - 20));
    await tester.pump();
    final double before = scroll.offset;
    await tester.pump(const Duration(milliseconds: 400));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(scroll.offset, greaterThan(before));
  });

  testWidgets('最近使用镜像不可拖、不可接落,最近记录不动', (tester) async {
    final ProviderContainer container = await _pump(tester);
    container.read(hubLayoutProvider.notifier).touch('feature:jia');
    await tester.pumpAndSettle();
    await _enterEdit(tester, '甲');

    // (a) 从镜像格(第一颗「甲」)起拖再移走:镜像没挂 Draggable,任何拖拽
    // 都不发生;移到乙的槽位若可拖会换位——断言布局纹丝不动。
    final Offset mirror = tester.getCenter(find.text('甲').first);
    final TestGesture ghost = await tester.startGesture(mirror);
    await tester.pump(const Duration(milliseconds: 300));
    await ghost.moveBy(const Offset(40, 160)); // 落进组A「乙」槽位的方向
    await tester.pump(const Duration(milliseconds: 60));
    await ghost.up();
    await tester.pumpAndSettle();

    HubLayout layout = container.read(hubLayoutProvider);
    expect(layout.items['feature:jia']!.sectionId, 'seed:组A');
    expect(layout.items['feature:jia']!.order, 0);

    // (b) 把真身拖到镜像上方(最近使用区不在矩形表里,无落区):弹回。
    final Offset aboveMirror = mirror - const Offset(0, 55);
    await _drag(tester, tester.getCenter(find.text('甲').last), aboveMirror);

    layout = container.read(hubLayoutProvider);
    expect(layout.recent, <String>['feature:jia']);
    expect(layout.items['feature:jia']!.sectionId, 'seed:组A');
    expect(layout.items['feature:jia']!.order, 0);
    expect(find.text('甲'), findsNWidgets(2)); // 镜像 + 真身都在
  });

  testWidgets('编辑态列间距取证(P5.1②):Flex 槽位恒等宽,视觉差=摇摆相位投影', (tester) async {
    // 复刻用户实机截图的那一行:三颗 mini(两颗带名字点、全带卸载角标)
    // + 一颗 feature 瓷贴。
    const List<HubTile> row = <HubTile>[
      HubTile(
          key: 'mini:a',
          name: 'GLM用量',
          icon: HubIcon.widget(Icon(Icons.circle)),
          labelDot: true,
          uninstallable: true),
      HubTile(
          key: 'mini:b',
          name: '系统监视器',
          icon: HubIcon.widget(Icon(Icons.circle)),
          uninstallable: true),
      HubTile(
          key: 'mini:c',
          name: '记账本',
          icon: HubIcon.widget(Icon(Icons.circle)),
          labelDot: true,
          uninstallable: true),
      HubTile(
          key: 'feature:market',
          name: '应用市场',
          icon: HubIcon.widget(Icon(Icons.circle))),
    ];
    await _pump(tester, tiles: () => row);
    await tester.longPress(find.text('GLM用量').first);
    await tester.pumpAndSettle();

    // 布局真相:TileGrid 的行是 Flex,四个 Expanded 槽位必然等宽等距
    // (parentData.offset 步进 = 槽宽 + spacing,逐格相等)。
    // IconTile 的首个 RenderBox 不是 Flex 直接子,沿 parent 上溯到挂
    // FlexParentData 的那层(= Row 的直接子,尺寸即槽位尺寸)。
    RenderBox flexCell(int i) {
      RenderBox cell = tester.renderObject<RenderBox>(find.byType(IconTile).at(i));
      while (cell.parentData is! FlexParentData) {
        cell = cell.parent! as RenderBox;
      }
      return cell;
    }

    double slotDx(int i) => (flexCell(i).parentData! as FlexParentData).offset.dx;

    double slotWidth(int i) => flexCell(i).size.width;

    final List<double> dxs = <double>[for (var i = 0; i < 4; i++) slotDx(i)];
    final List<double> widths = <double>[for (var i = 0; i < 4; i++) slotWidth(i)];
    // 槽宽逐格相等。
    expect(widths[0], widths[1]);
    expect(widths[1], widths[2]);
    expect(widths[2], widths[3]);
    // 槽位步进恒等(= 槽宽 + 16 间距),没有任何一格多出一档。
    expect(dxs[1] - dxs[0], dxs[2] - dxs[1]);
    expect(dxs[2] - dxs[1], dxs[3] - dxs[2]);

    // 视觉(含摇摆 Transform)上的间隙:随各格相位角有 ±2px 级投影差,
    // 这就是实机截图「记账本↔应用市场更宽」的来源——paint 层,非布局。
    double paintLeft(int i) => tester.getTopLeft(find.byType(IconTile).at(i)).dx;
    final List<double> paint = <double>[for (var i = 0; i < 4; i++) paintLeft(i)];
    // ignore: avoid_print
    print('DBG slots=$dxs widths=$widths paintLeft=$paint');
  });

  testWidgets('落库断言:拖拽后 prefs 里 v/sections/items/recent 全量正确', (tester) async {
    final ProviderContainer container = await _pump(tester);
    container.read(hubLayoutProvider.notifier).touch('feature:jia'); // recent 非空一起断
    await tester.pumpAndSettle();
    // 目录里有镜像格会让 find.text('甲') 双命中,直接从 provider 进整理态。
    container.read(hubEditingProvider.notifier).set(true);
    await tester.pumpAndSettle();

    await _drag(tester, tester.getCenter(find.text('甲').last), tester.getCenter(find.text('乙')));

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final Object? json = jsonDecode(prefs.getString(kHubLayoutPrefKey)!);
    expect((json as Map<Object?, Object?>)['v'], 1);
    final List<Object?> sections = json['sections'] as List<Object?>;
    expect(
      sections.map((Object? s) => (s as Map<Object?, Object?>)['id']),
      <Object?>['recent', 'seed:组A', 'seed:组B', 'default'],
    );
    final Map<Object?, Object?> items = json['items'] as Map<Object?, Object?>;
    expect(items['feature:jia'], <String, Object?>{'s': 'seed:组A', 'o': 1});
    expect(items['feature:yi'], <String, Object?>{'s': 'seed:组A', 'o': 0});
    expect(items['feature:bing'], <String, Object?>{'s': 'seed:组A', 'o': 2});
    expect(items['feature:ding'], <String, Object?>{'s': 'seed:组B', 'o': 0}); // 别组不夹带
    expect(json['recent'], <Object?>['feature:jia']);
    // 布局态与存储一致(同一份数据的两面)。
    final HubLayout layout = container.read(hubLayoutProvider);
    expect(layout.items['feature:jia']!.order, 1);
  });
}
