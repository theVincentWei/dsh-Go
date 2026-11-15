// DiminaHost「小程序问AI」链路(2026-11-15 拍板)测试:
// - onAskAi 透传 {appId, appName, pageTitle, pagePath} → DiminaAskAiEvent;
// - 页面信息缺省(容器拿不到页标题/路径)→ 字段容错成 null,事件不丢;
// - arguments 非 Map → 不发事件(坏 payload 不炸);
// - floatCurrentMiniProgram 走 'float' 分支回传 bool;老原生 notImplemented
//   /通道异常 → false(进场链路据此不进)。
library;

import 'dart:async';

import 'package:dsh_app/ui/applet/dimina/dimina_host.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel('dsh/dimina');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  /// 原生 → Dart:在 dsh/dimina 上发一条 onAskAi(先装 handler:调一次 float)。
  Future<void> installHandler() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async => true);
    await DiminaHost.floatCurrentMiniProgram();
  }

  Future<DiminaAskAiEvent?> fire(Map<Object?, Object?> args) async {
    await installHandler();
    final event = Completer<DiminaAskAiEvent?>();
    final sub = DiminaHost.askAiEvents.listen(event.complete);
    final ByteData message = const MethodChannel('dsh/dimina').codec.encodeMethodCall(MethodCall('onAskAi', args));
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
      'dsh/dimina',
      message,
      (_) {},
    );
    final result = await event.future.timeout(const Duration(seconds: 1), onTimeout: () => null);
    await sub.cancel();
    return result;
  }

  test('onAskAi 全量 payload 透传', () async {
    final event = await fire(<Object?, Object?>{
      'appId': 'wx-demo',
      'appName': '演示小程序',
      'pageTitle': '首页',
      'pagePath': 'pages/index/index',
    });
    expect(event?.appId, 'wx-demo');
    expect(event?.appName, '演示小程序');
    expect(event?.pageTitle, '首页');
    expect(event?.pagePath, 'pages/index/index');
  });

  test('onAskAi 页面信息缺省 → pageTitle/pagePath 容错成 null', () async {
    final event = await fire(<Object?, Object?>{'appId': 'wx-demo', 'appName': '演示小程序'});
    expect(event?.appId, 'wx-demo');
    expect(event?.appName, '演示小程序');
    expect(event?.pageTitle, isNull);
    expect(event?.pagePath, isNull);
  });

  test('onAskAi arguments 非 Map → 不发事件', () async {
    await installHandler();
    final events = <DiminaAskAiEvent>[];
    final sub = DiminaHost.askAiEvents.listen(events.add);
    final ByteData message = const MethodChannel('dsh/dimina').codec.encodeMethodCall(
      const MethodCall('onAskAi', 'not-a-map'),
    );
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
      'dsh/dimina',
      message,
      (_) {},
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await sub.cancel();
    expect(events, isEmpty);
  });

  test('floatCurrentMiniProgram 走 float 分支回传 bool', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'float');
      return true;
    });
    expect(await DiminaHost.floatCurrentMiniProgram(), isTrue);
  });

  test('floatCurrentMiniProgram 老原生 notImplemented → false 不抛', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async => null,
    );
    expect(await DiminaHost.floatCurrentMiniProgram(), isFalse);
  });
}
