// 桌面引擎接口三件套的控制器测试:目录 upsert(幂等 / 锚点落位 / 无锚点
// 默认组兜底)、removeTile(槽位保留、重装原位恢复、顺手清角标)、卸载
// 钩子(前缀命中 / 最长前缀优先)、角标 store 独立于目录(先 set 后
// upsert 的 key 也在)。渲染与手势在 desktop_test。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hub_desktop/hub_desktop.dart';
import 'package:shared_preferences/shared_preferences.dart';

HubTile _tile(String key, String name, {bool uninstallable = false}) => HubTile(
      key: key,
      name: name,
      icon: const HubIcon.widget(Icon(Icons.circle, size: 20)),
      uninstallable: uninstallable,
    );

/// 种子:AppHub 组里只有市场入口,默认组收尾。
Future<void> _seed(ProviderContainer container) async {
  await container.read(hubLayoutProvider.notifier).ensureSeeded(
        const <({String title, List<String> keys})>[
          (title: 'AppHub', keys: <String>['feature:apphub-market']),
        ],
        defaultGroupName: '应用',
      );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('upsert 幂等:重推同一批目录,注册表序不变、布局不重写', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await _seed(container);
    final HubDesktopController hub = container.read(hubDesktopControllerProvider);

    final List<HubTile> catalog = <HubTile>[
      _tile('feature:apphub-market', '应用市场'),
      _tile('feature:files', '文件'),
    ];
    hub.upsertTiles(catalog, anchorKey: 'feature:apphub-market');
    final Map<String, HubTile> first = container.read(hubTilesProvider);
    final HubLayout layoutAfterFirst = container.read(hubLayoutProvider);

    // 重推(同 key 新实例,内容一致):注册表插序不动,items 不再新增。
    hub.upsertTiles(catalog.reversed.map((HubTile t) => _tile(t.key, t.name)),
        anchorKey: 'feature:apphub-market');
    expect(container.read(hubTilesProvider).keys.toList(), first.keys.toList());
    expect(container.read(hubLayoutProvider).items, layoutAfterFirst.items);
  });

  test('锚点落位:新 key 垫到锚点所在组尾,按 upsert 顺序', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await _seed(container);
    final HubDesktopController hub = container.read(hubDesktopControllerProvider);

    hub.upsertTiles(<HubTile>[
      _tile('feature:apphub-market', '应用市场'),
      _tile('mini:wx1', '记账本'),
      _tile('mini:wx2', '日历'),
    ], anchorKey: 'feature:apphub-market');

    final HubLayout layout = container.read(hubLayoutProvider);
    expect(layout.items['mini:wx1']!.sectionId, 'seed:AppHub');
    expect(layout.items['mini:wx1']!.order, 1); // 市场入口(order 0)之后
    expect(layout.items['mini:wx2']!.sectionId, 'seed:AppHub');
    expect(layout.items['mini:wx2']!.order, 2);
  });

  test('无锚点不做显式落位:未安置 key 由解析垫在默认组尾(注册表序)', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await _seed(container);
    final HubDesktopController hub = container.read(hubDesktopControllerProvider);

    hub.upsertTiles(<HubTile>[
      _tile('feature:apphub-market', '应用市场'),
      _tile('feature:files', '文件'),
      _tile('feature:terminal', '终端'),
    ]);

    expect(container.read(hubLayoutProvider).items.containsKey('feature:files'), isFalse);
    final List<HubResolvedSection> resolved =
        resolveHubLayout(container.read(hubLayoutProvider), container.read(hubTilesProvider).keys.toList());
    final int at = resolved.indexWhere((HubResolvedSection r) => r.section.id == hubDefaultSectionId);
    expect(resolved[at].keys, <String>['feature:files', 'feature:terminal']);
  });

  test('removeTile:槽位保留,重装原位恢复;瓷贴角标顺手清,组头角标不动', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await _seed(container);
    final HubDesktopController hub = container.read(hubDesktopControllerProvider);

    hub.upsertTiles(<HubTile>[
      _tile('feature:apphub-market', '应用市场'),
      _tile('mini:wx1', '记账本'),
    ], anchorKey: 'feature:apphub-market');
    hub.setBadge('mini:wx1', const HubBadge(dot: true));
    hub.setSectionBadge('seed:AppHub', const HubBadge(count: 4));

    hub.removeTile('mini:wx1');
    // 槽位保留:placement 还在;角标被顺手清掉;组头角标不动。
    expect(container.read(hubLayoutProvider).items.containsKey('mini:wx1'), isTrue);
    expect(container.read(hubBadgesProvider).containsKey('mini:wx1'), isFalse);
    expect(container.read(hubSectionBadgesProvider).containsKey('seed:AppHub'), isTrue);
    // 注册表也少了它(目录外 key 不渲染,由解析兜住)。
    expect(container.read(hubTilesProvider).containsKey('mini:wx1'), isFalse);

    // 重装(upsert 回同一 key):原位恢复,不落新位。
    hub.upsertTiles(<HubTile>[_tile('mini:wx1', '记账本')], anchorKey: 'feature:apphub-market');
    final HubPlacement placement = container.read(hubLayoutProvider).items['mini:wx1']!;
    expect(placement.sectionId, 'seed:AppHub');
    expect(placement.order, 1);
  });

  test('卸载钩子:前缀命中,最长前缀优先', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final HubDesktopController hub = container.read(hubDesktopControllerProvider);

    expect(hub.hookFor('mini:wx1'), isNull); // 没注册 = 不可卸

    hub.registerUninstallHook('mini:', (HubTile _) async => true);
    expect(hub.hookFor('mini:wx1'), isNotNull);
    expect(hub.hookFor('feature:files'), isNull); // 别的命名空间不命中

    hub.registerUninstallHook('mini:paid:', (HubTile _) async => false);
    // 同 key 两个前缀都命中:更长的精确接管(paid: 返回 false,其余 true)。
    expect(await hub.hookFor('mini:paid:x')!(_tile('mini:paid:x', 'x')), isFalse);
    expect(await hub.hookFor('mini:plain:x')!(_tile('mini:plain:x', 'x')), isTrue);
  });

  test('角标 store 独立于目录:先 set 后 upsert 的 key 也保留', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final HubDesktopController hub = container.read(hubDesktopControllerProvider);

    hub.setBadge('mini:wx-later', const HubBadge(count: 2));
    expect(container.read(hubBadgesProvider)['mini:wx-later']!.count, 2);

    hub.upsertTiles(<HubTile>[_tile('mini:wx-later', '后装的')]);
    expect(container.read(hubTilesProvider).containsKey('mini:wx-later'), isTrue);
    expect(container.read(hubBadgesProvider).containsKey('mini:wx-later'), isTrue);

    // clearBadge 幂等:清没有的 key 不炸。
    hub.clearBadge('feature:never-set');
    expect(container.read(hubBadgesProvider).containsKey('mini:wx-later'), isTrue);
  });
}
