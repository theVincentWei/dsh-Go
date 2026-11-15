// 浮窗单球(2026-11-12,2026-11-15 方块毛玻璃+吸附直角形态)逻辑与交互测试:
// - Metrics 纯几何:定稿常量(56 方块/外露圆角 14/吸附阈值 48/图标 48+padding 4)
//   与 snapSide(松手吸附判定)/clampTop/yFractionFromTop/fullLeft/shapeFor;
// - floated 事件出球(默认右缘吸附)、foregrounded/destroyed 收球、单球顶替;
// - 松手距边<48dp 吸附(贴屏侧直角延伸到屏幕边缘)、距边≥48dp 停原地全圆角;
// - 吸附态/自由态点击都直接 DiminaHost.open 恢复(带原 appId/iconPng);
// - 缺图标渲染「星河双星」缺省图标。
library;

import 'dart:async';

import 'package:dsh_app/ui/applet/dimina/dimina_host.dart';
import 'package:dsh_app/ui/applet/dimina/float_ball.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const gestureKey = ValueKey('dimina_float_ball_gesture');
  const defaultIconKey = ValueKey('dimina_float_default_icon');

  group('DiminaFloatBallMetrics', () {
    test('定稿几何:56 方块/外露圆角 14/吸附阈值 48/图标 48+padding4/毛玻璃 sigma 5', () {
      expect(DiminaFloatBallMetrics.size, 56);
      expect(DiminaFloatBallMetrics.cornerOuter, 14);
      expect(DiminaFloatBallMetrics.snapThreshold, 48);
      expect(DiminaFloatBallMetrics.iconSize, 28);
      expect(DiminaFloatBallMetrics.iconPadding, 14);
      expect(DiminaFloatBallMetrics.iconCornerRadius, 7);
      expect(DiminaFloatBallMetrics.blurSigma, 5);
    });

    test('snapSide:距左/右屏缘<48 吸附该边,否则 null 停原地', () {
      expect(DiminaFloatBallMetrics.snapSide(0, 400), DiminaDockSide.left);
      expect(DiminaFloatBallMetrics.snapSide(10, 400), DiminaDockSide.left);
      expect(DiminaFloatBallMetrics.snapSide(400 - 56 - 10, 400), DiminaDockSide.right);
      // 恰好 48:不吸附(阈值是「小于」)。
      expect(DiminaFloatBallMetrics.snapSide(48, 400), isNull);
      expect(DiminaFloatBallMetrics.snapSide(400 - 56 - 48, 400), isNull);
      // 屏幕中间:自由停原地。
      expect(DiminaFloatBallMetrics.snapSide(100, 400), isNull);
      expect(DiminaFloatBallMetrics.snapSide(200, 400), isNull);
    });

    test('shapeFor:吸附态贴屏侧直角,自由/拖拽态全圆角', () {
      const outer = Radius.circular(DiminaFloatBallMetrics.cornerOuter);
      expect(
        DiminaFloatBallMetrics.shapeFor(side: DiminaDockSide.right, dragging: false),
        const BorderRadius.only(topLeft: outer, bottomLeft: outer),
      );
      expect(
        DiminaFloatBallMetrics.shapeFor(side: DiminaDockSide.left, dragging: false),
        const BorderRadius.only(topRight: outer, bottomRight: outer),
      );
      const full = BorderRadius.all(outer);
      expect(
        DiminaFloatBallMetrics.shapeFor(side: null, dragging: false),
        full,
        reason: '自由态全圆角',
      );
      expect(
        DiminaFloatBallMetrics.shapeFor(side: DiminaDockSide.right, dragging: true),
        full,
        reason: '拖拽中全圆角跟手',
      );
    });

    test('吸附 left:方块向屏外探 2dp(贴屏侧描边藏进屏幕外)', () {
      expect(DiminaFloatBallMetrics.fullLeft(DiminaDockSide.left, 400), -2);
      expect(DiminaFloatBallMetrics.fullLeft(DiminaDockSide.right, 400), 346);
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

    /// floated 一帧入树(pump 两帧:广播流事件微任务投递,首帧清不掉)。
    Future<void> pumpFloated(WidgetTester tester) async {
      events.add(DiminaFloatEvent(
        type: 'floated',
        appId: 'wx123',
        appName: '测试App',
        iconPng: png,
      ));
      await tester.pump();
      await tester.pump();
    }

    /// 默认右缘吸附的方块中心 y(62% 停靠位;测试 MediaQuery 无 padding)。
    double centerY(Size size) =>
        DiminaFloatBallMetrics.edgeGap +
        DiminaFloatBallMetrics.defaultYFraction *
            (size.height -
                DiminaFloatBallMetrics.size -
                DiminaFloatBallMetrics.edgeGap * 2) +
        DiminaFloatBallMetrics.size / 2;

    /// 右缘吸附时方块中心 x。
    double centerX(Size size) =>
        DiminaFloatBallMetrics.fullLeft(DiminaDockSide.right, size.width) +
        DiminaFloatBallMetrics.size / 2;

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
      expect(find.byKey(gestureKey), findsNothing);
    });

    testWidgets('floated 出球(默认右缘吸附,带图标),foregrounded 收球', (tester) async {
      await pumpHost(tester);
      await pumpFloated(tester);

      final size = MediaQuery.sizeOf(tester.element(find.byType(Scaffold)));
      expect(find.byKey(gestureKey), findsOneWidget);
      // 默认吸附右缘:方块与屏缘齐平。
      expect(
        tester.getTopLeft(find.byKey(gestureKey)).dx,
        DiminaFloatBallMetrics.fullLeft(DiminaDockSide.right, size.width),
      );
      // 吸附形态=贴屏侧直角。
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is DecoratedBox &&
              w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).borderRadius ==
                  DiminaFloatBallMetrics.shapeFor(
                    side: DiminaDockSide.right,
                    dragging: false,
                  ),
        ),
        findsWidgets,
      );

      events.add(const DiminaFloatEvent(type: 'foregrounded', appId: 'wx123'));
      await tester.pumpAndSettle();
      expect(find.byKey(gestureKey), findsNothing);
    });

    testWidgets('destroyed 收球;其它 app 的事件不动当前球', (tester) async {
      await pumpHost(tester);
      await pumpFloated(tester);
      expect(find.byKey(gestureKey), findsOneWidget);

      events.add(const DiminaFloatEvent(type: 'destroyed', appId: 'wx999'));
      await tester.pumpAndSettle();
      expect(find.byKey(gestureKey), findsOneWidget);

      events.add(const DiminaFloatEvent(type: 'destroyed', appId: 'wx123'));
      await tester.pumpAndSettle();
      expect(find.byKey(gestureKey), findsNothing);
    });

    testWidgets('单球:再次 floated 顶替当前球', (tester) async {
      await pumpHost(tester);
      await pumpFloated(tester);
      events.add(const DiminaFloatEvent(
        type: 'floated',
        appId: 'wx456',
        appName: '第二个',
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(gestureKey), findsOneWidget);

      // 顶替后 destroyed wx123 不收球,wx456 才收。
      events.add(const DiminaFloatEvent(type: 'destroyed', appId: 'wx123'));
      await tester.pumpAndSettle();
      expect(find.byKey(gestureKey), findsOneWidget);
      events.add(const DiminaFloatEvent(type: 'destroyed', appId: 'wx456'));
      await tester.pumpAndSettle();
      expect(find.byKey(gestureKey), findsNothing);
    });

    testWidgets('吸附态点击 → 直接 DiminaHost.open 带原 appId/图标并收球', (tester) async {
      await pumpHost(tester);
      await pumpFloated(tester);

      final size = MediaQuery.sizeOf(tester.element(find.byType(Scaffold)));
      await tester.tapAt(Offset(centerX(size), centerY(size)));
      await tester.pumpAndSettle();

      expect(openCalls, hasLength(1));
      expect(openCalls.single['appId'], 'wx123');
      expect(openCalls.single['name'], '测试App');
      expect(openCalls.single['iconPng'], png);
      expect(find.byKey(gestureKey), findsNothing);
    });

    testWidgets('鼠标指针点击吸附态 → 恢复小程序(真机/仿真器输入形态)', (tester) async {
      await pumpHost(tester);
      await pumpFloated(tester);

      final size = MediaQuery.sizeOf(tester.element(find.byType(Scaffold)));
      final gesture = await tester.startGesture(
        Offset(centerX(size), centerY(size)),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.up();
      await tester.pumpAndSettle();

      expect(openCalls, hasLength(1));
      expect(openCalls.single['appId'], 'wx123');
    });

    testWidgets('球刚出现立即点击 → 恢复小程序(真机时序)', (tester) async {
      await pumpHost(tester);
      await pumpFloated(tester);

      final size = MediaQuery.sizeOf(tester.element(find.byType(Scaffold)));
      await tester.tapAt(Offset(centerX(size), centerY(size)));
      await tester.pumpAndSettle();

      expect(openCalls, hasLength(1));
    });

    testWidgets('点击吸附方块贴屏侧边缘像素(瞄准抖动下界) → 恢复小程序', (tester) async {
      await pumpHost(tester);
      await pumpFloated(tester);

      final size = MediaQuery.sizeOf(tester.element(find.byType(Scaffold)));
      // 右缘吸附:方块左边缘 x = width - size。
      await tester.tapAt(Offset(
        DiminaFloatBallMetrics.fullLeft(DiminaDockSide.right, size.width),
        centerY(size),
      ));
      await tester.pumpAndSettle();

      expect(openCalls, hasLength(1));
    });

    testWidgets('松手距左缘<48dp → 吸附左缘(直角延伸),tap 直接恢复', (tester) async {
      await pumpHost(tester);
      await pumpFloated(tester);

      final size = MediaQuery.sizeOf(tester.element(find.byType(Scaffold)));
      // 从右缘吸附位拖到左缘附近:落点 left=10(<48)。
      final gesture = await tester.startGesture(Offset(centerX(size), centerY(size)));
      await gesture.moveBy(Offset(-(centerX(size) - 38), -10));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      // 吸附左缘:方块与屏缘齐平。
      expect(
        tester.getTopLeft(find.byKey(gestureKey)).dx,
        DiminaFloatBallMetrics.fullLeft(DiminaDockSide.left, size.width),
      );
      // 贴屏侧直角形状。
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is DecoratedBox &&
              w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).borderRadius ==
                  DiminaFloatBallMetrics.shapeFor(
                    side: DiminaDockSide.left,
                    dragging: false,
                  ),
        ),
        findsWidgets,
      );

      // 吸附态 tap 直接恢复(不再有弹回中间态)。
      final center = tester.getCenter(find.byKey(gestureKey));
      await tester.tapAt(center);
      await tester.pumpAndSettle();
      expect(openCalls, hasLength(1));
      expect(openCalls.single['appId'], 'wx123');
    });

    testWidgets('松手距边≥48dp → 自由停原地(全圆角),tap 直接恢复', (tester) async {
      await pumpHost(tester);
      await pumpFloated(tester);

      final size = MediaQuery.sizeOf(tester.element(find.byType(Scaffold)));
      // 拖到屏幕中间:落点 left=200(距左 200、距右 544,均 ≥48)。
      const freeLeft = 200.0;
      final gesture = await tester.startGesture(Offset(centerX(size), centerY(size)));
      await gesture.moveBy(Offset(-(centerX(size) - (freeLeft + DiminaFloatBallMetrics.size / 2)), -10));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      // 停在松手位置:纵向=松手位置(clamp 后),横向=落点。
      final topLeft = tester.getTopLeft(find.byKey(gestureKey));
      expect(topLeft.dx, freeLeft);
      // 全圆角形状。
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is DecoratedBox &&
              w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).borderRadius ==
                  DiminaFloatBallMetrics.shapeFor(side: null, dragging: false),
        ),
        findsWidgets,
      );

      // 自由态 tap 直接恢复。
      await tester.tapAt(tester.getCenter(find.byKey(gestureKey)));
      await tester.pumpAndSettle();
      expect(openCalls, hasLength(1));
      expect(openCalls.single['appId'], 'wx123');
    });

    testWidgets('缺图标 → 渲染星河双星缺省图标', (tester) async {
      await pumpHost(tester);
      events.add(const DiminaFloatEvent(
        type: 'floated',
        appId: 'wx1',
        appName: '星河',
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(gestureKey), findsOneWidget);
      expect(find.byKey(defaultIconKey), findsOneWidget);
    });
  });
}
