// 多机可用性单元测试(2026-11-11 拍板:离线常驻/带后端按机器判):
// availableOnCurrentMachine 真值表、backendRequired 进快照而 backendRunning
// 刻意不落盘、mergeInstalledMinis(目录核对 ∪ 快照档案兜底 ∪ 卸载剔除)。
// 快照读写/控制器时序归 hub_installed_snapshot_test.dart,这里不重复。
library;

import 'dart:convert';

import 'package:dsh_app/ui/applet/hub_apps_group.dart';
import 'package:flutter_test/flutter_test.dart';

HubInstalledApp mini({bool backendRequired = false, bool? backendRunning}) =>
    HubInstalledApp(
      appId: 'wx-a',
      name: '应用',
      backendRequired: backendRequired,
      backendRunning: backendRunning,
    );

void main() {
  test('availableOnCurrentMachine 真值表:离线常亮;依赖后端的查不到=置灰', () {
    // 纯离线:任何机器都可用。
    expect(mini().availableOnCurrentMachine, isTrue);
    // 声明了后端:当前机器在跑才可用。
    expect(mini(backendRequired: true, backendRunning: true).availableOnCurrentMachine, isTrue);
    expect(mini(backendRequired: true, backendRunning: false).availableOnCurrentMachine, isFalse);
    // 运行态查不到(老 server/目录失败/档案兜底):宁可灰不可假亮。
    expect(mini(backendRequired: true, backendRunning: null).availableOnCurrentMachine, isFalse);
  });

  test('JSON 往返:backendRequired 持久化,backendRunning 不落盘(逐机器事实)', () {
    const HubInstalledApp app = HubInstalledApp(
      appId: 'wx-sys',
      name: '系统监视器',
      iconKey: 'pulse',
      backendRequired: true,
      backendRunning: true,
    );
    final HubInstalledApp back = HubInstalledApp.fromJson(
        (jsonDecode(jsonEncode(app.toJson())) as Map<String, Object?>));
    expect(back.appId, app.appId);
    expect(back.backendRequired, isTrue);
    // 运行态不进快照:换机器后的第一帧不许假亮,真值由目录刷新回填。
    expect(back.backendRunning, isNull);
    // 坏字段/缺字段容错。
    final HubInstalledApp bare = HubInstalledApp.fromJson(<String, Object?>{'appId': 'wx-b'});
    expect(bare.name, '');
    expect(bare.backendRequired, isFalse);
    expect(bare.availableOnCurrentMachine, isTrue);
  });

  test('mergeInstalledMinis:目录行优先,快照补齐目录查不到的,本机已卸载的剔除', () {
    final Map<String, Map<String, Object?>?> states = <String, Map<String, Object?>?>{
      // 目录里的:a 仍装;b 目录有行但本机已不装(provider 阶段已过滤)。
      'wx-a': <String, Object?>{'installed': true, 'versionCode': 4},
      'wx-b': <String, Object?>{'installed': false, 'versionCode': 1},
      // 快照里的:c 本机仍装(目录没这行,比如换机器)→ 保留;d 已卸载 → 剔除。
      'wx-c': <String, Object?>{'installed': true, 'versionCode': 9},
      'wx-d': <String, Object?>{'installed': false},
    };
    final List<HubInstalledApp> merged = mergeInstalledMinis(
      // 契约:fromDirectory 只含「目录有行且本机核对仍安装」的条目。
      fromDirectory: <HubInstalledApp>[
        HubInstalledApp(
          appId: 'wx-a',
          name: '甲',
          installedVersionCode: 4,
          marketVersionCode: 5,
          backendRequired: true,
          backendRunning: false,
        ),
      ],
      directoryIds: <String>{'wx-a', 'wx-b'},
      states: states,
      archived: const <HubInstalledApp>[
        HubInstalledApp(appId: 'wx-c', name: '丙', backendRequired: true, installedVersionCode: 9),
        HubInstalledApp(appId: 'wx-d', name: '丁'),
      ],
    );

    final List<String> ids = <String>[for (final HubInstalledApp app in merged) app.appId];
    expect(ids, <String>['wx-a', 'wx-c']);
    // 档案兜底的条目:本机版本照常,市场版本未知(不挂更新点),运行态未知置灰。
    final HubInstalledApp c = merged.last;
    expect(c.name, '丙');
    expect(c.installedVersionCode, 9);
    expect(c.marketVersionCode, isNull);
    expect(c.updateAvailable, isFalse);
    expect(c.availableOnCurrentMachine, isFalse);
  });
}
