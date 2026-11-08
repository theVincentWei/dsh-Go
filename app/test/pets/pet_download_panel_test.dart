// 下载通知中心面板:行内容(名字/进度)、点行回跳参数、取消按钮。

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/download_tasks.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/pets/pet_download_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late ProviderContainer container;
  late DownloadTasksController tasks;

  setUp(() {
    container = ProviderContainer();
    addTearDown(container.dispose);
    tasks = container.read(downloadTasksProvider.notifier);
  });

  Future<void> pumpPanel(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: DownloadTasksPanel(
              onOpen: _noopOpen,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('列出任务:名字、百分比、取消即出列', (tester) async {
    final a = tasks.begin(
      key: 'k1',
      label: '季度报告.pdf',
      host: HostRef.ssh('box'),
      sessionId: 's1',
      total: 100,
    );
    tasks.begin(key: 'k2', label: '素材包.zip', host: HostRef.ssh('box'), sessionId: 's1', total: 200);
    tasks.progress(key: 'k1', received: 62);
    tasks.progress(key: 'k2', received: 30);
    await pumpPanel(tester);

    expect(find.text('季度报告.pdf'), findsOneWidget);
    expect(find.text('62%'), findsOneWidget);
    expect(find.text('素材包.zip'), findsOneWidget);
    expect(find.text('15%'), findsOneWidget);

    await tester.tap(find.byTooltip(appL10n.updateCancelDownload).first);
    expect(a.cancelled, isTrue);
    expect(container.read(downloadTasksProvider).map((t) => t.key), ['k2']);
  });

  test('container.listen 对任务表变更触发回调', () async {
    final log = <List<DownloadTask>>[];
    final sub = container.listen(downloadTasksProvider, (_, next) => log.add(next));
    addTearDown(sub.close);
    tasks.begin(key: 'x', label: 'l', host: HostRef.ssh('b'), sessionId: 's');
    await Future<void>.delayed(Duration.zero);
    expect(log, hasLength(1), reason: 'begin 必须通知监听者');
    tasks.progress(key: 'x', received: 5);
    await Future<void>.delayed(Duration.zero);
    expect(log, hasLength(2), reason: 'progress 必须通知监听者');
  });

  testWidgets('点行回跳:带回任务的 host 与会话', (tester) async {
    final opened = <(HostRef, String)>[];
    tasks.begin(key: 'k1', label: '季度报告.pdf', host: HostRef.ssh('box'), sessionId: 's1', total: 10);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: DownloadTasksPanel(
              onOpen: (host, sessionId) => opened.add((host, sessionId)),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('季度报告.pdf'));
    expect(opened, [const (HostRef.ssh('box'), 's1')]);
    expect(container.read(downloadTasksProvider), hasLength(1), reason: '跳转不取消任务');
  });
}

Future<void> _noopOpen(HostRef host, String sessionId) async {}
