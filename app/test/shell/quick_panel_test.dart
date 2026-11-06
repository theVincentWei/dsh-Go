// 快捷入口: a left swipe over the home tabs pulls it in from the right. Since
// the three-tab redesign the chat is a pushed page — an opaque route keeps the
// shell's own recognizer out of its hit chain — so the panel lives over the
// 聊天 / 小程序 / 设置 tabs; with a conversation selected it shows that one.
// Fingers move in small steps at Android's touch slop (8dp, what FlutterView
// reports), as on a phone: a single big move would cross every threshold at
// once and hide who claims the gesture first.
//
//   flutter test test/shell/quick_panel_test.dart

import 'dart:ui' show GestureSettings;

import 'package:dsh_app/state/adaptive_layout_state.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/quick_panel_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/render/code_block.dart';
import 'package:dsh_app/ui/engine/engine_screen.dart';
import 'package:dsh_app/ui/plugins/plugins_screen.dart';
import 'package:dsh_app/ui/remote/remote_screen.dart';
import 'package:dsh_app/ui/session/session_detail_page.dart';
import 'package:dsh_app/ui/settings/search/settings_search_page.dart';

import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_app/ui/shell/quick_panel.dart';
import 'package:dsh_app/ui/shell/session_list_page.dart';
import 'package:dsh_app/ui/web/local_web_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import '../chat/support/sample_chat.dart';
import 'adaptive/support.dart';

const _phone = Size(390, 844);

/// The panel on [_phone], with the conversation these tests have selected: all
/// it can have short of the 56 left over.
const _panelWidth = 334.0;

/// Android's touch slop in the view [useWindow] sets up (DPR 2).
void _androidSlop(WidgetTester tester) => tester.view.gestureSettings = const GestureSettings(physicalTouchSlop: 16);

ChatState _reply(String text) => ChatState(loading: false, items: [user(1, 'q'), assistant(2, text)]);

final _code = '```dart\n${'final longLine = "${'x' * 400}";\n' * 3}```';
final _table =
    '| ${List.generate(14, (i) => 'column number $i').join(' | ')} |\n'
    '|${' --- |' * 14}\n'
    '| ${List.generate(14, (i) => 'value $i').join(' | ')} |';

Future<void> _pump(
  WidgetTester tester, {
  Size size = _phone,
  LayoutPrefs prefs = const LayoutPrefs(loaded: true),
  String? reply,
}) async {
  useWindow(tester, size);
  _androidSlop(tester);
  mockClipboard(tester);
  await tester.pumpWidget(homeApp(prefs: prefs, chat: reply == null ? null : (_) => _reply(reply)));
  await pumpFrames(tester, 8);
}

/// Opens the conversation as the app does: a tap on its row in the 聊天 tab
/// selects it and pushes the chat page over the tabs. [instead] matches a
/// test's own chat stand-in (chatBuilder).
Future<void> _openChat(WidgetTester tester, {Finder? instead}) async {
  await tester.tap(find.byType(SessionTile).first);
  await pumpFrames(tester, 8);
  expect(instead ?? find.byType(ChatScreen), findsOneWidget);
}

/// A finger on its way: [steps] moves of [by], a frame each.
Future<void> _move(WidgetTester tester, TestGesture finger, Offset by, {int steps = 1}) async {
  for (var i = 0; i < steps; i++) {
    await finger.moveBy(by);
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// Down at [from], [steps] moves of [by], a pause (no fling), up, settled.
Future<void> _swipe(WidgetTester tester, Offset from, Offset by, {int steps = 40}) async {
  final finger = await tester.startGesture(from);
  await _move(tester, finger, by, steps: steps);
  await tester.pump(const Duration(milliseconds: 400));
  await finger.up();
  await pumpFrames(tester, 8);
}

/// The middle of the 聊天 tab's list on [_phone] — where the shell's own
/// translucent recognizer hears a sideways drag whatever the rows do.
const _chatsMiddle = Offset(195, 420);

Future<void> _swipeOpen(WidgetTester tester) => _swipe(tester, _chatsMiddle, const Offset(-6, 0));

Finder get _panel => find.byType(QuickPanel);
Finder _row(DrawerDestination d) => find.byKey(ValueKey('quick-panel-${d.name}'));

/// How far the panel's left edge has come in from the screen's right edge.
double _panelIn(WidgetTester tester) => tester.view.physicalSize.width / 2 - tester.getTopLeft(_panel).dx;

/// [_panelIn] with the finger [pulled] pixels along: the panel starts 24 past
/// the edge and arrives with the finger [_panelWidth] along.
double _inAfter(double pulled) => pulled / _panelWidth * (_panelWidth + 24) - 24;

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(HomeShell, skipOffstage: false)));

/// The horizontal scroll view holding [content].
ScrollPosition _scrollAround(WidgetTester tester, Finder content) => tester
    .stateList<ScrollableState>(find.ancestor(of: content, matching: find.byType(Scrollable)))
    .firstWhere((s) => s.axisDirection == AxisDirection.right)
    .position;

/// The horizontal scroll view inside [content].
ScrollPosition _scrollInside(WidgetTester tester, Finder content) => tester
    .stateList<ScrollableState>(find.descendant(of: content, matching: find.byType(Scrollable)))
    .firstWhere((s) => s.axisDirection == AxisDirection.right)
    .position;

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

  group('the swipe', () {
    testWidgets('left opens it, following the finger; the same finger pushes it back', (tester) async {
      await _pump(tester);
      expect(_panel, findsNothing);

      final finger = await tester.startGesture(_chatsMiddle);
      await _move(tester, finger, const Offset(-6, 0));
      expect(_panel, findsNothing, reason: 'nothing before real movement');
      await _move(tester, finger, const Offset(-6, 0), steps: 10);
      expect(_panelIn(tester), closeTo(_inAfter(66), 0.01), reason: 'all of it counts: no jump, no lost slop');

      await _move(tester, finger, const Offset(6, 0), steps: 5);
      expect(_panelIn(tester), closeTo(_inAfter(36), 0.01));

      // Reversing past closed stays closed: nothing else starts.
      await _move(tester, finger, const Offset(6, 0), steps: 15);
      expect(_panel, findsNothing);

      await tester.pump(const Duration(milliseconds: 400));
      await finger.up();
      await pumpFrames(tester, 8);
      expect(_panel, findsNothing);
    });

    testWidgets('past the middle it opens, short of it it falls back, a fling carries it', (tester) async {
      await _pump(tester);
      await _swipe(tester, _chatsMiddle, const Offset(-6, 0), steps: 12);
      expect(_panel, findsNothing);

      await _swipeOpen(tester);
      expect(_panel, findsOneWidget);
      expect(tester.getTopRight(_panel).dx, 390);
      expect(tester.getSize(_panel).width, _panelWidth);

      await _back(tester);
      await tester.fling(find.byType(HomeShell), const Offset(-80, 0), 1500);
      await pumpFrames(tester, 8);
      expect(_panel, findsOneWidget);
    });

    testWidgets('a fling settles it on the edge and never past', (tester) async {
      await _pump(tester);
      await tester.fling(find.byType(HomeShell), const Offset(-80, 0), 3000);
      await tester.pump();
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(_panelIn(tester), lessThanOrEqualTo(_panelWidth));
      }
      expect(_panelIn(tester), _panelWidth);
      await tester.fling(find.byType(HomeShell), const Offset(80, 0), 3000);
      await pumpFrames(tester, 8);
      expect(_panel, findsNothing);
    });

    testWidgets('open: right pushes it back, left keeps it', (tester) async {
      await _pump(tester);
      await _swipeOpen(tester);

      await _swipe(tester, const Offset(300, 420), const Offset(-4, 0), steps: 10);
      expect(_panelIn(tester), _panelWidth);

      await _swipe(tester, const Offset(300, 420), const Offset(8, 0));
      expect(_panel, findsNothing);
    });

    testWidgets('the system taking the finger away is no fling: it goes by how far it came', (tester) async {
      await _pump(tester);
      // [TestGesture] stamps every event zero unless told: real times, or no speed to measure.
      var time = Duration.zero;
      Future<void> pull(int steps) async {
        final finger = await tester.startGesture(_chatsMiddle);
        for (var i = 0; i < steps; i++) {
          time += const Duration(milliseconds: 16);
          await finger.moveBy(const Offset(-24, 0), timeStamp: time);
          await tester.pump(const Duration(milliseconds: 16));
        }
        await finger.cancel(timeStamp: time);
        await pumpFrames(tester, 8);
      }

      // Fast, and leftwards: it would have flung open.
      await pull(3);
      expect(_panel, findsNothing);

      await pull(8);
      expect(_panelIn(tester), _panelWidth);
    });

    testWidgets('a tap on the scrim closes it', (tester) async {
      await _pump(tester);
      await _swipeOpen(tester);
      await tester.tapAt(const Offset(40, 420));
      await pumpFrames(tester, 8);
      expect(_panel, findsNothing);
    });

    testWidgets('a tap goes through, even with a little jitter to the left', (tester) async {
      await _pump(tester);
      final row = tester.getCenter(find.byType(SessionTile).first);
      final finger = await tester.startGesture(row);
      await _move(tester, finger, const Offset(-3, 1));
      await finger.up();
      await pumpFrames(tester, 8);
      // Under the slop: the row's tap, not a drag — the chat page is pushed.
      expect(find.byType(ChatScreen), findsOneWidget);
      expect(_panel, findsNothing);
    });

    testWidgets('a vertical scroll stays the chat\'s, drifting left on the way', (tester) async {
      await _pump(tester, reply: List.filled(60, 'A long paragraph of reply text.').join('\n\n'));
      await _openChat(tester);
      // 消息列表在推入的聊天页里；定位它自己的竖向 Scrollable。
      final list = tester
          .stateList<ScrollableState>(find.descendant(of: find.byType(ChatScreen), matching: find.byType(Scrollable)))
          .firstWhere((s) => s.axisDirection == AxisDirection.up || s.axisDirection == AxisDirection.down)
          .position;
      final before = list.pixels;
      await _swipe(tester, _chatsMiddle, const Offset(-2, 12), steps: 15);
      expect(list.pixels, isNot(before));
      expect(_panel, findsNothing);
    });
  });

  group('what has a sideways swipe of its own keeps it', () {
    // At Android's slop and at Flutter's default one: the scroller waits for
    // the same distance either way. The chat is a pushed page now — the
    // shell's recognizer never competes over it — so this pins the scrollers
    // themselves still working under the same fingers.
    for (final android in [true, false]) {
      final slop = android ? 'Android slop' : 'default slop';

      testWidgets('a long code block ($slop)', (tester) async {
        await _pump(tester, reply: _code);
        await _openChat(tester);
        if (!android) tester.view.resetGestureSettings();
        await tester.pump();
        final block = find.byType(CodeBlock);
        final code = _scrollInside(tester, block);
        final from = tester.getCenter(block);

        final finger = await tester.startGesture(from);
        await _move(tester, finger, const Offset(-6, 0), steps: 20);
        expect(code.pixels, greaterThan(90));

        // Back the same way: still the code.
        final moved = code.pixels;
        await _move(tester, finger, const Offset(6, 0), steps: 5);
        expect(code.pixels, lessThan(moved));
        await finger.up();
        await pumpFrames(tester, 8);
        expect(_panel, findsNothing);
      });

      if (android) {
        // A move landing exactly on the slop: neither claims it yet, and the
        // next one goes to the code, which hears it first.
        testWidgets('a long code block, moves the size of the slop', (tester) async {
          await _pump(tester, reply: _code);
          await _openChat(tester);
          final block = find.byType(CodeBlock);
          final code = _scrollInside(tester, block);
          await _swipe(tester, tester.getCenter(block), const Offset(-8, 0), steps: 10);
          expect(code.pixels, greaterThan(60));
        });
      }

      testWidgets('a wide table ($slop)', (tester) async {
        await _pump(tester, reply: _table);
        await _openChat(tester);
        if (!android) tester.view.resetGestureSettings();
        await tester.pump();
        final cell = find.textContaining('column number 0', findRichText: true).first;
        final table = _scrollAround(tester, cell);
        expect(table.maxScrollExtent, greaterThan(100));

        await _swipe(tester, tester.getCenter(cell), const Offset(-6, 0), steps: 20);
        expect(table.pixels, greaterThan(90));
      });
    }

    testWidgets('any sideways drag under the finger, not only a scroll view', (tester) async {
      useWindow(tester, _phone);
      _androidSlop(tester);
      var dragged = 0.0;
      await tester.pumpWidget(
        testApp(
          HomeShell(
            // 推入聊天页的替身：一条自己的横向拖动。
            chatBuilder: Center(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragUpdate: (d) => dragged += d.delta.dx,
                child: const SizedBox(key: ValueKey('scrubber'), width: 300, height: 120),
              ),
            ),
          ),
          overrides: homeOverrides(),
        ),
      );
      await pumpFrames(tester, 8);
      await _openChat(tester, instead: find.byKey(const ValueKey('scrubber')));
      await _swipe(tester, tester.getCenter(find.byKey(const ValueKey('scrubber'))), const Offset(-6, 0), steps: 20);
      expect(dragged, lessThan(-90));
      expect(_panel, findsNothing);
    });

    testWidgets('对话详情 on a phone is a page of its own: its tabs keep the swipe', (tester) async {
      await _pump(tester);
      await _openChat(tester);
      SessionDetailPage.open(tester.element(find.byType(ChatScreen)), 's1');
      await pumpFrames(tester, 8);
      final tab = _container(tester).read(sessionDetailTabProvider);
      await _swipe(tester, const Offset(300, 420), const Offset(-8, 0), steps: 30);
      expect(_container(tester).read(sessionDetailTabProvider), isNot(tab));
      expect(_panel, findsNothing);
    });
  });

  group('back and the window', () {
    testWidgets('back closes the panel first; the app stays', (tester) async {
      await _pump(tester);
      await _swipeOpen(tester);
      await _back(tester);
      expect(_panel, findsNothing);
      expect(find.byType(HomeShell), findsOneWidget);
    });

    testWidgets('on its side, it covers the inset and its content keeps clear of it', (tester) async {
      useWindow(tester, const Size(780, 390), right: 40);
      _androidSlop(tester);
      mockClipboard(tester);
      await tester.pumpWidget(homeApp());
      await pumpFrames(tester, 8);
      await _swipe(tester, const Offset(400, 200), const Offset(-8, 0));
      expect(tester.getSize(_panel).width, QuickPanel.conversationWidth + 40);
      expect(tester.getTopRight(_panel).dx, 780);
      expect(tester.getTopRight(_row(DrawerDestination.plugins)).dx, lessThanOrEqualTo(740));
      expect(tester.takeException(), isNull);
    });
  });

  group('the rows', () {
    testWidgets('an install that never chose anything: 插件, 本机引擎, 设置, in that order', (tester) async {
      await _pump(tester);
      await _swipeOpen(tester);
      final rows = QuickPanelPrefs.defaultItems.map(_row).toList();
      for (final row in rows) {
        expect(row, findsOneWidget);
      }
      expect(tester.getTopLeft(rows[0]).dx, lessThan(tester.getTopLeft(rows[1]).dx));
      expect(tester.getTopLeft(rows[1]).dx, lessThan(tester.getTopLeft(rows[2]).dx));
      // 底栏三连胶囊的 tab 也带同名 Tooltip:把匹配收进面板里。
      expect(find.descendant(of: _panel, matching: find.byTooltip('插件')), findsOneWidget);
      expect(find.descendant(of: _panel, matching: find.byTooltip('本机引擎')), findsOneWidget);
      expect(find.descendant(of: _panel, matching: find.byTooltip('设置')), findsOneWidget);
      for (final other in [
        DrawerDestination.web,
        DrawerDestination.remote,
        DrawerDestination.settingsSearch,
        DrawerDestination.features,
      ]) {
        expect(_row(other), findsNothing);
      }
    });

    // 非 tab 的目的地仍推入整页；退出后回到聊天 tab（shell 现状不随推入收面板）。
    final pages = <DrawerDestination, Type>{
      DrawerDestination.web: LocalWebScreen,
      DrawerDestination.remote: RemoteScreen,
      DrawerDestination.plugins: PluginsScreen,
      DrawerDestination.engine: EngineScreen,
      DrawerDestination.settingsSearch: SettingsSearchPage,
    };
    for (final MapEntry(key: destination, value: page) in pages.entries) {
      testWidgets('${destination.name} opens its page; back lands on the chats tab', (tester) async {
        SharedPreferences.setMockInitialValues({
          QuickPanelController.itemsKey: [destination.name],
        });
        await _pump(tester);
        await _swipeOpen(tester);
        await tester.tap(_row(destination));
        await pumpFrames(tester, 8);
        expect(find.byType(page), findsOneWidget);

        tester.state<NavigatorState>(find.byType(Navigator).first).pop();
        await pumpFrames(tester, 8);
        expect(find.byType(page), findsNothing);
        expect(find.byType(HomeShell), findsOneWidget);
        // 面板在推入页面时未收起（见交付报告的待拍板项），这里不断言它。
      });
    }

    testWidgets('settings and 小程序 are tabs now: the bar switches, and the panel rides along', (tester) async {
      SharedPreferences.setMockInitialValues({
        QuickPanelController.itemsKey: [DrawerDestination.settings.name, DrawerDestination.features.name],
      });
      await _pump(tester);
      await _swipeOpen(tester);
      // 自定义三连胶囊没有 NavigationBar.selectedIndex 可读：选中态看图标
      // 着色（选中 primary，未选中 onSurfaceVariant）。面板开着时快捷键的
      // 同名 Tooltip 也在树上，homeTabIcon 按 tab 的 22 尺寸取到底栏那颗。
      final scheme = Theme.of(tester.element(find.byType(HomeShell))).colorScheme;

      await tester.tap(_row(DrawerDestination.features));
      await pumpFrames(tester, 8);
      expect(homeTabIcon(tester, '小程序').color, scheme.primary);
      expect(homeTabIcon(tester, '聊天').color, scheme.onSurfaceVariant);
      await tester.tap(_row(DrawerDestination.settings));
      await pumpFrames(tester, 8);
      expect(homeTabIcon(tester, '设置').color, scheme.primary);

      // 换 tab 不关面板；退回聊天 tab 走既有返回顺序（先关面板）。
      await tester.tapAt(const Offset(40, 420));
      await pumpFrames(tester, 8);
      expect(_panel, findsNothing);
      await _back(tester);
      expect(homeTabIcon(tester, '聊天').color, scheme.primary);
    });

    testWidgets('ids no destination answers to are dropped, repeats too; the order holds', (tester) async {
      SharedPreferences.setMockInitialValues({
        QuickPanelController.itemsKey: ['settings', 'gone', 'dshgo://open/settings', 'web', 'settings'],
      });
      await _pump(tester);
      await _swipeOpen(tester);
      final rows = tester
          .widgetList(
            find.descendant(
              of: _panel,
              matching: find.byWidgetPredicate(
                (w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('quick-panel-'),
              ),
            ),
          )
          .map((w) => (w.key! as ValueKey<String>).value)
          .toList();
      expect(rows, ['quick-panel-settings', 'quick-panel-web']);
    });
  });

  group('turned off', () {
    testWidgets('by the switch: the swipe goes to whatever is under it, as before', (tester) async {
      SharedPreferences.setMockInitialValues({QuickPanelController.swipeKey: false});
      await _pump(tester);
      await _swipe(tester, _chatsMiddle, const Offset(-6, 0));
      expect(_panel, findsNothing);
    });

    testWidgets('with nothing chosen: the conversation is still there to show, without shortcuts', (tester) async {
      SharedPreferences.setMockInitialValues({QuickPanelController.itemsKey: <String>[]});
      await _pump(tester);
      await _swipeOpen(tester);
      expect(_panel, findsOneWidget);
      for (final destination in DrawerDestination.values) {
        expect(_row(destination), findsNothing);
      }
    });

    testWidgets('while it is open: it goes at once', (tester) async {
      await _pump(tester);
      await _swipeOpen(tester);
      await _container(tester).read(quickPanelProvider.notifier).setSwipe(false);
      await pumpFrames(tester, 2);
      expect(_panel, findsNothing);
    });

    testWidgets('and on again, the swipe works without a restart', (tester) async {
      SharedPreferences.setMockInitialValues({QuickPanelController.swipeKey: false});
      await _pump(tester);
      await _container(tester).read(quickPanelProvider.notifier).setSwipe(true);
      await pumpFrames(tester, 2);
      await _swipeOpen(tester);
      expect(_panel, findsOneWidget);
    });
  });
}
