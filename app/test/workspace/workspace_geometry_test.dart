// Measured symmetry of the workspace chrome: the 聊天 tab's workspace sheet
// cards and the browser's bottom button mirrored. (The drawer's switcher row
// and its 10 / 20 grid went away with the drawer; breadcrumb capsules are
// checked in their own group.)
//
//   flutter test test/workspace/workspace_geometry_test.dart

import 'package:dsh_app/ui/common/breadcrumb_row.dart';
import 'package:dsh_app/ui/common/list_page_row.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_app/ui/workspace/directory_picker.dart';
import 'package:dsh_app/ui/workspace/workspace_switcher.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart';
import 'support.dart';

const _eps = 0.01;

Matcher _near(double v) => closeTo(v, _eps);

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _pumpList(WidgetTester tester) async {
  usePhoneSurface(tester);
  await tester.pumpWidget(
    goldenApp(
      home: HomeShell(chatBuilder: const SizedBox.expand()),
      brightness: Brightness.light,
      overrides: workspaceOverrides(sampleWorkspaceHost()),
    ),
  );
  await _settle(tester);
}

void main() {
  group('breadcrumbs', () {
    testWidgets('capsules: equal insets, one height, one centre line; first on the page gutter', (tester) async {
      usePhoneSurface(tester);
      await tester.pumpWidget(
        goldenApp(
          home: const DirectoryBrowserPage(start: '/root/code/dsh-app'),
          brightness: Brightness.light,
          overrides: workspaceOverrides(sampleWorkspaceHost()),
        ),
      );
      await _settle(tester);
      final capsules = find.byType(BreadcrumbCapsule);
      expect(capsules, findsNWidgets(3));
      final rects = [for (var i = 0; i < 3; i++) tester.getRect(capsules.at(i))];
      for (var i = 0; i < 3; i++) {
        final text = tester.getRect(find.descendant(of: capsules.at(i), matching: find.byType(Text)));
        expect(text.left - rects[i].left, _near(BreadcrumbCapsule.inset));
        expect(rects[i].right - text.right, _near(BreadcrumbCapsule.inset));
        expect(rects[i].height, _near(BreadcrumbRow.height));
        expect(rects[i].center.dy, _near(rects[0].center.dy));
      }
      // Separators: the same gap between every pair.
      expect(rects[1].left - rects[0].right, _near(rects[2].left - rects[1].right));
      final card = tester.getRect(
        find.descendant(of: find.byType(ListPageCard), matching: find.byType(GlassSurface)).first,
      );
      expect(rects[0].left, _near(card.left));
      expect(card.top - rects.last.bottom, _near(12));
      expect(rects[0].left, _near(16));

      // The bottom button mirrors the card.
      final button = tester.getRect(find.byType(FilledButton));
      expect(button.left, _near(card.left));
      expect(tester.view.physicalSize.width / tester.view.devicePixelRatio - button.right, _near(button.left));
    });
  });

  group('switcher sheet', () {
    testWidgets('cards 20 in on both sides; rows share the glyph column', (tester) async {
      await _pumpList(tester);
      await tester.tap(find.byTooltip('工作区')); // 标题行的「工作区」圆键。
      await _settle(tester);
      final sheet = tester.getRect(find.byType(WorkspaceSheet));
      final cards = find.descendant(of: find.byType(WorkspaceSheet), matching: find.byType(GlassSurface));
      expect(cards, findsWidgets);
      for (var i = 0; i < tester.widgetList(cards).length; i++) {
        final r = tester.getRect(cards.at(i));
        expect(r.left - sheet.left, _near(20));
        expect(sheet.right - r.right, _near(20));
      }
      final rows = find.descendant(of: find.byType(WorkspaceSheet), matching: find.byType(ListPageRow));
      final glyphLefts = {
        for (var i = 0; i < tester.widgetList(rows).length; i++)
          tester.getRect(find.descendant(of: rows.at(i), matching: find.byType(Icon)).first).left.toStringAsFixed(2),
      };
      expect(glyphLefts, hasLength(1));
    });
  });
}
