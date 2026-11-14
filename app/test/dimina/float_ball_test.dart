// 浮窗单球(2026-11-12)逻辑与交互测试:
// - Metrics 纯几何:snapSide/clampTop/yFractionFromTop;
// - floated 事件出球、foregrounded/destroyed 收球、单球顶替;
// - 点击球 → DiminaHost.open 带原 appId/iconPng(容器原地恢复链路)。
library;

import 'dart:async';

import 'package:dsh_app/ui/applet/dimina/dimina_host.dart';
import 'package:dsh_app/ui/applet/dimina/float_ball.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DiminaFloatBallMetrics', () {
    test('snapSide: 中点落左半吸附左边,右半吸附右边', () {
      expect(DiminaFloatBallMetrics.snapSide(100, 400), DiminaDockSide.left);
      expect(DiminaFloatBallMetrics.snapSide(300, 400), DiminaDockSide.right);
    });

    test('clampTop 限制在上下界内', () {
      expect(DiminaFloatBallMetrics.clampTop(-5, 8, 300), 8);
      expect(DiminaFloatBallMetrics.clampTop(500, 8, 300), 300);
      expect(DiminaFloatBallMetrics.clampTop(150, 8, 300), 150);
    });

    test('yFractionFromTop: travel<=0 落默认值,正常区间归一化', () {
      expect(
        DiminaFloatBallMetrics.yFractionFromTop(0, 8, 0),
        DiminaFloatBallMetrics.defaultYFraction,
      );
      expect(DiminaFloatBallMetrics.yFractionFromTop(8, 8, 400), 0.0);
      expect(DiminaFloatBallMetrics.yFractionFromTop(408, 8, 400), 1.0);
      expect(DiminaFloatBallMetrics.yFractionFromTop(208, 8, 400), 0.5);
    });
  });

  group('DiminaFloatBall widget', () {
    late StreamController<DiminaFloatEvent> events;
    final Uint8List png = Uint8List.fromList([1, 2, 3]);
    final List<Map<Object?, Object?>> openCalls = [];

    Future<void> pumpHost(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: DiminaFloatBall(
            events: events.stream,
            child: const Scaffold(body: SizedBox.expand()),
          ),
        ),
      );
      await tester.pump();
    }

    setUp(() {
      events = StreamController<DiminaFloatEvent>.broadcast();
      openCalls.clear();
      const channel = MethodChannel('dsh/dimina');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'open') {
          openCalls.add(call.arguments as Map<Object?, Object?>);
        }
        return true;
      });
    });

    tearDown(() {
      events.close();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('dsh/dimina'), null);
    });

    testWidgets('无事件不渲染球', (tester) async {
      await pumpHost(tester);
      expect(find.byKey(const ValueKey('dimina_float_ball_gesture')), findsNothing);
    });

    testWidgets('floated 出球(带图标),foregrounded 收球', (tester) async {
      await pumpHost(tester);
      events.add(DiminaFloatEvent(
        type: 'floated',
        appId: 'wx123',
        appName: '测试App',
        iconPng: png,
      ));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('dimina_float_ball_gesture')),
        findsOneWidget,
      );

      events.add(const DiminaFloatEvent(type: 'foregrounded', appId: 'wx123'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('dimina_float_ball_gesture')),
        findsNothing,
      );
    });

    testWidgets('destroyed 收球;其它 app 的事件不动当前球', (tester) async {
      await pumpHost(tester);
      events.add(DiminaFloatEvent(
        type: 'floated',
        appId: 'wx123',
        appName: '测试App',
        iconPng: png,
      ));
      await tester.pumpAndSettle();

      events.add(const DiminaFloatEvent(type: 'destroyed', appId: 'wx999'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('dimina_float_ball_gesture')),
        findsOneWidget,
      );

      events.add(const DiminaFloatEvent(type: 'destroyed', appId: 'wx123'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('dimina_float_ball_gesture')),
        findsNothing,
      );
    });

    testWidgets('单球:再次 floated 顶替当前球', (tester) async {
      await pumpHost(tester);
      events.add(DiminaFloatEvent(
        type: 'floated',
        appId: 'wx123',
        appName: '测试App',
        iconPng: png,
      ));
      await tester.pumpAndSettle();
      events.add(DiminaFloatEvent(
        type: 'floated',
        appId: 'wx456',
        appName: '第二个',
        iconPng: png,
      ));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('dimina_float_ball_gesture')),
        findsOneWidget,
      );

      // 顶替后 destroyed wx123 不收球,wx456 才收。
      events.add(const DiminaFloatEvent(type: 'destroyed', appId: 'wx123'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('dimina_float_ball_gesture')),
        findsOneWidget,
      );
      events.add(const DiminaFloatEvent(type: 'destroyed', appId: 'wx456'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('dimina_float_ball_gesture')),
        findsNothing,
      );
    });

    testWidgets('点击球 → DiminaHost.open 带原 appId/图标并收球', (tester) async {
      await pumpHost(tester);
      events.add(DiminaFloatEvent(
        type: 'floated',
        appId: 'wx123',
        appName: '测试App',
        iconPng: png,
      ));
      await tester.pumpAndSettle();

      // 停靠球球心压在屏幕边上:点击露出的内半圆中心(屏宽-半圆深度)。
      final size = MediaQuery.sizeOf(tester.element(find.byType(Scaffold)));
      final centerY = DiminaFloatBallMetrics.edgeGap +
          DiminaFloatBallMetrics.defaultYFraction *
              (size.height -
                  DiminaFloatBallMetrics.height -
                  DiminaFloatBallMetrics.edgeGap * 2) +
          DiminaFloatBallMetrics.radius;
      await tester.tapAt(Offset(
        size.width - DiminaFloatBallMetrics.dockedWidth / 2,
        centerY,
      ));
      await tester.pumpAndSettle();

      expect(openCalls, hasLength(1));
      expect(openCalls.single['appId'], 'wx123');
      expect(openCalls.single['name'], '测试App');
      expect(openCalls.single['iconPng'], png);
      expect(
        find.byKey(const ValueKey('dimina_float_ball_gesture')),
        findsNothing,
      );
    });
  });
}
