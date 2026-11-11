// Measured alignment of the 聊天 tab's list (the former drawer): cards and
// filter capsules share the 16 line, 全选 and the count on the selection
// header's line, the action bar's keys on the 10 lines. Numbers, not
// eyeballing.
//
//   flutter test test/drawer/drawer_geometry_test.dart

import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/drawer_view_state.dart';
import 'package:dsh_app/state/session_attention_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/common/capsule_chip.dart';
import 'package:dsh_app/ui/shell/drawer/selection_bars.dart';
import 'package:dsh_app/ui/common/empty_view.dart';
import 'package:dsh_app/ui/shell/drawer/drawer_filter_bar.dart';
import 'package:dsh_app/ui/shell/drawer/folder_header.dart';
import 'package:dsh_app/ui/shell/drawer/folder_mark.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_app/ui/shell/session_list_page.dart';
import 'package:dsh_client/dsh_client.dart' show SessionSummary;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart';
import 'support.dart';

const _eps = 0.01;

Matcher _near(double v) => closeTo(v, _eps);

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  List<SessionSummary>? sessions,
  DrawerView view = sampleFolders,
  Map<String, PendingKind> pending = const {},
  double textScale = 1,
}) async {
  SharedPreferences.setMockInitialValues(storedView(view));
  usePhoneSurface(tester);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
    goldenApp(
      brightness: Brightness.light,
      // 列表已是聊天 tab 的整页；聊天页用替身，测的全是列表自己的几何。
      home: HomeShell(chatBuilder: const SizedBox.expand()),
      overrides: [
        localRuntimeProvider.overrideWith(
          () => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus)),
        ),
        sessionsProvider.overrideWith(() => FakeSessions(sessions ?? sampleSessions())),
        currentSessionProvider.overrideWith(() => FakeCurrentSession('s2')),
        pendingInteractionsProvider.overrideWith(() => FixedPending(pending)),
        unreadSessionIdsProvider.overrideWithValue(const {}),
      ],
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  return ProviderScope.containerOf(tester.element(find.byType(HomeShell)));
}

Rect _rect(WidgetTester tester, Finder finder) => tester.getRect(finder);

/// The 聊天 tab's page fills the Scaffold body (the bottom bar is its own).
Rect _page(WidgetTester tester) => _rect(tester, find.byType(SessionListPage));

void main() {
  group('folders', () {
    testWidgets('header on the row grid; members line up with the folder name', (tester) async {
      await _pump(tester);
      final page = _page(tester);
      final header = find.widgetWithText(DrawerFolderHeader, '工作');
      final headerRect = _rect(tester, header);
      final mark = _rect(tester, find.descendant(of: header, matching: find.byType(FolderMarkGlyph)));
      final name = _rect(tester, find.descendant(of: header, matching: find.text('工作')));
      final member = find.widgetWithText(SessionTile, '解释 proot 的 link2symlink');
      final memberAvatar = _rect(tester, find.descendant(of: member, matching: find.byKey(const ValueKey('session-avatar'))));
      // The card slice (the Ink) inside the tile: margins live outside it.
      final memberCard = _rect(tester, find.descendant(of: member, matching: find.byType(Ink)));
      final loose = find.widgetWithText(SessionTile, '修复登录按钮重复提交');
      final looseTitle = _rect(tester, find.descendant(of: loose, matching: find.text('修复登录按钮重复提交')));

      // Equal edges on the 16 lines; the folder's row stays 44 high, the
      // member rows are 64 (两行,设置行同款) and touch their group's edges.
      expect(headerRect.height, _near(DrawerFolderHeader.height));
      expect(memberCard.height, _near(SessionTile.height));
      expect(headerRect.left - page.left, _near(16));
      expect(page.right - headerRect.right, _near(16));
      expect(memberCard.left - page.left, _near(SessionTile.marginH));
      expect(page.right - memberCard.right, _near(SessionTile.marginH));
      // Mark on the header's inner 10 line; a member's avatar keeps the
      // folder's indent inside the card's 16 inner edge, and the title
      // follows the avatar.
      expect(mark.left - page.left, _near(26));
      expect(mark.center.dy, _near(headerRect.center.dy));
      expect(name.left - page.left, _near(26 + SessionTile.folderIndent));
      expect(memberAvatar.left - page.left, _near(SessionTile.marginH + SessionTile.innerH + SessionTile.folderIndent));
      expect(
        looseTitle.left - page.left,
        _near(SessionTile.marginH + SessionTile.innerH + SessionTile.avatarSize + SessionTile.avatarGap),
      );
    });

    testWidgets('a closed folder hides its members; opening reveals them', (tester) async {
      final container = await _pump(tester);
      expect(find.text('把 README 翻译成英文'), findsNothing);
      await tester.tap(find.widgetWithText(DrawerFolderHeader, '学习'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('把 README 翻译成英文'), findsOneWidget);
      expect(container.read(drawerViewProvider).byId('f2')!.collapsed, isFalse);
    });
  });

  group('filters', () {
    testWidgets('capsules start on the cards\' 16 line, equal height, 8 apart, one centre line', (tester) async {
      await _pump(tester);
      final page = _page(tester);
      final chips = [
        for (final f in DrawerFilter.values) _rect(tester, find.widgetWithText(CapsuleChoiceChip, f.label)),
      ];
      expect(chips.first.left - page.left, _near(SessionTile.marginH));
      for (var i = 1; i < chips.length; i++) {
        expect(chips[i].height, _near(chips.first.height));
        expect(chips[i].center.dy, _near(chips.first.center.dy));
        expect(chips[i].left - chips[i - 1].right, _near(DrawerFilterBar.gap));
      }
    });

    testWidgets('the 「对话列表」 key is a 34 circle ending on the 10 line', (tester) async {
      await _pump(tester);
      final page = _page(tester);
      final key = _rect(tester, find.byTooltip('对话列表'));
      expect(key.size, const Size.square(34));
      expect(page.right - key.right, _near(10));
    });

    testWidgets('360 wide at 1.3× text: nothing overflows', (tester) async {
      tester.view.physicalSize = const Size(360 * 2, 780 * 2);
      await _pump(tester, textScale: 1.3);
      expect(tester.takeException(), isNull);
    });
  });

  group('multi-select', () {
    testWidgets('全选 on the 20 line; the count centred on the page', (tester) async {
      final container = await _pump(tester);
      final page = _page(tester);
      container.read(drawerSelectionProvider.notifier).start('s2');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      final all = _rect(tester, find.descendant(of: find.byType(DrawerSelectionHeader), matching: find.text('全选')));
      expect(all.left - page.left, _near(20));
      final count = _rect(tester, find.text('已选 1 个'));
      expect(count.center.dx, _near(page.center.dx));
    });

    testWidgets('the check slides in on the 20 line; titles move one slot right', (tester) async {
      final container = await _pump(tester);
      final page = _page(tester);
      container.read(drawerSelectionProvider.notifier).start('s2');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      final loose = find.widgetWithText(SessionTile, '给设置页加深色模式');
      final title = _rect(tester, find.descendant(of: loose, matching: find.text('给设置页加深色模式')));
      expect(
        title.left - page.left,
        _near(
          SessionTile.marginH +
              SessionTile.innerH +
              SessionTile.checkSlot +
              SessionTile.avatarSize +
              SessionTile.avatarGap,
        ),
      );
      final member = find.widgetWithText(SessionTile, '解释 proot 的 link2symlink');
      final memberTitle = _rect(tester, find.descendant(of: member, matching: find.text('解释 proot 的 link2symlink')));
      expect(
        memberTitle.left - page.left,
        _near(
          SessionTile.marginH +
              SessionTile.innerH +
              SessionTile.folderIndent +
              SessionTile.checkSlot +
              SessionTile.avatarSize +
              SessionTile.avatarGap,
        ),
      );
    });

  });

  group('empty', () {
    // No folders either: since #230 a folder keeps the list (its long press
    // starts a chat in it) even with no conversations.
    testWidgets('no conversations: no filters, the empty view centred in the page', (tester) async {
      await _pump(tester, sessions: const [], view: const DrawerView(loaded: true));
      final page = _page(tester);
      expect(find.byType(CapsuleChoiceChip), findsNothing);
      final empty = _rect(tester, find.byType(EmptyView));
      expect(empty.center.dx, _near(page.center.dx));
    });
  });
}
