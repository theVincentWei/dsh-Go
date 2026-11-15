// DiminaHost 权限通道(平台权限契约 v1 §6/§7)测试:
// - getPermissionState 透传 {supported, scopes:{scope:granted}};
// - setPermission 回传 bool(写容器 consent);
// - 容器 store 不可用(supported=false)与老原生 notImplemented 都降级:
//   permissionState → null / setPermission → false。
library;

import 'package:dsh_app/ui/applet/dimina/dimina_host.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel('dsh/dimina');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('permissionState 透传 supported+scopes(数据源=容器 consent)', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getPermissionState');
      expect((call.arguments as Map)['appId'], 'wx-audio-test');
      return <String, Object?>{
        'supported': true,
        'scopes': <String, Object?>{'scope.record': true, 'scope.notification': false},
      };
    });
    final Map<String, Object?>? state = await DiminaHost.permissionState('wx-audio-test');
    expect(state?['supported'], true);
    final Map<Object?, Object?> scopes = state?['scopes'] as Map<Object?, Object?>;
    expect(scopes['scope.record'], true);
    expect(scopes['scope.notification'], false);
  });

  test('容器 store 不可用 → supported=false 原样透传(UI 降级只读)', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      return <String, Object?>{'supported': false, 'scopes': <String, Object?>{}};
    });
    final Map<String, Object?>? state = await DiminaHost.permissionState('wx-old');
    expect(state?['supported'], false);
  });

  test('老原生没有 getPermissionState(notImplemented)→ null 不抛', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => null);
    expect(await DiminaHost.permissionState('wx-old'), isNull);
  });

  test('setPermission 回传 true(已写容器 store)', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'setPermission');
      final Map args = call.arguments as Map;
      expect(args['appId'], 'wx-audio-test');
      expect(args['scope'], 'scope.record');
      expect(args['granted'], false);
      return true;
    });
    expect(await DiminaHost.setPermission('wx-audio-test', 'scope.record', false), isTrue);
  });

  test('setPermission 写失败(store 不可用)→ false(UI 回滚开关)', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => false);
    expect(await DiminaHost.setPermission('wx-audio-test', 'scope.record', true), isFalse);
  });

  test('setPermission 老原生 notImplemented → false 不抛', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => null);
    expect(await DiminaHost.setPermission('wx-old', 'scope.record', true), isFalse);
  });
}
