// 已装清单持久化快照的测试(T3「整页弹入」修复):冷启有快照时首轮即
// 现状(loading 不经过 UI)、真清单落定后对账(diff 消失)、成功非空才
// 写盘、刷新失败/空结果保留快照(网络抖动与 host 断开不塌目录)、损坏
// 快照容错、无快照保持旧语义、invalidate 直拉真数据不闪回快照。

import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/ui/applet/hub_apps_group.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _snapshotKey = 'hub.installed-snapshot.v1';

/// autoDispose 的 provider 靠 listener 养活(read 不算监听,无监听当拍即
/// 弃置、build 被取消);生产由 keep-alive 注册者(hubDesktopSyncProvider)
/// 从应用根 watch。
ProviderContainer _liveContainer() {
  final ProviderContainer container = ProviderContainer();
  addTearDown(container.dispose);
  container.listen(hubInstalledProvider, (_, _) {});
  return container;
}

List<HubInstalledApp> _apps(List<String> ids) => <HubInstalledApp>[
      for (final String id in ids) HubInstalledApp(appId: id, name: '应用$id'),
    ];

Future<void> _flush() async {
  // 一个真实时钟拍 + 两轮微任务:把挂起的静默刷新与 unawaited 的
  // prefs 写链都冲完,再断言。
  await Future<void>.delayed(const Duration(milliseconds: 5));
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

/// 读快照原文(prefs 里落的 JSON)。
Future<Object?> _snapshotRaw() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  return jsonDecode(prefs.getString(_snapshotKey)!);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final Future<List<HubInstalledApp>> Function() original = HubInstalledController.fetcher;
    addTearDown(() => HubInstalledController.fetcher = original);
  });

  test('快照存在:冷启现状即快照(真值未落不空窗),刷新后对账并写盘', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      _snapshotKey: jsonEncode(<Object?>[for (final HubInstalledApp a in _apps(<String>['wx1', 'wx2'])) a.toJson()]),
    });
    int fetchCalls = 0;
    final Completer<List<HubInstalledApp>> gate = Completer<List<HubInstalledApp>>();
    HubInstalledController.fetcher = () async {
      fetchCalls++;
      return gate.future;
    };

    final ProviderContainer container = _liveContainer();

    // 冷启首轮:build 的结果就是快照(真数据还在闸门外,现状不空窗)。
    final List<HubInstalledApp> first = await container.read(hubInstalledProvider.future);
    expect(first.map((HubInstalledApp a) => a.appId), <String>['wx1', 'wx2']);
    expect(container.read(hubInstalledProvider).isLoading, isFalse);

    // 闸门放行真值(wx2 已卸载 → 对账消失),fetch 恰好跑一次。
    gate.complete(_apps(<String>['wx1']));
    await _flush();
    expect(container.read(hubInstalledProvider).value!.map((HubInstalledApp a) => a.appId), <String>['wx1']);
    expect(fetchCalls, 1);

    // 快照已被真值覆盖(wx2 不再回来)。
    final List<dynamic> saved = await _snapshotRaw() as List<dynamic>;
    expect(saved, hasLength(1));
    expect((saved.single as Map<dynamic, dynamic>)['appId'], 'wx1');
  });

  test('刷新失败保留快照(目录不塌),空结果同样保留(host 断开不塌)', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      _snapshotKey: jsonEncode(<Object?>[for (final HubInstalledApp a in _apps(<String>['wx1'])) a.toJson()]),
    });
    HubInstalledController.fetcher = () async => throw Exception('host down');

    final ProviderContainer container = _liveContainer();
    final List<HubInstalledApp> first = await container.read(hubInstalledProvider.future);
    expect(first.single.appId, 'wx1'); // build 的结果就是快照
    await _flush();
    await _flush();
    expect(container.read(hubInstalledProvider).hasError, isFalse);
    expect(container.read(hubInstalledProvider).value!.single.appId, 'wx1');

    // 空结果(host 断开时逐个失败归一成空):invalidate 后同样保留现状。
    HubInstalledController.fetcher = () async => const <HubInstalledApp>[];
    container.invalidate(hubInstalledProvider);
    final List<HubInstalledApp> rebuilt = await container.read(hubInstalledProvider.future);
    expect(rebuilt.single.appId, 'wx1'); // 空结果不塌非空现状
    await _flush();
    expect(container.read(hubInstalledProvider).value!.single.appId, 'wx1');
    // 且不把空清单写进快照。
    final List<dynamic> saved = await _snapshotRaw() as List<dynamic>;
    expect(saved, hasLength(1));
  });

  test('损坏快照容错:当没有快照,直接走真抓取', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{_snapshotKey: '{oops'});
    HubInstalledController.fetcher = () async => _apps(<String>['wx8']);

    final ProviderContainer container = _liveContainer();
    expect(container.read(hubInstalledProvider).isLoading, isTrue);
    await _flush();
    expect(container.read(hubInstalledProvider).value!.single.appId, 'wx8');
    // 成功落定后写盘,坏快照被好快照顶掉。
    expect(((await _snapshotRaw() as List<dynamic>).single as Map<dynamic, dynamic>)['appId'], 'wx8');
  });

  test('无快照(首次安装):旧语义,loading→真值,成功非空才写盘', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    int fetchCalls = 0;
    HubInstalledController.fetcher = () async {
      fetchCalls++;
      return _apps(<String>['wx9']);
    };

    final ProviderContainer container = _liveContainer();
    expect(container.read(hubInstalledProvider).isLoading, isTrue);
    await _flush();
    expect(container.read(hubInstalledProvider).value!.single.appId, 'wx9');
    expect(fetchCalls, 1);
    expect(((await _snapshotRaw() as List<dynamic>).single as Map<dynamic, dynamic>)['appId'], 'wx9');
  });

  test('invalidate 直拉真数据,不闪回快照', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      _snapshotKey: jsonEncode(<Object?>[for (final HubInstalledApp a in _apps(<String>['wx1'])) a.toJson()]),
    });
    int fetchCalls = 0;
    List<HubInstalledApp> real = _apps(<String>['wx1', 'wx2']);
    HubInstalledController.fetcher = () async {
      fetchCalls++;
      return real;
    };

    final ProviderContainer container = _liveContainer();
    await _flush(); // 冷启轮:快照 → 真值 [wx1, wx2]
    expect(container.read(hubInstalledProvider).value!.map((HubInstalledApp a) => a.appId), <String>['wx1', 'wx2']);
    expect(fetchCalls, 1);

    // 打开小程序/卸载路径的 invalidate:直接真抓取(没有快照闪回),
    // 新清单立刻就是现状。
    real = _apps(<String>['wx1', 'wx3']);
    container.invalidate(hubInstalledProvider);
    await container.read(hubInstalledProvider.future);
    expect(container.read(hubInstalledProvider).value!.map((HubInstalledApp a) => a.appId), <String>['wx1', 'wx3']);
    expect(fetchCalls, 2);
  });
}
