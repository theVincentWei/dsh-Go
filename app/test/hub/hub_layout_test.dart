// 「小程序」桌面布局的状态测试:首装迁移、未安置回退、拖拽落表、分组增删
// 改序、最近使用、持久化(prefs mock)。桌面页的渲染与手势在 app_desktop_test。

import 'package:dsh_app/state/hub_layout_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 种子分组:星河 1 个、AppHub 2 个、自动化 2 个,默认组收尾。
List<({String title, List<String> keys})> get seedGroups => <({String title, List<String> keys})>[
  (title: '星河', keys: <String>['applet:balance']),
  (title: 'AppHub', keys: <String>['mini:wx1', 'feature:apphub-market']),
  (title: '自动化', keys: <String>['feature:schedules', 'feature:plugins']),
];

Future<void> seed(ProviderContainer container) async {
  await container
      .read(hubLayoutProvider.notifier)
      .ensureSeeded(seedGroups, defaultGroupName: '应用');
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('迁移:原静态目录原样成组,默认组收尾且不可删', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await seed(container);

    final HubLayout layout = container.read(hubLayoutProvider);
    expect(layout.loaded, isTrue);
    expect(layout.seeded, isTrue);
    expect(layout.sections.map((s) => s.id).toList(),
        <String>['recent', 'seed:星河', 'seed:AppHub', 'seed:自动化', 'default']);
    expect(layout.items['applet:balance']!.sectionId, 'seed:星河');
    expect(layout.items['mini:wx1']!.order, 0);
    expect(layout.items['feature:apphub-market']!.order, 1);
    expect(layout.items['feature:plugins']!.sectionId, 'seed:自动化');
    expect(layout.section(hubDefaultSectionId)!.locked, isTrue);
    expect(layout.smartSection().smart, isTrue);
  });

  test('迁移幂等:种过之后再来一把种子不动布局(保住用户改过的样子)', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await seed(container);
    container.read(hubLayoutProvider.notifier).renameGroup('seed:自动化', '工作流');

    await container.read(hubLayoutProvider.notifier).ensureSeeded(
      <({String title, List<String> keys})>[
        (title: '另一套', keys: <String>['feature:x']),
      ],
      defaultGroupName: '应用',
    );

    final HubLayout layout = container.read(hubLayoutProvider);
    expect(layout.sections.map((s) => s.name), contains('工作流'));
    expect(layout.sections.map((s) => s.id), isNot(contains('seed:另一套')));
    expect(layout.items.containsKey('feature:x'), isFalse);
  });

  test('解析:未安置的应用按目录顺序垫在默认组尾部,显式安置的在前', () {
    final HubLayout layout = HubLayout(
      loaded: true,
      seeded: true,
      sections: const <HubSectionData>[
        HubSectionData(id: hubRecentSectionId, name: '', smart: true),
        HubSectionData(id: 'seed:A', name: 'A'),
        HubSectionData(id: hubDefaultSectionId, name: '应用', locked: true),
      ],
      items: const <String, HubPlacement>{'b': HubPlacement('seed:A', 0)},
    );

    final List<HubResolvedSection> resolved =
        resolveHubLayout(layout, <String>['c', 'a', 'b']);
    expect(resolved[0].keys, isEmpty); // 智能组的 keys 恒空,内容归 recentsFor
    expect(resolved[1].keys, <String>['b']);
    expect(resolved[2].keys, <String>['c', 'a']);
  });

  test('解析:placement 指向已删分组时当未安置处理', () {
    final HubLayout layout = HubLayout(
      loaded: true,
      seeded: true,
      sections: const <HubSectionData>[
        HubSectionData(id: hubRecentSectionId, name: '', smart: true),
        HubSectionData(id: hubDefaultSectionId, name: '应用', locked: true),
      ],
      items: const <String, HubPlacement>{'b': HubPlacement('seed:没了', 0)},
    );
    final List<HubResolvedSection> resolved =
        resolveHubLayout(layout, <String>['a', 'b']);
    // b 曾被显式安置过(分组被删才回默认组):仍算「安置过」,排在未安置的 a 前。
    expect(resolved[1].keys, <String>['b', 'a']);
  });

  test('拖拽落表:组内换位只物化目标组,别的组不被动', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await seed(container);
    container.read(hubLayoutProvider.notifier).assignSections(<({String id, List<String> keys})>[
      (id: 'seed:自动化', keys: <String>['feature:plugins', 'feature:schedules']),
    ]);

    final HubLayout layout = container.read(hubLayoutProvider);
    expect(layout.items['feature:plugins']!.order, 0);
    expect(layout.items['feature:schedules']!.order, 1);
    expect(layout.items['applet:balance']!.sectionId, 'seed:星河');
    final List<HubResolvedSection> resolved =
        resolveHubLayout(layout, <String>['applet:balance', 'mini:wx1', 'feature:apphub-market', 'feature:plugins', 'feature:schedules']);
    final int at = resolved.indexWhere((r) => r.section.id == 'seed:自动化');
    expect(resolved[at].keys, <String>['feature:plugins', 'feature:schedules']);
  });

  test('拖拽落表:跨组移动', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await seed(container);
    container.read(hubLayoutProvider.notifier).assignSections(<({String id, List<String> keys})>[
      (id: 'seed:星河', keys: <String>['applet:balance', 'feature:schedules']),
      (id: 'seed:AppHub', keys: <String>['mini:wx1', 'feature:apphub-market']),
      (id: 'seed:自动化', keys: <String>['feature:plugins']),
    ]);

    final HubLayout layout = container.read(hubLayoutProvider);
    expect(layout.items['feature:schedules']!.sectionId, 'seed:星河');
    expect(layout.items['feature:schedules']!.order, 1);
    expect(layout.items['feature:plugins']!.sectionId, 'seed:自动化');
  });

  test('删分组:组内应用退回默认组(未安置),分组消失', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await seed(container);
    container.read(hubLayoutProvider.notifier).deleteGroup('seed:自动化');

    final HubLayout layout = container.read(hubLayoutProvider);
    expect(layout.sections.map((s) => s.id), isNot(contains('seed:自动化')));
    expect(layout.items.containsKey('feature:schedules'), isFalse);
    final List<HubResolvedSection> resolved = resolveHubLayout(
        layout, <String>['applet:balance', 'feature:schedules', 'feature:plugins']);
    final int at = resolved.indexWhere((r) => r.section.id == hubDefaultSectionId);
    expect(resolved[at].keys, <String>['feature:schedules', 'feature:plugins']);
  });

  test('删分组:智能组与默认组删不掉', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await seed(container);
    final HubLayoutController notifier = container.read(hubLayoutProvider.notifier);
    notifier.deleteGroup(hubRecentSectionId);
    notifier.deleteGroup(hubDefaultSectionId);
    final HubLayout layout = container.read(hubLayoutProvider);
    expect(layout.section(hubRecentSectionId), isNotNull);
    expect(layout.section(hubDefaultSectionId), isNotNull);
  });

  test('新装自动安置:未安置的 mini 垫进市场入口所在组尾,已安置的不动', () async {
    // 复刻真机时序:种子落地时市场里还没有小程序(AppHub 组只有市场入口),
    // 之后装了两个,依次垫在市场入口后面。
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(hubLayoutProvider.notifier).ensureSeeded(
      <({String title, List<String> keys})>[
        (title: 'AppHub', keys: <String>['feature:apphub-market']),
      ],
      defaultGroupName: '应用',
    );
    final HubLayoutController notifier = container.read(hubLayoutProvider.notifier);
    notifier.absorbUnplaced(<String>['mini:wx1', 'mini:wx2'],
        anchorKey: 'feature:apphub-market');

    final HubLayout layout = container.read(hubLayoutProvider);
    expect(layout.items['mini:wx1']!.sectionId, 'seed:AppHub');
    expect(layout.items['mini:wx1']!.order, 1); // 市场入口(order 0)之后
    expect(layout.items['mini:wx2']!.sectionId, 'seed:AppHub');
    expect(layout.items['mini:wx2']!.order, 2);

    // 解析时落在 AppHub 组里,排在市场入口后面;默认组不收它们。
    final List<HubResolvedSection> resolved = resolveHubLayout(
        layout, <String>['mini:wx2', 'mini:wx1', 'feature:apphub-market']);
    final int at =
        resolved.indexWhere((HubResolvedSection r) => r.section.id == 'seed:AppHub');
    expect(resolved[at].keys,
        <String>['feature:apphub-market', 'mini:wx1', 'mini:wx2']);
    expect(resolved.last.keys, isEmpty);

    // 再来一把:没有新 key 就不写存储(state 实例不动,_persist 都不进)。
    final HubLayout before = container.read(hubLayoutProvider);
    notifier.absorbUnplaced(<String>['mini:wx1'],
        anchorKey: 'feature:apphub-market');
    expect(container.read(hubLayoutProvider), same(before));
  });

  test('新装自动安置:锚点被拖进默认组就跟去默认组', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await seed(container);
    final HubLayoutController notifier = container.read(hubLayoutProvider.notifier);
    notifier.assignSections(<({String id, List<String> keys})>[
      (id: hubDefaultSectionId,
       keys: <String>['feature:apphub-market', 'feature:schedules']),
    ]);
    notifier.absorbUnplaced(<String>['mini:wx9'], anchorKey: 'feature:apphub-market');
    expect(container.read(hubLayoutProvider).items['mini:wx9']!.sectionId,
        hubDefaultSectionId);
    expect(container.read(hubLayoutProvider).items['mini:wx9']!.order, 2);
  });

  test('新装自动安置:锚点无 placement(所在分组被删)时不接', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await seed(container);
    final HubLayoutController notifier = container.read(hubLayoutProvider.notifier);
    // 删掉市场入口所在的 AppHub 组:入口退回默认组(placement 被抹),锚点没了。
    notifier.deleteGroup('seed:AppHub');
    expect(container.read(hubLayoutProvider).items.containsKey('feature:apphub-market'),
        isFalse);
    notifier.absorbUnplaced(<String>['mini:wx8'], anchorKey: 'feature:apphub-market');
    expect(container.read(hubLayoutProvider).items.containsKey('mini:wx8'), isFalse);
  });

  test('分组排序与改名:非智能组间换位,改名不改 id', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await seed(container);
    final HubLayoutController notifier = container.read(hubLayoutProvider.notifier);

    notifier.moveGroup('seed:AppHub', -1);
    expect(container.read(hubLayoutProvider).sections.map((s) => s.id).toList(),
        <String>['recent', 'seed:AppHub', 'seed:星河', 'seed:自动化', 'default']);

    notifier.renameGroup('seed:AppHub', '小程序市场');
    final HubLayout layout = container.read(hubLayoutProvider);
    expect(layout.section('seed:AppHub')!.name, '小程序市场');
    expect(layout.items['mini:wx1']!.sectionId, 'seed:AppHub');
  });

  test('新建分组排在默认组前', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await seed(container);
    container.read(hubLayoutProvider.notifier).createGroup(' 收藏 ');
    final HubLayout layout = container.read(hubLayoutProvider);
    expect(layout.sections.map((s) => s.id).toList().last, 'default');
    expect(layout.sections.map((s) => s.name).toList().reversed.toList()[1], '收藏');
  });

  test('最近使用:最新在前、去重、封顶;显示时按目录过滤', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await seed(container);
    final HubLayoutController notifier = container.read(hubLayoutProvider.notifier);
    notifier.touch('feature:schedules');
    notifier.touch('applet:balance');
    notifier.touch('feature:schedules');
    expect(container.read(hubLayoutProvider).recent,
        <String>['feature:schedules', 'applet:balance']);

    for (var i = 0; i < kHubRecentCap + 5; i++) {
      notifier.touch('mini:x$i');
    }
    expect(container.read(hubLayoutProvider).recent.length, kHubRecentCap);
    expect(container.read(hubLayoutProvider).recent.first, 'mini:x${kHubRecentCap + 4}');

    // schedules 早被挤出 30 条封顶了,再摸一次回 MRU 头部;过滤掉目录外的 key。
    notifier.touch('feature:schedules');
    final List<String> shown = container
        .read(hubLayoutProvider)
        .recentsFor(<String>{'feature:schedules', 'mini:x0'});
    expect(shown, <String>['feature:schedules']);
  });

  test('最近使用可隐藏', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await seed(container);
    final HubLayoutController notifier = container.read(hubLayoutProvider.notifier);
    notifier.setRecentsHidden(true);
    expect(container.read(hubLayoutProvider).smartSection().hidden, isTrue);
    notifier.setRecentsHidden(false);
    expect(container.read(hubLayoutProvider).smartSection().hidden, isFalse);
  });

  test('未迁移前一切改动都是空操作(工厂视图不写存储)', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    // 等 prefs 异步 load 落地(不能拿 ensureSeeded 当屏障,它真会种布局)。
    HubLayout loaded = container.read(hubLayoutProvider);
    for (var i = 0; i < 50 && !loaded.loaded; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      loaded = container.read(hubLayoutProvider);
    }
    expect(loaded.loaded, isTrue);

    final HubLayoutController notifier = container.read(hubLayoutProvider.notifier);
    notifier.createGroup('收藏');
    notifier.renameGroup(hubDefaultSectionId, '改不动');
    notifier.deleteGroup(hubDefaultSectionId);
    notifier.assignSections(const [(
      id: hubDefaultSectionId,
      keys: <String>['feature:x'],
    )]);
    notifier.moveGroup(hubDefaultSectionId, -1);
    notifier.setRecentsHidden(true);

    final HubLayout layout = container.read(hubLayoutProvider);
    expect(layout.seeded, isFalse);
    expect(layout.sections, isEmpty);
    expect(layout.items, isEmpty);

    final String? raw =
        (await SharedPreferences.getInstance()).getString(kHubLayoutPrefKey);
    expect(raw, isNull);
  });

  test('持久化:新容器从 prefs 恢复已迁移布局(最近使用也回来)', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await seed(container);
    final HubLayoutController notifier = container.read(hubLayoutProvider.notifier);
    notifier.touch('feature:schedules');
    notifier.renameGroup('seed:AppHub', '小程序市场');

    final String? raw =
        (await SharedPreferences.getInstance()).getString(kHubLayoutPrefKey);
    expect(raw, isNotNull);

    final container2 = ProviderContainer();
    addTearDown(container2.dispose);
    HubLayout restored = container2.read(hubLayoutProvider);
    for (var i = 0; i < 50 && !restored.loaded; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      restored = container2.read(hubLayoutProvider);
    }
    expect(restored.seeded, isTrue);
    expect(restored.sections.map((s) => s.id).toList(),
        <String>['recent', 'seed:星河', 'seed:AppHub', 'seed:自动化', 'default']);
    expect(restored.section('seed:AppHub')!.name, '小程序市场');
    expect(restored.recent, <String>['feature:schedules']);
    expect(restored.items['feature:plugins']!.sectionId, 'seed:自动化');
  });
}
