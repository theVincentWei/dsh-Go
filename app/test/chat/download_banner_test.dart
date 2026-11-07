// 横条:显示任务名与百分比;取消按钮把任务标记取消并出列。

import 'package:dsh_app/state/download_tasks.dart';
import 'package:dsh_app/ui/chat/widgets/download_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('无活动下载时不占布局', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: MaterialApp(home: Scaffold(body: DownloadTasksBanner()))));
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('显示任务名与进度,取消即出列', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(downloadTasksProvider.notifier);
    final task = controller.begin(key: 'k', label: '报表.pdf', total: 100);
    controller.progress(key: 'k', received: 50);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: DownloadTasksBanner())),
      ),
    );
    expect(find.text('报表.pdf'), findsOneWidget);
    expect(find.text('50%'), findsOneWidget);
    expect(task.cancelled, isFalse);

    await tester.tap(find.byIcon(Icons.close));
    expect(task.cancelled, isTrue);
    expect(container.read(downloadTasksProvider), isEmpty);
  });
}
