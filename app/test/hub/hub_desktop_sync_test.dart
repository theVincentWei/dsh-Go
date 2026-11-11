// noteNew 守卫测试(预览反馈收尾):prefs 后端缺失时静默跳过——不抛、
// 不点亮,整轮目录推送不中断(注册表照常落库)。

import 'package:dsh_app/state/hub_desktop_sync.dart'
    show hubDesktopSyncProvider, hubNewMinisProvider;
import 'package:dsh_app/ui/applet/hub_apps_group.dart'
    show HubInstalledApp, HubInstalledController, hubInstalledProvider;
import 'package:dsh_app/ui/features/feature_catalog.dart'
    show FeatureSection, featureSectionsProvider;
import 'package:flutter/services.dart' show MethodCall, MethodChannel;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:hub_desktop/hub_desktop.dart' show hubTilesProvider;

class _FixedInstalled extends HubInstalledController {
  _FixedInstalled(this.apps);

  final List<HubInstalledApp> apps;

  @override
  Future<List<HubInstalledApp>> build() async => apps;
}

Future<void> _flush() async {
  await Future<void>.delayed(const Duration(milliseconds: 5));
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // sync 链路的两个 EventChannel 在测试环境没有实现:激活/取消都会抛
    // MissingPlugin(dispose 阶段背锅)。mock 掉 listen,让用例只聚焦
    // noteNew 的 prefs 缺失分支。
    for (final String channel in <String>[
      'dev.fluttercommunity.plus/connectivity_status',
      'dsh/runtime/events',
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(channel), (MethodCall call) async => null);
    }
  });

  // 故意不 mock SharedPreferences:getInstance 走平台通道,单测环境必
  // MissingPlugin → _load 走缺失分支,noteNew 必须静默跳过(修复前这里
  // 会对 const 初始集合 addAll 抛 UnsupportedError,整轮推送中断)。
  test('prefs 后端缺失:noteNew 静默跳过,目录推送不中断、不点亮', () async {
    final ProviderContainer container = ProviderContainer(overrides: <Override>[
      hubInstalledProvider.overrideWith(
          () => _FixedInstalled(<HubInstalledApp>[
                const HubInstalledApp(appId: 'wx1', name: '记账本'),
              ])),
      featureSectionsProvider.overrideWithValue(const <FeatureSection>[]),
    ]);
    addTearDown(container.dispose);

    container.read(hubDesktopSyncProvider); // 激活注册者(推目录+新装检测)
    await _flush();
    await _flush();

    // 目录照常落库(noteNew 没把推送打断)。
    expect(container.read(hubTilesProvider), contains('mini:wx1'));
    // 不点亮任何「新装未打开」名字点。
    expect(container.read(hubNewMinisProvider), isEmpty);
  });
}
