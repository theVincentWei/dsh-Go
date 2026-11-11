// autoSync 静默同步的 planner 纯函数测试:目录 + 本机已装 → 动作列表。
// runner 的执行路径(网络/通道)不在单测面,由真机验收覆盖。
library;

import 'package:dsh_app/state/auto_sync_state.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> catalogApp({
  required String appId,
  int? versionCode,
  bool? autoSync,
  String name = '应用',
}) =>
    <String, Object?>{
      'appId': appId,
      'name': name,
      'versionCode': ?versionCode,
      'autoSync': ?autoSync,
      'iconUrl': 'http://hub/icons/$appId-icon.png',
    };

/// 本机已装状态:{appId → 本机 versionCode};value 为 null 表示查询失败
/// (runner 把失败归一成 null,planner 按「未装」处理)。
Map<String, Map<String, Object?>?> installedOf({Map<String, int?> versions = const {}}) =>
    <String, Map<String, Object?>?>{
      for (final MapEntry<String, int?> entry in versions.entries)
        entry.key: entry.value == null
            ? null
            : <String, Object?>{
                'installed': true,
                'versionCode': entry.value,
                'versionName': 'x',
              },
    };

void main() {
  test('总开关关闭 → 空 plan', () {
    final List<AutoSyncAction> actions = planAutoSync(
      catalog: <Map<String, Object?>>[
        catalogApp(appId: 'a', versionCode: 1, autoSync: true),
      ],
      installed: installedOf(),
      enabled: false,
    );
    expect(actions, isEmpty);
  });

  test('升级全自动:非 autoSync 已装且落后 → 照样 update;已装不落后 → 跳过', () {
    final List<AutoSyncAction> actions = planAutoSync(
      catalog: <Map<String, Object?>>[
        catalogApp(appId: 'plain', versionCode: 5, autoSync: false),
        catalogApp(appId: 'legacy', versionCode: 7),
      ],
      installed: installedOf(versions: <String, int?>{'plain': 3, 'legacy': 7}),
      enabled: true,
    );
    // plain 已装落后 → 静默升级(不再看 autoSync);legacy 已装不落后 → 跳过。
    expect(actions, hasLength(1));
    expect(actions.single.appId, 'plain');
    expect(actions.single.kind, AutoSyncActionKind.update);
    expect(actions.single.targetVersionCode, 5);
  });

  test('首装全自动(2026-11-12 拍板「server 装了前端配套装」):未装 → install,不看 autoSync', () {
    final List<AutoSyncAction> actions = planAutoSync(
      catalog: <Map<String, Object?>>[
        catalogApp(appId: 'plain', versionCode: 5, autoSync: false),
        catalogApp(appId: 'legacy', versionCode: 5),
        catalogApp(appId: 'flagged', versionCode: 2, autoSync: true),
      ],
      installed: installedOf(),
      enabled: true,
    );
    // autoSync 字段退役:false/缺字段/true 一律静默装上桌面。
    expect(actions, hasLength(3));
    expect(
      <String>[for (final AutoSyncAction action in actions) action.appId],
      <String>['plain', 'legacy', 'flagged'],
    );
    expect(
      <AutoSyncActionKind>[for (final AutoSyncAction action in actions) action.kind],
      everyElement(AutoSyncActionKind.install),
    );
  });

  test('没装的 autoSync 应用 → install 动作,manifest 指向固定端口反代', () {
    final List<AutoSyncAction> actions = planAutoSync(
      catalog: <Map<String, Object?>>[
        catalogApp(appId: 'wxabc', versionCode: 3, autoSync: true),
      ],
      installed: installedOf(),
      enabled: true,
    );
    expect(actions, hasLength(1));
    expect(actions.single.appId, 'wxabc');
    expect(actions.single.kind, AutoSyncActionKind.install);
    expect(actions.single.targetVersionCode, 3);
    expect(
      actions.single.updateManifestUrl,
      endsWith('/apps/wxabc/manifest.json'),
    );
  });

  test('已装且落后 → update 动作;持平/领先 → 跳过', () {
    final List<AutoSyncAction> actions = planAutoSync(
      catalog: <Map<String, Object?>>[
        catalogApp(appId: 'behind', versionCode: 9, autoSync: true),
        catalogApp(appId: 'even', versionCode: 4, autoSync: true),
        catalogApp(appId: 'ahead', versionCode: 1, autoSync: true),
      ],
      installed: installedOf(versions: <String, int?>{
        'behind': 2,
        'even': 4,
        'ahead': 5,
      }),
      enabled: true,
    );
    expect(actions, hasLength(1));
    expect(actions.single.appId, 'behind');
    expect(actions.single.kind, AutoSyncActionKind.update);
    expect(actions.single.targetVersionCode, 9);
  });

  test('目录缺 versionCode / 目录行缺 appId → 跳过', () {
    final List<AutoSyncAction> actions = planAutoSync(
      catalog: <Map<String, Object?>>[
        catalogApp(appId: 'noversion', autoSync: true),
        catalogApp(appId: '', versionCode: 2, autoSync: true),
      ],
      installed: installedOf(),
      enabled: true,
    );
    expect(actions, isEmpty);
  });

  test('本周期已试过同一目标版本 → 跳过;目标版本变了 → 重试', () {
    final List<AutoSyncAction> actions = planAutoSync(
      catalog: <Map<String, Object?>>[
        catalogApp(appId: 'retry-same', versionCode: 3, autoSync: true),
        catalogApp(appId: 'retry-next', versionCode: 7, autoSync: true),
      ],
      installed: installedOf(),
      enabled: true,
      attempted: <String, int>{'retry-same': 3, 'retry-next': 5},
    );
    expect(actions, hasLength(1));
    expect(actions.single.appId, 'retry-next');
    expect(actions.single.targetVersionCode, 7);
  });

  test('本机查询失败(null)按未装处理 → install', () {
    final List<AutoSyncAction> actions = planAutoSync(
      catalog: <Map<String, Object?>>[
        catalogApp(appId: 'unknown', versionCode: 2, autoSync: true),
      ],
      installed: installedOf(versions: <String, int?>{'unknown': null}),
      enabled: true,
    );
    expect(actions.single.kind, AutoSyncActionKind.install);
  });

  test('卸载豁免:豁免表里的未装 app 不再自动装回(卸载语义不被吃掉)', () {
    final List<AutoSyncAction> actions = planAutoSync(
      catalog: <Map<String, Object?>>[
        catalogApp(appId: 'removed', versionCode: 5),
        catalogApp(appId: 'kept', versionCode: 5),
      ],
      installed: installedOf(),
      enabled: true,
      excluded: const <String>{'removed'},
    );
    // removed 被用户卸载过(未 purge)→ 跳过;kept 照常 install。
    expect(actions, hasLength(1));
    expect(actions.single.appId, 'kept');
    expect(actions.single.kind, AutoSyncActionKind.install);
  });
}
