// Regression tests for the bottom bar's tabs: cold-start restore keeps the
// highlight capsule on the restored tab (后台杀掉再进,页面在恢复的 tab、胶囊
// 却停在第一格的脱钩), and the tab cells respond to taps without an ink
// ripple (点按反馈只有高亮胶囊的流动,2026-11-11 拍板去掉水波).
//
//   flutter test test/shell/home_tab_restore_test.dart

import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'golden_harness.dart';

List<Override> _homeOverrides() => [
  localRuntimeProvider.overrideWith(
    () => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus)),
  ),
  sessionsProvider.overrideWith(() => FakeSessions(sampleSessions())),
  currentSessionProvider.overrideWith(() => FakeCurrentSession('s2')),
];

/// The tab strip's highlight capsule: one DecoratedBox with the stadium of
/// the flowing pill (_TabGlow), tinted with the theme's primary.
Finder _pill(ColorScheme scheme) => find.byWidgetPredicate(
  (w) =>
      w is DecoratedBox &&
      w.decoration is BoxDecoration &&
      (w.decoration as BoxDecoration).borderRadius == BorderRadius.circular(22) &&
      (w.decoration as BoxDecoration).color == scheme.primary.withValues(alpha: 0.18),
);

Future<void> _pumpShell(WidgetTester tester, {Map<String, Object> prefs = const {}}) async {
  SharedPreferences.setMockInitialValues(prefs);
  usePhoneSurface(tester);
  await tester.pumpWidget(
    goldenApp(home: HomeShell(chatBuilder: const SizedBox.expand()), brightness: Brightness.light, overrides: _homeOverrides()),
  );
  // _restoreTab's prefs round trip lands on a later frame; let the shell
  // settle (the restore's page jump included).
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('cold start on the settings tab: pill and page both land there', (tester) async {
    await _pumpShell(tester, prefs: {'home.tab': 2});

    // The page really is the third tab (that part worked before the fix).
    final pageController = tester.widget<PageView>(find.byType(PageView)).controller!;
    expect(pageController.page, 2);

    // The highlight capsule sits on the third slot of the strip: without the
    // fix it stayed on the first slot (the animation's from position) and
    // nothing ever moved it.
    final scheme = Theme.of(tester.element(find.byType(HomeShell))).colorScheme;
    final pill = _pill(scheme);
    expect(pill, findsOneWidget);
    final strip = tester.getRect(find.ancestor(of: pill, matching: find.byType(GlassSurface)).first);
    final pillRect = tester.getRect(pill);
    final slot = strip.width / 3;
    expect(pillRect.left - strip.left, closeTo(2 * slot + 6, 1.0));
    expect(pillRect.width, closeTo(slot - 12, 1.0));
  });

  testWidgets('tab cells still switch on tap, without an ink ripple', (tester) async {
    await _pumpShell(tester);

    // The strip's glass holds the three tab cells; the device key's glass is
    // a sibling, not a descendant, so a descendant InkWell can only be a tab
    // cell's ripple.
    final strip = find.ancestor(of: find.byIcon(AppIcons.settings), matching: find.byType(GlassSurface)).first;
    expect(find.descendant(of: strip, matching: find.byType(InkWell)), findsNothing);

    // Tapping a tab still switches: the page follows and the pill lands on
    // the tapped cell.
    await tester.tap(find.byIcon(AppIcons.settings));
    await tester.pumpAndSettle();
    expect(tester.widget<PageView>(find.byType(PageView)).controller!.page, 2);
    final scheme = Theme.of(tester.element(find.byType(HomeShell))).colorScheme;
    final stripRect = tester.getRect(strip);
    final pillRect = tester.getRect(_pill(scheme));
    final slot = stripRect.width / 3;
    expect(pillRect.left - stripRect.left, closeTo(2 * slot + 6, 1.0));
  });
}
