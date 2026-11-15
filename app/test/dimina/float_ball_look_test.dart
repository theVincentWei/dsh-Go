// 浮窗球外观金样生成器(2026-11-15 吸附直角+闲置半藏定稿,给用户看球的实际长相):
//   flutter test test/dimina/float_ball_look_test.dart --update-goldens
// 产出 test/dimina/goldens/ball_docked_right.png(吸附右缘,贴屏侧直角延伸) /
// ball_half_hidden.png(吸附闲置 4s 自动半藏,露一半图标) /
// ball_dragging.png(拖拽浅白全圆角) / ball_docked_left.png(吸附左缘镜像) /
// ball_free.png(自由态原地全圆角)。
// 用真实 DiminaFloatBall widget 渲染,几何与线上完全一致。
library;

import 'dart:async';

import 'package:dsh_app/ui/applet/dimina/dimina_host.dart';
import 'package:dsh_app/ui/applet/dimina/float_ball.dart';
import 'package:dsh_app/ui/applet/dimina/glyph_raster.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('浮窗球外观四态:吸附右缘 / 拖拽浅白 / 吸附左缘 / 自由原地', (tester) async {
    // 半藏态点击会走 _restore→DiminaHost.open(MethodChannel),mock 掉原生侧。
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('dsh/dimina'), (call) async => true);
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

    // 1) 吸附右缘(默认可动区 62% 高度处):贴屏侧直角、方块延伸到屏幕边缘,
    //    外露侧圆角 14,毛玻璃底、图标 28dp 居中(四周 6dp,方块 40dp)。
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/ball_docked_right.png'),
    );

    // 1.5) 吸附闲置 4s → 自动半藏:方块探出屏外一半,露一半图标(贴屏侧仍无线)。
    await tester.pump(const Duration(seconds: 4, milliseconds: 100));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/ball_half_hidden.png'),
    );
    // 半藏态点击直接恢复(不做二次点击):球消失。
    // 半藏时方块一半在屏外,getCenter 恰在屏缘线上 → 往屏内偏 14dp 打可见区中心。
    final halfCenter = tester.getCenter(
      find.byKey(const ValueKey('dimina_float_ball_gesture')),
    );
    await tester.tapAt(Offset(halfCenter.dx - 14, halfCenter.dy));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('dimina_float_ball_gesture')), findsNothing);

    // 重新 floated 一颗球,继续后续拖拽流程。
    events.add(DiminaFloatEvent(
      type: 'floated',
      appId: 'wx1',
      appName: '待办提醒',
      iconPng: png,
    ));
    await tester.pumpAndSettle();

    // 2) 拖拽中:整块跟手并变浅白(手指按住未松开时截帧)。
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('dimina_float_ball_gesture'))),
    );
    await gesture.moveBy(const Offset(-260, -160));
    // 第一帧派发手势事件(onPanStart/Update 才执行),第二帧走完 150ms 变色。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/ball_dragging.png'),
    );

    // 3) 松手:落点距左缘 <48dp → 动画吸附左缘(贴屏侧直角镜像)。
    await gesture.up();
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/ball_docked_left.png'),
    );

    // 4) 再拖回屏幕中间松手:距两边均 ≥48dp → 自由停原地,全圆角。
    final freeGesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('dimina_float_ball_gesture'))),
    );
    // 屏宽 360(逻辑):拖到 left≈124(距左 124、距右 180,均 ≥48)。
    await freeGesture.moveBy(const Offset(140, 0));
    await tester.pump();
    await freeGesture.up();
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/ball_free.png'),
    );
    events.close();
  });
}
