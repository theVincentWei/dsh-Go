// 「小程序」桌面引擎画布的 widget 测试:目录经 HubDesktopController.upsertTiles
// 喂进注册表,断言分组渲染、搜索平铺、长按整理模式、组内 / 跨组拖拽落库、
// 新建 / 删除分组、卸载双条件(钩子未注册不出「−」;点击直接上报钩子,弹窗
// 归宿主)、声明式角标、组头角标、置灰与最近使用。控制器纯逻辑(upsert 幂等 /
// 锚点落位 / removeTile 保槽)在 controller_test;依赖宿主的用例(shell 返回键
// 分支、目录翻译、absorb 编排、完成按钮与大标题的对齐、注册者迁移回归、卸载
// 弹窗接线)留在 app/test/hub。字体由 flutter_test_config 统一加载;动画关闭时
// 摇摆不转,可 pumpAndSettle。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hub_desktop/hub_desktop.dart';
import 'package:shared_preferences/shared_preferences.dart';

const HubDesktopStrings strings = HubDesktopStrings(
  searchHint: '搜索小程序',
  editingHint: '整理模式:拖动图标换位或跨组,点分组名旁的 ⋯ 管理',
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

  @override
  void onOpen(HubTile tile) => opened.add(tile.key);
}

HubTile _tile(
  String id,
  String name, {
  bool enabled = true,
  bool uninstallable = false,
  List<String> aliases = const <String>[],
}) =>
    HubTile(
      key: 'feature:$id',
      name: name,
      icon: const HubIcon.widget(Icon(Icons.circle, size: 20)),
      enabled: enabled,
      uninstallable: uninstallable,
      searchAliases: aliases,
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
  const _Harness({required this.container, required this.delegate});

  final ProviderContainer container;
  final HubDesktopDelegate delegate;

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
            body: HubDesktopView(delegate: delegate, strings: strings),
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
  await tester.pumpWidget(_Harness(container: container, delegate: d));
  await tester.pumpAndSettle();
  return container;
}

/// 滚到 [finder] 可见(惰性列表里没构建的部件,finder 是找不到的)。
Future<void> _reveal(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(finder, 120, scrollable: find.byType(Scrollable).first);
  await Scrollable.ensureVisible(tester.element(finder), alignment: 0.5);
  await tester.pump();
}

/// 进整理模式(宿主的「完成」按钮不在引擎面里,直接看组头菜单)。
Future<void> _enterEdit(WidgetTester tester, String anyTileLabel) async {
  await tester.longPress(find.text(anyTileLabel));
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

  testWidgets('计数封顶 99+', (tester) async {
    await _pump(tester, badges: <String, HubBadge>{'feature:jia': const HubBadge(count: 120)});

    expect(find.text('99+'), findsOneWidget);
  });

  testWidgets('enabled:false 整块置灰不可点,enabled 的可点并上报', (tester) async {
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
  });

  testWidgets('组头角标:setSectionBadge 的组挂胶丸,别的组不挂', (tester) async {
    await _pump(tester, sectionBadges: <String, HubBadge>{'seed:组A': const HubBadge(count: 2)});

    // 「2」只出现在组A 头旁(图标格没有计数)。
    expect(find.text('2'), findsOneWidget);
  });
}
