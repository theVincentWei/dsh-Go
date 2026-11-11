// 「小程序」桌面页的宿主侧 widget 测试:目录翻译(buildHubCatalog /
// needsSession 置灰)、absorb 编排(新装小程序垫进 AppHub 组)、壳相关的
// 用例(长按进整理 + 「完成」与大标题对齐、整理中系统返回先退整理)、
// 小程序更新红点与「−」卸载角标的端到端。纯引擎行为(分组渲染/搜索/拖拽
// /新建删除分组/角标渲染/置灰)在 packages/hub_desktop/test/desktop_test。
// 字体由 flutter_test_config 统一加载;动画关闭(goldenApp)时摇摆不转,
// 可 pumpAndSettle。

import 'dart:convert';

import 'package:dsh_app/runtime/runtime_state.dart'
    show LocalRuntimeState, localRuntimeLogsProvider, localRuntimeProvider;
import 'package:dsh_app/pets/pet_mood.dart' show PetMood, PetScope;
import 'package:dsh_app/pets/pet_signals.dart'
    show PetMoodController, petMoodProvider;
import 'package:dsh_app/state/bots_state.dart'
    show DsBotAvailability, DsBotController, DsBotInbox, DsBotInboxController, DsBotStatus, dsBotInboxProvider, dsBotProvider;
import 'package:dsh_app/state/hub_layout_state.dart';
import 'package:dsh_app/state/sessions_state.dart' show currentSessionProvider, sessionsProvider;
import 'package:dsh_app/state/settings_state.dart'
    show AppSettings, settingsProvider;
import 'package:dsh_app/ui/applet/hub_apps_group.dart'
    show HubInstalledApp, hubInstalledProvider;
import 'package:dsh_app/ui/features/all_features_page.dart';
import 'package:dsh_app/ui/features/feature_catalog.dart';
import 'package:dsh_app/ui/hub/hub_apps_catalog.dart' show HubCatalog, buildHubCatalog;
import 'package:dsh_app/ui/shell/home_shell.dart' show HomeShell;
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hub_desktop/hub_desktop.dart' show IconTile;
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

  testWidgets('新装小程序自动垫进 AppHub 组,不再沉到默认组', (tester) async {
    // 预置一份「迁移时市场为空」的旧布局:AppHub 组只有市场入口,没有 mini
    // (真机上装过小程序之后才升级到本版的布局长这样)。
    SharedPreferences.setMockInitialValues(<String, Object>{
      kHubLayoutPrefKey: jsonEncode(<String, Object?>{
        'v': 1,
        'sections': <Object?>[
          <String, Object?>{'id': hubRecentSectionId, 'name': '', 'smart': true},
          <String, Object?>{'id': 'seed:AppHub', 'name': 'AppHub'},
          <String, Object?>{'id': hubDefaultSectionId, 'name': '应用', 'locked': true},
        ],
        'items': <String, Object?>{
          'feature:apphub-market': <String, Object?>{'s': 'seed:AppHub', 'o': 0},
          'feature:jia': <String, Object?>{'s': hubDefaultSectionId, 'o': 0},
        },
        'recent': <Object?>[],
      }),
    });

    final ProviderContainer container = await _pump(
      tester,
      sections: _twoGroups(),
      minis: <HubInstalledApp>[
        const HubInstalledApp(appId: 'wx1', name: '新装小程序'),
      ],
    );

    // 布局层面:小程序被垫进市场入口所在分组,排市场入口后面;用户显式
    // 安置过的默认组条目不动。
    final HubLayout layout = container.read(hubLayoutProvider);
    expect(layout.items['mini:wx1']!.sectionId, 'seed:AppHub');
    expect(layout.items['mini:wx1']!.order, 1);
    expect(layout.items['feature:jia']!.sectionId, hubDefaultSectionId);

    // 渲染层面:图标出现在 AppHub 组、市场入口同一排的右一位(一行 4 列,
    // order 1 就在市场入口旁边;惰性列表,滚出来再量)。
    await _reveal(tester, find.text('新装小程序'));
    await _reveal(tester, find.text('应用市场'));
    final Offset market = tester.getTopLeft(find.text('应用市场'));
    final Offset mini = tester.getTopLeft(find.text('新装小程序'));
    expect(mini.dy, market.dy); // 同一排
    expect(mini.dx, greaterThan(market.dx)); // 市场入口右边一位
    expect(tester.getTopLeft(find.text('AppHub')).dy, lessThan(mini.dy));
  });

  test('目录:文件(免会话主机目录版)/终端以原生应用身份进桌面,种子组「本对话」排最前', () {
    final HubCatalog catalog = buildHubCatalog(
      minis: const <HubInstalledApp>[],
      sections: _twoGroups(),
      settled: true,
    );

    expect(
      catalog.apps.map((app) => app.key),
      containsAll(<String>['feature:host-files', 'feature:terminal']),
    );
    // 同一枚应用不重复进目录(同名 feature 组里没有它们,key 也不撞)。
    expect(catalog.apps.map((app) => app.key).toSet().length, catalog.apps.length);
    expect(catalog.seedGroups.first.title, '本对话');
    expect(catalog.seedGroups.first.keys, <String>['feature:host-files', 'feature:terminal']);
  });

  testWidgets('文件免会话可点,终端仍要当前对话', (tester) async {
    final ProviderContainer container = await _pump(tester, sections: _twoGroups());

    expect(find.text('本对话'), findsOneWidget);
    expect(find.widgetWithText(IconTile, '文件'), findsOneWidget);
    expect(find.widgetWithText(IconTile, '终端'), findsOneWidget);

    // 没打开对话:文件已是免会话的主机目录浏览,不置灰;终端仍 needsSession。
    IconTile tile(String label) => tester.widget<IconTile>(find.widgetWithText(IconTile, label));
    expect(tile('文件').enabled, isTrue);
    expect(tile('终端').enabled, isFalse);

    // 选了对话后终端也能点。
    container.read(currentSessionProvider.notifier).select('s1');
    await tester.pumpAndSettle();
    expect(tile('终端').enabled, isTrue);
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

  testWidgets('整理模式下小程序图标出「−」卸载角标', (tester) async {
    await _pump(tester, minis: <HubInstalledApp>[
      const HubInstalledApp(appId: 'wx1', name: '记账本'),
    ]);

    expect(find.byIcon(Icons.remove), findsNothing);
    await _enterEdit(tester, '应用市场');
    expect(find.byIcon(Icons.remove), findsOneWidget);
  });
}
