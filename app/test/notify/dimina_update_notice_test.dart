// 升级完成告知（契约 §6.4）：容器 `applied` 事件 → 一条瞬态告知。
// 前台弹玻璃 Banner 数秒即收，后台走 NotifyChannel；**不进未读收件箱**。

import 'package:dsh_app/state/apphub_notices_state.dart';
import 'package:dsh_app/notify/notify_channel.dart' show NotifySystemStatus;
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
  setUp(() {
    DiminaHost.ensureNativeHandler();
  });

  testWidgets('applied 事件（前台）：弹瞬态 Banner 且不进未读收件箱', (tester) async {
    final channel = FakeNotifyChannel();
    final container = await pumpHost(tester, <Override>[
      appHubNoticesProvider.overrideWith(_EmptyNotices.new),
      notifyChannelProvider.overrideWithValue(channel),
    ]);
    await _applied(versionCode: 21);
    await tester.pumpAndSettle();

    expect(find.text('「记账」已升级至 v1.2.3'), findsOneWidget);
    expect(container.read(appHubNoticesProvider).notices, isEmpty, reason: '升级告知是过场信息，不进收件箱');
    expect(container.read(appHubNoticesProvider).unread, 0);
    expect(channel.shown, isEmpty, reason: '前台只弹 Banner，不发系统通知');

    // 几秒后自动收起。
    await tester.pump(const Duration(seconds: 13));
    await tester.pumpAndSettle();
    expect(find.text('「记账」已升级至 v1.2.3'), findsNothing);
  });

  testWidgets('applied 事件（后台）：走系统通知、kind=update、不进收件箱', (tester) async {
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
}
