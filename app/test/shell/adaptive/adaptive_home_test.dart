// TODO(golden): 底部三 tab 改版后需在有 Flutter 的机器上 flutter test --update-goldens 重录
// The home screen on an open foldable (720 × 900): the 聊天 tab at rest, the
// conversation pushed over it, 对话详情 as the two-height sheet, measured
// against the sheet's own 20; goldens in light and dark. The tablet rail /
// sidebar / panel layout went away with the drawer in the three-tab redesign.
// Regenerate with
//
//   flutter test --update-goldens test/shell/adaptive/adaptive_home_test.dart

import 'package:dsh_app/state/adaptive_layout_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/session/session_detail_page.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_app/ui/shell/session_list_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../chat/support/harness.dart';
import 'support.dart';

const _medium = Size(720, 900);

const _eps = 0.01;
Matcher _near(double v) => closeTo(v, _eps);

Rect _key(WidgetTester tester, String key) => tester.getRect(find.byKey(ValueKey(key)));

Future<void> _pumpHome(
  WidgetTester tester, {
  Size size = _medium,
  double right = 0,
  double left = 0,
  Brightness brightness = Brightness.light,
  LayoutPrefs prefs = const LayoutPrefs(loaded: true),
  String? session = 's1',
}) async {
  useWindow(tester, size, left: left, right: right);
  mockClipboard(tester);
  await tester.pumpWidget(homeApp(brightness: brightness, prefs: prefs, session: session));
  // Keep the initial 800 ms, coalescing only its later frames. The gesture,
  // route and panel-transition pumps below remain unchanged.
  await pumpFrames(tester, 2);
  await tester.pump(const Duration(milliseconds: 600));
}

/// Opens the conversation: a tap on its row in the 聊天 tab pushes the chat.
Future<void> _openChat(WidgetTester tester) async {
  await tester.tap(find.byType(SessionTile).first);
  await pumpFrames(tester, 8);
  expect(find.byType(ChatScreen), findsOneWidget);
}

Future<void> _openSheet(WidgetTester tester, {bool full = false}) async {
  SessionDetailPage.open(tester.element(find.byType(ChatScreen)), 's1');
  await pumpFrames(tester, 8);
  if (full) {
    await tester.tap(find.bySemanticsLabel('展开'));
    await pumpFrames(tester, 8);
  }
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    freezeClocks();
  });
  tearDown(thawClocks);

  testWidgets('at rest it is the 聊天 tab; the chat is not on screen', (tester) async {
    await _pumpHome(tester);
    expect(tester.takeException(), isNull);
    expect(find.byType(SessionTile), findsWidgets);
    expect(find.byType(ChatScreen), findsNothing);
    // 底栏三连胶囊（自定义件，无 NavigationBar）：聊天选中（primary 圆底配
    // primary 图标），另两颗未选中（onSurfaceVariant 图标）。
    final scheme = Theme.of(tester.element(find.byType(HomeShell))).colorScheme;
    expect(homeTabIcon(tester, '聊天').color, scheme.primary);
    expect(homeTabIcon(tester, '小程序').color, scheme.onSurfaceVariant);
    expect(homeTabIcon(tester, '设置').color, scheme.onSurfaceVariant);
  });

  testWidgets('the pushed chat hides the ≡ key and back returns to the tab', (tester) async {
    await _pumpHome(tester);
    // On the tab there is no chat header at all.
    expect(find.byKey(const ValueKey('chat-menu')), findsNothing);
    await _openChat(tester);
    // onOpenDrawer == null (the chat is a pushed page): the ≡ key goes away.
    expect(find.byKey(const ValueKey('chat-menu')), findsNothing);
    expect(find.byKey(const ValueKey('chat-title-pill')), findsOneWidget);

    await tester.binding.handlePopRoute();
    await pumpFrames(tester, 8);
    expect(find.byType(ChatScreen), findsNothing);
    expect(find.byType(SessionTile), findsWidgets);
  });

  group('720 × 900, the wide sheet', () {
    testWidgets('half the window, title and tabs on the sheet\'s 20', (tester) async {
      final semantics = tester.ensureSemantics();
      await _pumpHome(tester);
      await _openChat(tester);
      await _openSheet(tester);
      final sheet = _key(tester, 'detail-sheet');
      expect(sheet, const Rect.fromLTWH(0, 450, 720, 450));
      final title = tester.getRect(find.text('对话详情'));
      expect(title.left - sheet.left, _near(20));
      final segments = tester.getRect(find.byType(GlassSegments));
      expect(segments.left - sheet.left, _near(20));
      expect(sheet.right - segments.right, _near(20));
      await tester.tap(find.bySemanticsLabel('展开'));
      await pumpFrames(tester, 8);
      expect(_key(tester, 'detail-sheet').top, _near(statusBar + 12));
      semantics.dispose();
    });
  });

  for (final brightness in Brightness.values) {
    final mode = brightness == Brightness.dark ? 'dark' : 'light';
    group('goldens ($mode)', () {
      testWidgets('medium_sheet', (tester) async {
        await _pumpHome(tester, brightness: brightness);
        await _openChat(tester);
        await _openSheet(tester);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/medium_sheet_$mode.png'));
      });

      testWidgets('medium_sheet_full', (tester) async {
        final semantics = tester.ensureSemantics();
        await _pumpHome(tester, brightness: brightness);
        await _openChat(tester);
        await _openSheet(tester, full: true);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/medium_sheet_full_$mode.png'));
        semantics.dispose();
      });
    });
  }
}
