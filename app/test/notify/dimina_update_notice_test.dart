// 装好/升好告知（契约 §6.4 修订 + 首装修订，2026-11-12：告知都进收件箱）：
// 服务端落上（POST /api/v1/notices 200）→ 立即拉一轮，走既有投递管线——
// 前台正式 Banner、未读收件箱一条记录（升级 templateId=system-upgrade /
// 首装 system-install）；服务端没落上（不可达/拒绝）→ 回落瞬态告知：前台
// 玻璃 Banner 数秒即收，后台走 NotifyChannel（kind=update），不进收件箱。

import 'package:dsh_app/notify/apphub_notices.dart' show AppHubNoticeService;
import 'package:dsh_app/state/apphub_notices_state.dart';
import 'package:dsh_app/notify/notify_channel.dart' show NotifySystemStatus;
import 'package:dsh_app/state/auto_sync_state.dart';
import 'package:dsh_app/state/notify_state.dart'
    show FlagController, appForegroundProvider, notifyChannelProvider, notifySystemStatusProvider;
import 'package:dsh_app/ui/applet/dimina/dimina_host.dart';
import 'package:dsh_app/ui/notify/apphub_notice_host.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';
import 'support.dart';

const _codec = StandardMethodCodec();

Future<void> _applied({int versionCode = 12, String versionName = '1.2.3'}) async {
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
    'dsh/dimina',
    _codec.encodeMethodCall(
      MethodCall('onUpdateEvent', <String, Object?>{
        'event': 'applied',
        'appId': 'wxapp',
        'versionCode': versionCode,
        'versionName': versionName,
      }),
    ),
    (ByteData? _) {},
  );
}

Future<ProviderContainer> pumpHost(WidgetTester tester, List<Override> overrides) async {
  await tester.runAsync(loadTestFonts);
  usePhoneView(tester);
  await tester.pumpWidget(
    testApp(
      const AppHubNoticeHost(),
      overrides: <Override>[
        appHubAppNamesProvider.overrideWith((ref) async => const <String, String>{'wxapp': '记账'}),
        // 这组测试只管升级告知：不启动轮询（避免测试期无谓的网络尝试）。
        notifySystemStatusProvider.overrideWith((ref) async => const NotifySystemStatus.unavailable()),
        ...overrides,
      ],
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  return ProviderScope.containerOf(tester.element(find.byType(AppHubNoticeHost)));
}

class _EmptyNotices extends AppHubNoticesController {
  @override
  AppHubNotices build() => const AppHubNotices(loaded: true);

  @override
  Future<void> refresh() async {}
}

void main() {
  setUp(() async {
    // 36c7d762 通知入口迁移后,ensureNativeHandler 随容器 Header 铃铛接线一起
    // 拆掉了;但 applied 事件仍走 `dsh/dimina` 的 onUpdateEvent 分发。测试里
    // 挂分发器借用公开的 sync()(它第一步就是挂 handler):mock 掉通道出站,
    // 返回 null = 老原生不支持,调用方静默,无副作用。
    const MethodChannel channel = MethodChannel('dsh/dimina');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => null);
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    await DiminaHost.sync(appId: 'wxapp', name: '记账');
    // 默认注入「服务端没落上」：这组用例主打回落行为；要测进收件箱的用例
    // 自己把 reportHostNotice 换成 true。测试完还原生产实现。
    final Future<bool> Function({
      required String appId,
      required String title,
      required String body,
      String? dedupeKey,
      String? templateId,
    }) originalReport = AppHubNoticeService.reportHostNotice;
    final Future<void> Function() originalPoll = AppHubNoticeService.pollNow;
    AppHubNoticeService.reportHostNotice =
        ({required String appId, required String title, required String body, String? dedupeKey, String? templateId}) async =>
            false;
    AppHubNoticeService.pollNow = () async {};
    addTearDown(() {
      AppHubNoticeService.reportHostNotice = originalReport;
      AppHubNoticeService.pollNow = originalPoll;
    });
  });

  testWidgets('applied 事件（前台，服务端没落上）：回落瞬态 Banner 且不进未读收件箱', (tester) async {
    final channel = FakeNotifyChannel();
    final container = await pumpHost(tester, <Override>[
      appHubNoticesProvider.overrideWith(_EmptyNotices.new),
      notifyChannelProvider.overrideWithValue(channel),
    ]);
    await _applied(versionCode: 21);
    await tester.pumpAndSettle();

    expect(find.text('「记账」已升级至 v1.2.3'), findsOneWidget);
    expect(container.read(appHubNoticesProvider).notices, isEmpty, reason: '回落告知不进收件箱');
    expect(container.read(appHubNoticesProvider).unread, 0);
    expect(channel.shown, isEmpty, reason: '前台只弹 Banner，不发系统通知');

    // 几秒后自动收起。
    await tester.pump(const Duration(seconds: 13));
    await tester.pumpAndSettle();
    expect(find.text('「记账」已升级至 v1.2.3'), findsNothing);
  });

  testWidgets('applied 事件（服务端落上）：进收件箱，走既有管线出正式 Banner', (tester) async {
    final channel = FakeNotifyChannel();
    final container = await pumpHost(tester, <Override>[
      appHubNoticesProvider.overrideWith(_EmptyNotices.new),
      notifyChannelProvider.overrideWithValue(channel),
    ]);
    // 服务端落库后的既有管线：轮询把新行 ingest 进收件箱并弹正式 Banner。
    const MiniAppNotice row = MiniAppNotice(
      id: 7,
      appId: 'wxapp',
      templateId: kHostUpgradeTemplateId,
      title: '记账',
      body: '「记账」已升级至 v1.2.3',
    );
    String? capturedKey;
    String? capturedTemplate;
    AppHubNoticeService.reportHostNotice =
        ({required String appId, required String title, required String body, String? dedupeKey, String? templateId}) async {
          capturedKey = dedupeKey;
          capturedTemplate = templateId;
          container.read(appHubNoticesProvider.notifier).ingest(<MiniAppNotice>[row], unread: 1);
          container.read(appHubNoticesProvider.notifier).showBanner(row);
          return true;
        };
    await _applied(versionCode: 31);
    await tester.pumpAndSettle();

    expect(capturedKey, 'upgrade-31', reason: 'dedupeKey 带版本，升级重试幂等');
    expect(capturedTemplate, kHostUpgradeTemplateId, reason: '升级告知显式标 system-upgrade');
    expect(container.read(appHubNoticesProvider).unread, 1);
    expect(container.read(appHubNoticesProvider).notices.single.templateId, kHostUpgradeTemplateId);
    // 前台弹正式 Banner（title=应用名，不缀应用名后缀），系统通知没发。
    expect(find.text('「记账」已升级至 v1.2.3'), findsOneWidget);
    expect(channel.shown, isEmpty);
    // Banner 到点收起，收件箱记录保留（与回落瞬态告知的关键差异）。
    await tester.pump(const Duration(seconds: 13));
    await tester.pumpAndSettle();
    expect(find.text('「记账」已升级至 v1.2.3'), findsNothing);
    expect(container.read(appHubNoticesProvider).notices, hasLength(1));
  });

  testWidgets('applied 事件（后台，服务端没落上）：回落系统通知、kind=update、不进收件箱', (tester) async {
    final channel = FakeNotifyChannel();
    final container = await pumpHost(tester, <Override>[
      appHubNoticesProvider.overrideWith(_EmptyNotices.new),
      notifyChannelProvider.overrideWithValue(channel),
      appForegroundProvider.overrideWith(() => FlagController(false)),
    ]);
    await _applied(versionCode: 22);
    await tester.pumpAndSettle();

    expect(channel.shown, hasLength(1));
    final post = channel.shown.single;
    expect(post.kind, 'update');
    expect(post.title, '记账');
    expect(post.text, '「记账」已升级至 v1.2.3');
    expect(post.notifyId, isNull, reason: '不是收件箱通知，点它不回写已读');
    expect(container.read(appHubNoticesProvider).notices, isEmpty);
  });

  testWidgets('同一个版本的 applied 只说一次', (tester) async {
    final channel = FakeNotifyChannel();
    await pumpHost(tester, <Override>[
      appHubNoticesProvider.overrideWith(_EmptyNotices.new),
      notifyChannelProvider.overrideWithValue(channel),
      appForegroundProvider.overrideWith(() => FlagController(false)),
    ]);
    await _applied(versionCode: 23);
    await tester.pumpAndSettle();
    await _applied(versionCode: 23);
    await tester.pumpAndSettle();
    expect(channel.shown, hasLength(1));
  });

  // ── 首装完成告知（§6.4 首装修订，2026-11-12「server 装了前端配套装」）──

  void emitInstall({required int versionCode}) =>
      AutoSyncRunner.debugEmitInstallApplied(AutoSyncOutcome(
        appId: 'wxapp',
        kind: AutoSyncActionKind.install,
        ok: true,
        versionCode: versionCode,
        detail: 'installed',
      ));

  testWidgets('install 事件（前台，服务端没落上）：回落瞬态 Banner 且不进收件箱', (tester) async {
    final channel = FakeNotifyChannel();
    final container = await pumpHost(tester, <Override>[
      appHubNoticesProvider.overrideWith(_EmptyNotices.new),
      notifyChannelProvider.overrideWithValue(channel),
    ]);
    emitInstall(versionCode: 41);
    await tester.pumpAndSettle();

    expect(find.text('「记账」已装好 v41，在小程序桌面打开'), findsOneWidget);
    expect(container.read(appHubNoticesProvider).notices, isEmpty, reason: '回落告知不进收件箱');
    expect(channel.shown, isEmpty, reason: '前台只弹 Banner，不发系统通知');
    await tester.pump(const Duration(seconds: 13));
    await tester.pumpAndSettle();
    expect(find.text('「记账」已装好 v41，在小程序桌面打开'), findsNothing);
  });

  testWidgets('install 事件（服务端落上）：进收件箱 templateId=system-install，点击语义同升级', (tester) async {
    final channel = FakeNotifyChannel();
    final container = await pumpHost(tester, <Override>[
      appHubNoticesProvider.overrideWith(_EmptyNotices.new),
      notifyChannelProvider.overrideWithValue(channel),
    ]);
    const MiniAppNotice row = MiniAppNotice(
      id: 9,
      appId: 'wxapp',
      templateId: kHostInstallTemplateId,
      title: '记账',
      body: '「记账」已装好 v42，在小程序桌面打开',
    );
    String? capturedKey;
    String? capturedTemplate;
    AppHubNoticeService.reportHostNotice =
        ({required String appId, required String title, required String body, String? dedupeKey, String? templateId}) async {
          capturedKey = dedupeKey;
          capturedTemplate = templateId;
          container.read(appHubNoticesProvider.notifier).ingest(<MiniAppNotice>[row], unread: 1);
          container.read(appHubNoticesProvider.notifier).showBanner(row);
          return true;
        };
    emitInstall(versionCode: 42);
    await tester.pumpAndSettle();

    expect(capturedKey, 'install-42', reason: 'dedupeKey 带版本，重装重试幂等');
    expect(capturedTemplate, kHostInstallTemplateId, reason: '首装告知标 system-install');
    expect(container.read(appHubNoticesProvider).unread, 1);
    expect(container.read(appHubNoticesProvider).notices.single.templateId, kHostInstallTemplateId);
    expect(find.text('「记账」已装好 v42，在小程序桌面打开'), findsOneWidget);
    expect(channel.shown, isEmpty);
    await tester.pump(const Duration(seconds: 13));
    await tester.pumpAndSettle();
    expect(find.text('「记账」已装好 v42，在小程序桌面打开'), findsNothing);
    expect(container.read(appHubNoticesProvider).notices, hasLength(1), reason: '收件箱记录保留');
  });

  testWidgets('install 事件（后台，服务端没落上）：回落系统通知、不进收件箱', (tester) async {
    final channel = FakeNotifyChannel();
    final container = await pumpHost(tester, <Override>[
      appHubNoticesProvider.overrideWith(_EmptyNotices.new),
      notifyChannelProvider.overrideWithValue(channel),
      appForegroundProvider.overrideWith(() => FlagController(false)),
    ]);
    emitInstall(versionCode: 43);
    await tester.pumpAndSettle();

    expect(channel.shown, hasLength(1));
    final post = channel.shown.single;
    expect(post.kind, 'update');
    expect(post.title, '记账');
    expect(post.text, '「记账」已装好 v43，在小程序桌面打开');
    expect(post.publicText, '小程序已安装');
    expect(container.read(appHubNoticesProvider).notices, isEmpty);
  });

  testWidgets('同一个版本的 install 只说一次', (tester) async {
    final channel = FakeNotifyChannel();
    await pumpHost(tester, <Override>[
      appHubNoticesProvider.overrideWith(_EmptyNotices.new),
      notifyChannelProvider.overrideWithValue(channel),
      appForegroundProvider.overrideWith(() => FlagController(false)),
    ]);
    emitInstall(versionCode: 44);
    await tester.pumpAndSettle();
    emitInstall(versionCode: 44);
    await tester.pumpAndSettle();
    expect(channel.shown, hasLength(1));
  });
}
