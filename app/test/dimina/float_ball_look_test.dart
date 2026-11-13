// 浮窗球外观金样生成器(2026-11-13,给用户看球的实际长相):
//   flutter test test/dimina/float_ball_look_test.dart --update-goldens
// 产出 test/dimina/goldens/ball_docked_right.png(贴右停靠) /
// ball_dragging.png(拖拽整圆) / ball_docked_left.png(吸附左缘)。
// 用真实 DiminaFloatBall widget 渲染,几何与线上完全一致。
library;

import 'dart:async';

import 'package:dsh_app/ui/applet/dimina/dimina_host.dart';
import 'package:dsh_app/ui/applet/dimina/float_ball.dart';
import 'package:dsh_app/ui/applet/dimina/glyph_raster.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('浮窗球外观三态:贴右停靠 / 拖拽整圆 / 吸附左缘', (tester) async {
    // 1080x2400 @3x,与真机同尺寸,golden 直接是手机分辨率。
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    // 栅格化走真实异步光栅线程,widget 测试的 FakeAsync 区外才能完成。
    final png = await tester.runAsync(() => rasterizeGlyphPng('star'));
    final events = StreamController<DiminaFloatEvent>.broadcast();

    Widget host() => MaterialApp(
          debugShowCheckedModeBanner: false,
          home: DiminaFloatBall(
            events: events.stream,
            child: Scaffold(
              backgroundColor: const Color(0xFF14161B),
              appBar: AppBar(
                title: const Text('Mini apps'),
                backgroundColor: const Color(0xFF1B1E26),
              ),
              body: ListView(
                children: List.generate(
                  6,
                  (i) => Container(
                    margin: const EdgeInsets.all(12),
                    height: 96,
                    decoration: BoxDecoration(
                      color: const Color(0xFF232732),
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

    await tester.pumpWidget(host());
    // Image.memory 的解码是真实异步:先 precache 进缓存,金样里图标才已上屏。
    await tester.runAsync(() async {
      if (png != null) {
        await precacheImage(Image.memory(png).image, tester.element(find.byType(Scaffold)));
      }
    });
    events.add(DiminaFloatEvent(
      type: 'floated',
      appId: 'wx1',
      appName: '待办提醒',
      iconPng: png,
    ));
    await tester.pumpAndSettle();

    // 1) 贴边停靠(默认右缘,可动区 62% 高度处):半胶囊,贴边平直、外侧半圆。
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/ball_docked_right.png'),
    );

    // 2) 拖拽中:整圆跟手(手指按住未松开时截帧)。
    //    球心压在屏幕边上,手势从露出的内半圆起拖(几何中心恰在屏幕边界)。
    final start = tester.getCenter(
          find.byKey(const ValueKey('dimina_float_ball_gesture')),
        ) -
        const Offset(DiminaFloatBallMetrics.radius, 0);
    final gesture = await tester.startGesture(start);
    await gesture.moveBy(const Offset(-260, -160));
    // 第一帧派发手势事件(onPanStart/Update 才执行),第二帧走完 150ms 形变。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/ball_dragging.png'),
    );

    // 3) 松手:中点过屏幕中线 → 动画吸附到左缘。
    await gesture.up();
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/ball_docked_left.png'),
    );
    events.close();
  });
}
