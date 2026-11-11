// 容器 Header 铃铛接线（契约 §6.3）：dsh/dimina 通道的
//   Dart → 原生 pushNotifyUnread
//   原生 → Dart openNotificationCenter / fetchUnread
// 以及宿主件收到点击后 push 通知中心页。


import 'package:dsh_app/state/apphub_notices_state.dart';
import 'package:dsh_app/ui/applet/dimina/dimina_host.dart';
import 'package:dsh_app/ui/notify/apphub_notice_host.dart';
import 'package:dsh_app/ui/notify/notification_center.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';

const _codec = StandardMethodCodec();
const _channelName = 'dsh/dimina';

/// 把一条「原生 → Dart」的通道消息交给 Dart 侧 handler，返回它的回复。
Future<Object?> _nativeCall(MethodCall call) async {
  final ByteData? reply = await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(_channelName, _codec.encodeMethodCall(call), (ByteData? _) {});
  if (reply == null) return null;
  return _codec.decodeEnvelope(reply);
}

class _FakeNotices extends AppHubNoticesController {
  _FakeNotices(this.initial);

  final AppHubNotices initial;
  int refreshCalls = 0;

  @override
  AppHubNotices build() => initial;

  @override
  Future<void> refresh() async => refreshCalls++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final List<MethodCall> pushed = <MethodCall>[];

  setUp(() {
    pushed.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel(_channelName),
      (MethodCall call) async {
        pushed.add(call);
        return null;
      },
    );
    DiminaHost.ensureNativeHandler();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(_channelName), null);
  });

  test('pushNotifyUnread 走通道把角标数推给原生容器', () async {
    await DiminaHost.pushNotifyUnread(7);
    expect(DiminaHost.notifyUnread, 7);
    final MethodCall call = pushed.single;
    expect(call.method, 'pushNotifyUnread');
    expect(call.arguments, <String, Object?>{'count': 7});
  });

  test('fetchUnread 返回最近一次推送的未读数（容器 resume 兜底）', () async {
    await DiminaHost.pushNotifyUnread(2);
    expect(await _nativeCall(const MethodCall('fetchUnread')), 2);
  });

  test('openNotificationCenter 触发宿主件的通知中心请求流', () async {
    final Future<void> requested = DiminaHost.notificationCenterRequests.first;
    await _nativeCall(const MethodCall('openNotificationCenter'));
    await requested;
  });

  testWidgets('铃铛点击会把通知中心页推到前台', (tester) async {
    await tester.runAsync(loadTestFonts);
    usePhoneView(tester);
    final fake = _FakeNotices(const AppHubNotices(loaded: true));
    await tester.pumpWidget(
      testApp(
        const AppHubNoticeHost(),
        overrides: <Override>[
          appHubNoticesProvider.overrideWith(() => fake),
          appHubAppNamesProvider.overrideWith((ref) async => const <String, String>{}),
        ],
      ),
    );
    await tester.pump();
    expect(find.byType(NotificationCenterPage), findsNothing);

    await _nativeCall(const MethodCall('openNotificationCenter'));
    await tester.pumpAndSettle();
    expect(find.byType(NotificationCenterPage), findsOneWidget);
  });
}
