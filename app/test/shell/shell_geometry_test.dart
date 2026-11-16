// Measured alignment of the shell's chrome: the 聊天 tab's 10 / 20 grid, the
// secondary-page bar, the search header, the sheet header and the onboarding
// step bar. Numbers, not eyeballing.
//
//   flutter test test/shell/shell_geometry_test.dart

import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/common/app_sheet.dart';
import 'package:dsh_app/ui/onboarding/onboarding_scaffold.dart';
import 'package:dsh_app/ui/onboarding/runtime_setup_page.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_app/ui/shell/page_frame.dart';
import 'package:dsh_app/ui/shell/session_list_page.dart';
import 'package:dsh_app/ui/shell/session_search_page.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'golden_harness.dart';

const _eps = 0.01;

Matcher _near(double v) => closeTo(v, _eps);

/// Secondary pages are pushed pages: a blank page underneath keeps
/// `Navigator.canPop` true, so [AppPage] renders its back key.
Widget _pushed(Widget page) => Navigator(
  onPopPage: (route, result) {
    if (!route.didPop(result)) return false;
    return true;
  },
  pages: [
    MaterialPage<void>(child: const SizedBox.shrink()),
    MaterialPage<void>(child: page),
  ],
);

Future<void> _pumpChats(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  usePhoneSurface(tester);
  await tester.pumpWidget(
    goldenApp(
      home: HomeShell(chatBuilder: const SizedBox.expand()),
      brightness: Brightness.light,
      overrides: [
        localRuntimeProvider.overrideWith(
          () => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus)),
        ),
        settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
        sessionsProvider.overrideWith(() => FakeSessions(sampleSessions())),
        currentSessionProvider.overrideWith(() => FakeCurrentSession('s2')),
      ],
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

void main() {
  group('chats tab', () {
    testWidgets('cards on the 16 line, avatar on the 16 inner line, keys end on the 10 line', (tester) async {
      await _pumpChats(tester);
      final page = tester.getRect(find.byType(SessionListPage));
      // The list no longer insets its rows: each card slice carries its own
      // 16 margins, so the visual card is the Ink inside the tile.
      final first = find.byType(SessionTile).first;
      final tile = tester.getRect(find.descendant(of: first, matching: find.byType(Ink)).first);
      final avatar = tester.getRect(find.descendant(of: first, matching: find.byKey(const ValueKey('session-avatar'))));
      final title = tester.getRect(find.text('修复登录按钮重复提交'));
      final key = tester.getRect(find.byTooltip('对话列表'));

      expect(tile.left - page.left, _near(SessionTile.marginH));
      expect(page.right - tile.right, _near(SessionTile.marginH));
      expect(tile.height, _near(SessionTile.height));
      // The avatar sits on the card's 16 inner line; the title follows it.
      expect(avatar.left - page.left, _near(SessionTile.marginH + SessionTile.innerH));
      expect(avatar.size, const Size.square(SessionTile.avatarSize));
      expect(title.left - avatar.right, _near(SessionTile.avatarGap));
      // The title row's 「对话列表」 round key ends where the cards do.
      expect(page.right - key.right, _near(10));
      expect(key.size, const Size.square(34));
    });
  });

  group('secondary page bar', () {
    testWidgets('back button 12 from the edge, 44 round, title on the large-title line', (tester) async {
      usePhoneSurface(tester);
      await tester.pumpWidget(
        goldenApp(
          brightness: Brightness.light,
          home: _pushed(
            AppPage.list(
              title: '示例',
              children: [for (var i = 0; i < 40; i++) SizedBox(height: 48, child: Text('行 $i'))],
            ),
          ),
        ),
      );
      await tester.pump();
      final screen = tester.getRect(find.byType(AppPage));
      final back = tester.getRect(find.byType(GlassIconButton));
      expect(back.left - screen.left, _near(12));
      expect(back.size, const Size(44, 44));
      expect(back.top, _near(32 + 6)); // status bar + (56 - 44) / 2
      final titles = find.text('示例');
      expect(titles, findsNWidgets(2));
      // The large title starts on the 24 line, where the back glyph sits.
      final large = tester.getRect(titles.first);
      expect(large.left, _near(24));
      // The bar title is centred on the screen.
      final bar = tester.getRect(titles.last);
      expect(bar.center.dx, _near(screen.center.dx));
    });
  });

  testWidgets('secondary page with two actions keeps its title centred', (tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        brightness: Brightness.light,
        home: _pushed(
          AppPage.list(
            title: '两个操作',
            actions: [
              GlassIconButton(icon: AppIcons.search, tooltip: '查找', onPressed: () {}),
              GlassIconButton(icon: AppIcons.more, tooltip: '更多', onPressed: () {}),
            ],
            children: [for (var i = 0; i < 30; i++) SizedBox(height: 60, child: Text('行 $i'))],
          ),
        ),
      ),
    );
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
    await tester.pumpAndSettle();
    final screen = tester.getRect(find.byType(AppPage));
    final title = tester.getRect(find.text('两个操作').last);
    final back = tester.getRect(find.byTooltip('返回'));
    final search = tester.getRect(find.byTooltip('查找'));
    final more = tester.getRect(find.byTooltip('更多'));
    expect(title.center.dx, closeTo(screen.center.dx, 0.5));
    expect(more.left - search.right, _near(8));
    expect(screen.right - more.right, _near(12));
    for (final button in [back, search, more]) {
      expect(button.size, const Size(44, 44));
      expect(button.center.dy, _near(back.center.dy));
    }
  });

  testWidgets('search header: 12 on both sides, field as tall as the back button and level with it', (tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(goldenApp(brightness: Brightness.light, home: const SessionSearchPage()));
    await tester.pump();
    final screen = tester.getRect(find.byType(SessionSearchPage));
    final back = tester.getRect(find.byType(GlassIconButton));
    final field = tester.getRect(find.ancestor(of: find.byType(TextField), matching: find.byType(GlassSurface)).first);
    expect(back.left - screen.left, _near(12));
    expect(screen.right - field.right, _near(12));
    expect(field.height, _near(back.height));
    expect(field.center.dy, _near(back.center.dy));
  });

  testWidgets('sheet header: one handle and a title with mirrored 20 gutters', (tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        brightness: Brightness.light,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showAppSheet<void>(
                  context,
                  builder: (_) => const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SheetHeader('切换主机'),
                      SheetGroup(children: [ListTile(title: Text('本机'))]),
                    ],
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final sheet = tester.getRect(find.byType(SheetHeader));
    final title = tester.getRect(find.text('切换主机'));
    final group = tester.getRect(find.descendant(of: find.byType(SheetGroup), matching: find.byType(GlassSurface)));
    expect(title.left - sheet.left, _near(kSheetGutter));
    expect(sheet.right - title.right, _near(kSheetGutter));
    expect(find.byType(SheetIconButton), findsNothing);
    expect(find.byType(SheetDragHandle), findsOneWidget);
    // Default groups in a sheet follow the same gutter.
    expect(group.left - sheet.left, _near(kSheetGutter));
    expect(sheet.right - group.right, _near(kSheetGutter));
  });

  testWidgets('onboarding step bar is centred on the screen', (tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        brightness: Brightness.light,
        home: OnboardingProgress(step: 1, steps: 2, child: RuntimeSetupPage(onDone: () {})),
        overrides: [
          localRuntimeProvider.overrideWith(
            () => FakeRuntime(
              const LocalRuntimeState(
                loaded: true,
                status: RuntimeStatus(phase: RuntimePhase.installing, bundledVersion: 'r1'),
              ),
            ),
          ),
        ],
      ),
    );
    await tester.pump();
    final screen = tester.getRect(find.byType(RuntimeSetupPage));
    final bar = tester.getRect(find.byType(OnboardingStepBar));
    expect(bar.center.dx, _near(screen.center.dx));
    expect(bar.width, _near(OnboardingStepBar.width));
  });
}
