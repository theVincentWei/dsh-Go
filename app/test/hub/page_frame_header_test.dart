// AppPage 大标题高度首帧预算的测试(T4):首帧就用同款字形预算值,
// postFrame 实测校准时不再跳动 —— 桌面引擎包(hub_desktop)把内容首屏
// 高度对齐这个值,预算不准冷进会跳一下。

import 'package:dsh_app/ui/shell/page_frame.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart';

void main() {
  testWidgets('AppPage 首帧与实测校准后的内容位置一致(无跳动)', (tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(goldenApp(
      brightness: Brightness.light,
      home: AppPage.list(
        title: '标题预算',
        children: const <Widget>[Text('标记')],
      ),
    ));

    // 首帧渲染位置:postFrame 的实测 setState 已排队但未应用,读到的就是
    // 预算值撑起来的首帧(pumpWidget 之后不能先 pump,会把校准帧刷出来、
    // 量到假的首帧)。
    final Offset before = tester.getTopLeft(find.text('标记'));

    await tester.pumpAndSettle();
    final Offset after = tester.getTopLeft(find.text('标记'));
    expect(after, before);
  });

  testWidgets('带副标题的页同样无跳动', (tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(goldenApp(
      brightness: Brightness.light,
      home: AppPage.list(
        title: '标题预算',
        subtitle: const Text('一行副标题'),
        children: const <Widget>[Text('标记')],
      ),
    ));

    final Offset before = tester.getTopLeft(find.text('标记'));

    await tester.pumpAndSettle();
    final Offset after = tester.getTopLeft(find.text('标记'));
    expect(after, before);
  });
}
