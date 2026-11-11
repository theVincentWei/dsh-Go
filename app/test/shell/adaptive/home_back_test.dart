// Back on the home screen: multi-select in the 聊天 tab's list ends first and
// the tab stays; from another tab back returns to 聊天; on 聊天 with nothing
// selected there is nothing to pop into — the app stays (leaving it is the
// system's back-exit flow). The sidebar variant is gone with the drawer.
//
//   flutter test test/shell/adaptive/home_back_test.dart

import 'package:dsh_app/state/drawer_view_state.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../chat/support/harness.dart';
import 'support.dart';

ProviderContainer _container(WidgetTester tester) => ProviderScope.containerOf(tester.element(find.byType(HomeShell)));

Future<void> _back(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await pumpFrames(tester, 6);
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    freezeClocks();
  });
  tearDown(thawClocks);

  testWidgets('phone: back ends multi-select, the tab stays', (tester) async {
    useWindow(tester, const Size(390, 844));
    mockClipboard(tester);
    await tester.pumpWidget(homeApp());
    await pumpFrames(tester, 6);

    _container(tester).read(drawerSelectionProvider.notifier).start('s2');
    await pumpFrames(tester, 2);
    await _back(tester);
    expect(_container(tester).read(drawerSelectionProvider), isNull);
    expect(find.byType(HomeShell), findsOneWidget);
  });

  testWidgets('from another tab back returns to 聊天; with nothing selected the app stays', (tester) async {
    useWindow(tester, const Size(390, 844));
    mockClipboard(tester);
    await tester.pumpWidget(homeApp());
    await pumpFrames(tester, 6);
    final scheme = Theme.of(tester.element(find.byType(HomeShell))).colorScheme;

    // 底栏切到 设置；返回键退回 聊天 tab。（IndexedStack 里挂载着的
    // SettingsScreen 也有「设置」字样，tab 一律按 Tooltip 找；选中态看图标
    // 着色：选中 primary，未选中 onSurfaceVariant。）
    expect(homeTabIcon(tester, '设置').color, scheme.onSurfaceVariant);
    await tester.tap(find.byTooltip('设置'));
    await pumpFrames(tester, 4);
    expect(homeTabIcon(tester, '设置').color, scheme.primary);
    expect(homeTabIcon(tester, '聊天').color, scheme.onSurfaceVariant);
    await _back(tester);
    expect(homeTabIcon(tester, '聊天').color, scheme.primary);

    // 聊天 tab 上没有多选、没有面板：没有可退的东西，应用不动（系统退出
    // 流程归系统）。
    await _back(tester);
    expect(find.byType(HomeShell), findsOneWidget);
    expect(homeTabIcon(tester, '聊天').color, scheme.primary);
  });
}
