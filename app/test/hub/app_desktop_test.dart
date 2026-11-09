// 「小程序」桌面页的 widget 测试:迁移渲染、搜索平铺、长按整理模式、组内 /
// 跨组拖拽、新建 / 删除分组、小程序「−」卸载角标。字体由 flutter_test_config
// 统一加载;动画关闭(goldenApp)时摇摆不转,可 pumpAndSettle。

import 'package:dsh_app/runtime/runtime_state.dart'
    show LocalRuntimeState, localRuntimeLogsProvider, localRuntimeProvider;
import 'package:dsh_app/pets/pet_mood.dart' show PetMood, PetScope;
import 'package:dsh_app/pets/pet_signals.dart'
    show PetMoodController, petMoodProvider;
import 'package:dsh_app/state/bots_state.dart'
    show DsBotAvailability, DsBotController, DsBotInbox, DsBotInboxController, DsBotStatus, dsBotInboxProvider, dsBotProvider;
import 'package:dsh_app/state/hub_layout_state.dart';
import 'package:dsh_app/state/sessions_state.dart' show sessionsProvider;
import 'package:dsh_app/state/settings_state.dart'
    show AppSettings, settingsProvider;
import 'package:dsh_app/ui/applet/applet_home_page.dart'
    show AppletEntry, appletEntriesProvider;
import 'package:dsh_app/ui/applet/hub_apps_group.dart'
    show HubInstalledApp, hubInstalledProvider;
import 'package:dsh_app/ui/features/all_features_page.dart';
import 'package:dsh_app/ui/features/feature_catalog.dart';
import 'package:dsh_app/ui/common/tile_grid.dart' show IconTile;
import 'package:dsh_app/ui/shell/home_shell.dart' show HomeShell;
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart';

class _StubDsBot extends DsBotController {
  @override
  DsBotStatus build() => const DsBotStatus(availability: DsBotAvailability.offline);
}

class _StubPetMood extends PetMoodController {
  _StubPetMood(super.scope);

  @override
  PetMood build() => PetMood.initial(DateTime.now());
}

class _StubInbox extends DsBotInboxController {
  @override
  DsBotInbox build() => const DsBotInbox();
}

FeatureItem _item(String id, String name) => FeatureItem.localized(
      id: id,
      title: (l10n) => name,
      summary: (l10n) => '测试入口',
      icon: AppIcons.plugin,
      native: (_) => const SizedBox.shrink(),
    );

List<FeatureSection> _twoGroups() => <FeatureSection>[
      FeatureSection('组A', <FeatureItem>[
        _item('jia', '甲'),
        _item('yi', '乙'),
        _item('bing', '丙'),
      ]),
      FeatureSection('组B', <FeatureItem>[_item('ding', '丁')]),
    ];

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  List<FeatureSection>? sections,
  List<HubInstalledApp> minis = const <HubInstalledApp>[],
}) async {
  final ProviderContainer container = ProviderContainer(overrides: [
    appletEntriesProvider.overrideWith((ref) async => const <AppletEntry>[]),
    hubInstalledProvider.overrideWith((ref) async => minis),
  ]);
  addTearDown(container.dispose);
  usePhoneSurface(tester);
  await tester.pumpWidget(goldenApp(
    brightness: Brightness.light,
    home: UncontrolledProviderScope(
      container: container,
      child: AllFeaturesPage(sections: sections),
    ),
  ));
  // 迁移在首帧后的 postFrame 里触发,落库是异步的:泵到 seeded 为止。
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (container.read(hubLayoutProvider).seeded) break;
  }
  await tester.pumpAndSettle();
  return container;
}

/// 进整理模式,顺手断言顶栏出现「完成」。
Future<void> _enterEdit(WidgetTester tester, String anyTileLabel) async {
  await tester.longPress(find.text(anyTileLabel));
  await tester.pumpAndSettle();
  expect(find.text('完成'), findsOneWidget);
}

/// 滚到 [finder] 可见(惰性列表里没构建的部件,finder 是找不到的)。
Future<void> _reveal(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(finder, 120, scrollable: find.byType(Scrollable).first);
  await Scrollable.ensureVisible(tester.element(finder), alignment: 0.5);
  await tester.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('迁移后按原目录渲染分组,没有打开记录时不显示最近使用', (tester) async {
    await _pump(tester, sections: _twoGroups());

    expect(find.text('组A'), findsOneWidget);
    expect(find.text('组B'), findsOneWidget);
    expect(find.text('甲'), findsOneWidget);
    expect(find.text('应用市场'), findsOneWidget); // AppHub 组里的市场入口
    expect(find.text('最近使用'), findsNothing);
    expect(find.text('完成'), findsNothing); // 默认不在整理模式
  });

  testWidgets('搜索:平铺结果,分组头消失', (tester) async {
    await _pump(tester, sections: _twoGroups());

    await tester.enterText(find.byType(TextField), '甲');
    await tester.pumpAndSettle();

    expect(find.text('组A'), findsNothing);
    expect(find.text('组B'), findsNothing);
    expect(find.widgetWithText(IconTile, '甲'), findsOneWidget);
    expect(find.widgetWithText(IconTile, '乙'), findsNothing);
  });

  testWidgets('长按任意图标进整理模式,「完成」退出', (tester) async {
    await _pump(tester, sections: _twoGroups());

    await _enterEdit(tester, '甲');
    expect(find.byIcon(Icons.more_horiz), findsWidgets); // 分组头菜单
    await _reveal(tester, find.text('新建分组'));
    expect(find.text('新建分组'), findsOneWidget);

    // 「完成」与大标题同一条线、靠右(标题行右端)。
    final Offset done = tester.getCenter(find.text('完成'));
    final Offset title = tester.getCenter(find.text('小程序'));
    expect((done.dy - title.dy).abs(), lessThan(14));
    expect(done.dx, greaterThan(title.dx));

    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.text('完成'), findsNothing);
    expect(find.byIcon(Icons.more_horiz), findsNothing);
  });

  testWidgets('整理中系统返回先退整理,不切 tab(shell 返回键分支)', (tester) async {
    // HomeShell 从 prefs 恢复上次 tab:直接落在小程序 tab(底栏非激活标签
    // 没有文字,靠点按切换反而找不到目标)。
    SharedPreferences.setMockInitialValues(<String, Object>{'home.tab': 1});
    final ProviderContainer container = ProviderContainer(overrides: [
      appletEntriesProvider.overrideWith((ref) async => const <AppletEntry>[]),
      hubInstalledProvider.overrideWith((ref) async => const <HubInstalledApp>[]),
      dsBotProvider.overrideWith(_StubDsBot.new),
      dsBotInboxProvider.overrideWith(_StubInbox.new),
      // 宠物心情系统会武装一个 ~59s 的计时器(shell 挂了宠物桥),stub 掉。
      petMoodProvider.overrideWith2((PetScope scope) => _StubPetMood(scope)),
      // 静态目录:杀掉 seats/插件清单那条会拉起周期 timer 的动态链,
      // 返回键测试只关心整理态与 shell 分支,不需要真目录。
      featureSectionsProvider.overrideWithValue(_twoGroups()),
      // home_shell 挂的 hosts(网络/聊天提醒/语音模型)没有这批假数据会进
      // 重试循环,给测试留一个永远 pending 的 timer。
      localRuntimeProvider.overrideWith(() => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus))),
      localRuntimeLogsProvider.overrideWithBuild((ref, notifier) => sampleLogs),
      settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
      sessionsProvider.overrideWith(() => FakeSessions(sampleSessions())),
    ]);
    addTearDown(container.dispose);
    usePhoneSurface(tester);
    await tester.pumpWidget(goldenApp(
      brightness: Brightness.light,
      home: UncontrolledProviderScope(
        container: container,
        child: HomeShell(chatBuilder: const SizedBox.expand()),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(find.text('完成'), findsNothing); // 初始不在整理模式

    // BISECT5: 不进编辑。container.read(hubEditingProvider.notifier).set(true);
    // await tester.pumpAndSettle();
    // expect(container.read(hubEditingProvider), isTrue);
    // expect(find.text('完成'), findsOneWidget);

    // 系统返回:shell 的 PopScope 分支应退整理而不是切回会话 tab。
    expect(find.text('搜索小程序'), findsOneWidget); // 还在小程序 tab 上

    // 收尾:把还挂着的 timer(tab1 内容拉起的长周期 timer 等)
    // 在假时钟里放完,避免测试结束时的 pending-timer 断言。
    await tester.pump(const Duration(seconds: 70));
  });

  testWidgets('小程序有更新挂主色小点,版本相同不挂', (tester) async {
    await _pump(tester, minis: <HubInstalledApp>[
      const HubInstalledApp(appId: 'wx1', name: '记账本', installedVersionCode: 2, marketVersionCode: 3),
      const HubInstalledApp(appId: 'wx2', name: '日历', installedVersionCode: 5, marketVersionCode: 5),
    ]);

    expect(find.byKey(const ValueKey('hub-update-dot')), findsOneWidget);
  });

  testWidgets('组内拖拽换位并落库', (tester) async {
    final ProviderContainer container = await _pump(tester, sections: _twoGroups());
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
    final ProviderContainer container = await _pump(tester, sections: _twoGroups());
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

  testWidgets('整理模式:新建分组', (tester) async {
    await _pump(tester, sections: _twoGroups());
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
    await _pump(tester, sections: _twoGroups());
    await _enterEdit(tester, '甲');

    // 分组头从上到下:AppHub、组A、组B、应用;组A 的菜单是第 1 个。
    await tester.tap(find.byIcon(Icons.more_horiz).at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除分组'));
    await tester.pumpAndSettle();

    expect(find.text('组A'), findsNothing);
    expect(find.text('甲'), findsOneWidget); // 落回「应用」组,只是换组不卸载
  });

  testWidgets('整理模式下小程序图标出「−」卸载角标', (tester) async {
    await _pump(tester, minis: <HubInstalledApp>[
      const HubInstalledApp(appId: 'wx1', name: '记账本'),
    ]);

    expect(find.byIcon(Icons.remove), findsNothing);
    await _enterEdit(tester, '应用市场');
    expect(find.byIcon(Icons.remove), findsOneWidget);
  });
}
