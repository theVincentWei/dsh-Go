// 「小程序」桌面页的宿主侧 widget 测试:目录翻译(buildHubCatalog /
// needsSession 置灰)、absorb 编排(新装小程序垫进 AppHub 组,经注册者的
// upsertTiles 锚点落位)、壳相关的用例(长按进整理 + 「完成」与大标题对齐、
// 整理中系统返回先退整理)、注册者迁移回归(更新红点、「−」卸载角标、
// ds-bot 未读红圈、AppHub 组头未读按内容匹配)。纯引擎行为(分组渲染/
// 搜索/拖拽/新建删除分组/角标渲染/置灰/卸载双条件)在
// packages/hub_desktop/test。字体由 flutter_test_config 统一加载;动画
// 关闭(goldenApp)时摇摆不转,可 pumpAndSettle。

import 'dart:convert';

import 'package:dsh_app/l10n/l10n.dart' show L10n;
import 'package:dsh_app/runtime/runtime_state.dart'
    show LocalRuntimeState, localRuntimeLogsProvider, localRuntimeProvider;
import 'package:dsh_app/pets/pet_mood.dart' show PetMood, PetScope;
import 'package:dsh_app/pets/pet_signals.dart'
    show PetMoodController, petMoodProvider;
import 'package:dsh_app/state/apphub_notices_state.dart'
    show AppHubNotices, AppHubNoticesController, MiniAppNotice, appHubNoticesProvider;
import 'package:dsh_app/state/bots_state.dart'
    show DsBotAvailability, DsBotController, DsBotInbox, DsBotInboxController, DsBotStatus, dsBotInboxProvider, dsBotProvider;
import 'package:dsh_app/state/hub_desktop_sync.dart'
    show hubDesktopSyncProvider, hubNewMinisProvider;
import 'package:dsh_app/state/hub_layout_state.dart';
import 'package:dsh_app/state/sessions_state.dart' show currentSessionProvider, sessionsProvider;
import 'package:dsh_app/state/settings_state.dart'
    show AppSettings, settingsProvider;
import 'package:dsh_app/ui/applet/hub_apps_group.dart'
    show HubInstalledApp, HubInstalledController, hubInstalledProvider;
import 'package:dsh_app/ui/features/all_features_page.dart';
import 'package:dsh_app/ui/features/feature_catalog.dart';
import 'package:dsh_app/ui/hub/hub_apps_catalog.dart' show HubCatalog, buildHubCatalog;
import 'package:dsh_app/ui/shell/home_shell.dart' show HomeShell;
import 'package:dsh_app/ui/shell/root_navigator_key.dart' show rootNavigatorKey;
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/theme/theme.dart' show buildLightTheme;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart'
    show GlobalMaterialLocalizations;
import 'package:flutter_riverpod/flutter_riverpod.dart'
    show ProviderContainer, UncontrolledProviderScope;
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:hub_desktop/hub_desktop.dart' show HubBadge, IconTile, hubBadgesProvider;
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart';
import '../support/test_fonts.dart' show withTestFonts;

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

/// 固定已装清单(AsyncNotifier 覆写;build 直接回真值,不走快照/抓取)。
class _FixedInstalled extends HubInstalledController {
  _FixedInstalled(this.apps);

  final List<HubInstalledApp> apps;

  @override
  Future<List<HubInstalledApp>> build() async => apps;
}

/// 固定状态的小程序通知收件箱(桌面计数角标的注册者迁移回归用)。
class _StubNoticesController extends AppHubNoticesController {
  _StubNoticesController(this._state);
  final AppHubNotices _state;
  @override
  AppHubNotices build() => _state;
}

/// 带未读的 ds-bot 收件箱(注册者迁移回归:红圈随源变化挂上)。
class _UnreadInbox extends DsBotInboxController {
  @override
  DsBotInbox build() => const DsBotInbox(unread: <String, int>{'bot-1': 3});
}

/// 带未读的 AppHub 通知(注册者迁移回归:组头胶丸按内容匹配)。
class _UnreadNotices extends AppHubNoticesController {
  @override
  AppHubNotices build() => const AppHubNotices(unread: 3);
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
  List<Override> overrides = const <Override>[],
}) async {
  final ProviderContainer container = ProviderContainer(overrides: [
    hubInstalledProvider.overrideWith(() => _FixedInstalled(minis)),
    // 假目录同时给 provider 一份:注册者(sync)读的是 provider,页面收到
    // 的 [sections] 只是渲染侧参数——两边必须同源,目录才一致。
    if (sections != null) featureSectionsProvider.overrideWithValue(sections),
    ...overrides,
  ]);
  addTearDown(container.dispose);
  usePhoneSurface(tester);
  // 激活 keep-alive 注册者(生产在 DshApp 根装配 watch 一次):目录、角标
  // 与卸载钩子都经它整批同步进引擎注册表。
  container.read(hubDesktopSyncProvider);
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
      hubInstalledProvider.overrideWith(() => _FixedInstalled(const <HubInstalledApp>[])),
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
    // 激活 keep-alive 注册者(目录喂进引擎注册表,与生产同一条路)。
    container.read(hubDesktopSyncProvider);
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

  testWidgets('小程序有更新挂名字点(iOS 式),瓷贴角不再有 dot;新装未打开也亮', (tester) async {
    await _pump(tester, minis: <HubInstalledApp>[
      const HubInstalledApp(appId: 'wx1', name: '记账本', installedVersionCode: 2, marketVersionCode: 3),
      const HubInstalledApp(appId: 'wx2', name: '日历', installedVersionCode: 5, marketVersionCode: 5),
    ]);

    // 冷启动空 seen:wx1 亮「更新」、wx2 亮「新装未打开」——同名点同槽位。
    expect(find.byKey(const ValueKey('hub-label-dot')), findsNWidgets(2));
    expect(find.byKey(const ValueKey('hub-update-dot')), findsNothing); // 瓷贴角 dot 档退役
  });

  testWidgets('新装未打开亮名字点,markOpened 熄灭(跨重启保持)', (tester) async {
    // 冷启动 + 空 seen:第一次清单里的 mini 都算「首次出现」→ 亮名字点。
    final ProviderContainer container = await _pump(tester, minis: <HubInstalledApp>[
      const HubInstalledApp(appId: 'wx1', name: '记账本'),
    ]);
    expect(find.byKey(const ValueKey('hub-label-dot')), findsOneWidget);

    // 打开一次(iOS:打开即熄):onOpen 分发里写的就是 markOpened。
    container.read(hubNewMinisProvider.notifier).markOpened('mini:wx1');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('hub-label-dot')), findsNothing);

    // 重启保持:prefs 里 hub.new-minis 已无 wx1、seen 有它——新容器(重启)
    // 后不亮;另一颗装了但从未打开的 wx2 保持亮。
    final ProviderContainer reborn = ProviderContainer(overrides: <Override>[
      hubInstalledProvider.overrideWith(() => _FixedInstalled(<HubInstalledApp>[
            const HubInstalledApp(appId: 'wx1', name: '记账本'),
            const HubInstalledApp(appId: 'wx2', name: '新装的', installedVersionCode: 1, marketVersionCode: 2),
          ])),
      featureSectionsProvider.overrideWithValue(_twoGroups()),
    ]);
    addTearDown(reborn.dispose);
    reborn.read(hubDesktopSyncProvider);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: reborn,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        navigatorKey: rootNavigatorKey,
        locale: const Locale('zh', 'CN'),
        supportedLocales: const <Locale>[Locale('zh', 'CN')],
        localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
          L10n.delegate,
          ...GlobalMaterialLocalizations.delegates,
        ],
        theme: withTestFonts(buildLightTheme()),
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: AllFeaturesPage(sections: _twoGroups()),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('hub-label-dot')), findsOneWidget); // 只有 wx2
  });

  testWidgets('重启不误判:seen 里的老应用不因冷启动清单而亮', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'hub.seen-minis': <String>['mini:wx1'],
    });
    await _pump(tester, minis: <HubInstalledApp>[
      const HubInstalledApp(appId: 'wx1', name: '老朋友'),
    ]);
    expect(find.byKey(const ValueKey('hub-label-dot')), findsNothing);
  });

  testWidgets('注册者迁移:通知未读挂瓷贴角计数,更新走名字点——两指示器并存', (tester) async {
    // wx1 有 2 条未读(瓷贴角计数角标)且市场有更新 → 角上计数 + 名字点并存
    // (iOS 同款);wx2 无未读、有更新 + 新装未打开 → 瓷贴角清掉(不再有红点
    // 兜底)、只有名字点;wx2 那条已读通知不进计数(未读收件箱语义)。
    const AppHubNotices stubState = AppHubNotices(
      notices: <MiniAppNotice>[
        MiniAppNotice(id: 1, appId: 'wx1', title: 'a'),
        MiniAppNotice(id: 2, appId: 'wx1', title: 'b'),
        MiniAppNotice(id: 3, appId: 'wx2', title: 'c', read: true),
      ],
      unread: 2,
    );
    final ProviderContainer container = await _pump(
      tester,
      minis: <HubInstalledApp>[
        const HubInstalledApp(appId: 'wx1', name: '记账本', installedVersionCode: 2, marketVersionCode: 3),
        const HubInstalledApp(appId: 'wx2', name: '日历', installedVersionCode: 5, marketVersionCode: 6),
      ],
      overrides: <Override>[
        appHubNoticesProvider.overrideWith(() => _StubNoticesController(stubState)),
      ],
    );

    // 引擎角标注册表(喂送层的真实输出,避开像素歧义):
    // wx1 未读计数;wx2 无未读清掉——更新不再回瓷贴角(用户裁决)。
    final HubBadge? wx1Badge = container.read(hubBadgesProvider)['mini:wx1'];
    expect(wx1Badge?.count, 2);
    expect(wx1Badge?.dot, isFalse);
    final HubBadge? wx2Badge = container.read(hubBadgesProvider)['mini:wx2'];
    expect(wx2Badge, isNull);
    // 名字点(更新/新装未打开):两颗都亮;瓷贴角无 dot 渲染。
    expect(find.byKey(const ValueKey('hub-label-dot')), findsNWidgets(2));
    expect(find.byKey(const ValueKey('hub-update-dot')), findsNothing);
  });

  testWidgets('整理模式下小程序图标出「−」卸载角标(注册者注册了 mini: 钩子)', (tester) async {
    await _pump(tester, minis: <HubInstalledApp>[
      const HubInstalledApp(appId: 'wx1', name: '记账本'),
    ]);

    expect(find.byIcon(Icons.remove), findsNothing);
    await _enterEdit(tester, '应用市场');
    expect(find.byIcon(Icons.remove), findsOneWidget);
  });

  testWidgets('注册者迁移:ds-bot 未读按 key 挂红圈', (tester) async {
    // 目录里给一颗 ds-bot feature(feature:ds-bot 是注册者写死的 key)。
    final List<FeatureSection> sections = <FeatureSection>[
      FeatureSection('组A', <FeatureItem>[_item('ds-bot', '助手'), _item('jia', '甲')]),
      FeatureSection('组B', <FeatureItem>[_item('ding', '丁')]),
    ];
    await _pump(
      tester,
      sections: sections,
      overrides: <Override>[dsBotInboxProvider.overrideWith(_UnreadInbox.new)],
    );

    expect(find.text('助手'), findsOneWidget);
    expect(find.text('3'), findsOneWidget); // 红圈计数来自 dsBotInboxProvider.total
  });

  testWidgets('注册者迁移:AppHub 组头未读按内容匹配,改名后仍亮', (tester) async {
    // 预置布局:AppHub 组已改名为「常用」,组里只有市场入口(没有 mini,
    // 也没有「AppHub」字样)——证明口径是内容(mini:/市场入口)而非组名。
    SharedPreferences.setMockInitialValues(<String, Object>{
      kHubLayoutPrefKey: jsonEncode(<String, Object?>{
        'v': 1,
        'sections': <Object?>[
          <String, Object?>{'id': hubRecentSectionId, 'name': '', 'smart': true},
          <String, Object?>{'id': 'seed:AppHub', 'name': '常用'},
          <String, Object?>{'id': hubDefaultSectionId, 'name': '应用', 'locked': true},
        ],
        'items': <String, Object?>{
          'feature:apphub-market': <String, Object?>{'s': 'seed:AppHub', 'o': 0},
        },
        'recent': <Object?>[],
      }),
    });
    await _pump(
      tester,
      sections: _twoGroups(),
      overrides: <Override>[appHubNoticesProvider.overrideWith(_UnreadNotices.new)],
    );

    expect(find.text('常用'), findsOneWidget); // 组名已不含 AppHub
    // 组头胶丸仍亮(组里装着市场入口)。注意:未读「3」在桌面上现在有
    // 两处合法显示——页头「服务通知」钥匙的 UnreadDot(task-12 收入口进
    // 宿主页头时新增)和这里的组头胶丸(HubUnreadBadge,引擎内部件,未
    // 进公开桶),全局 find.text('3') 不再唯一,按类型收窄到组头这一颗。
    final Finder groupBadge = find.byWidgetPredicate(
      (Widget w) => w.runtimeType.toString() == 'HubUnreadBadge',
    );
    expect(groupBadge, findsOneWidget);
    expect(find.descendant(of: groupBadge, matching: find.text('3')), findsOneWidget);
  });

  testWidgets('桌面「−」点击经根 navigator 弹共用卸载弹窗;取消不动', (tester) async {
    // 引擎「−」直接调钩子(无自带确认框);钩子经根 navigator 打开桌面与
    // 市场详情页共用的弹窗(整包文案 + purge 勾选)。这里走完整链路到弹窗,
    // 取消后桌面不动;确认后的整包编排由 task-11 的编排层测试覆盖。
    final ProviderContainer container = ProviderContainer(overrides: <Override>[
      hubInstalledProvider.overrideWith(() => _FixedInstalled(<HubInstalledApp>[
            const HubInstalledApp(appId: 'wx1', name: '记账本'),
          ])),
      featureSectionsProvider.overrideWithValue(_twoGroups()),
    ]);
    addTearDown(container.dispose);
    usePhoneSurface(tester);
    container.read(hubDesktopSyncProvider);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        navigatorKey: rootNavigatorKey,
        locale: const Locale('zh', 'CN'),
        supportedLocales: const <Locale>[Locale('zh', 'CN')],
        localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
          L10n.delegate,
          ...GlobalMaterialLocalizations.delegates,
        ],
        // 壳(AppPage/AppBackdrop)读宿主主题 extension(DshSurfaces 等),
        // 必须用真主题构建器,裸 ThemeData 会在壳上炸。
        theme: withTestFonts(buildLightTheme()),
        // 冻结整理模式的摇摆钟摆(与 goldenApp 同款),pumpAndSettle 才能
        // 收敛。
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: AllFeaturesPage(sections: _twoGroups()),
      ),
    ));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (container.read(hubLayoutProvider).seeded) break;
    }
    await tester.pumpAndSettle();

    // 进整理模式,小程序格挂「−」。
    await tester.longPress(find.text('应用市场'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.remove));
    await tester.pumpAndSettle();

    // 共用弹窗经根 navigator 出现:整包文案 + purge 勾选(与详情页同一颗)。
    expect(find.text('卸载 记账本'), findsOneWidget);
    expect(find.byType(CheckboxListTile), findsOneWidget);

    // 取消:弹窗关闭,桌面不动。
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('卸载 记账本'), findsNothing);
    expect(find.text('记账本'), findsOneWidget);
  });
}
