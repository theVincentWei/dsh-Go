// The in-app half: banner over any page, tap routing (notification or banner),
// and the "is the chat on screen" signal (lib/ui/notify/chat_alert_host.dart).

import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/bots_state.dart';
import 'package:dsh_app/state/chat_reveal_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/notify_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:dsh_app/ui/common/discard_guard.dart';
import 'package:dsh_app/ui/notify/chat_alert_host.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import '../shell/golden_harness.dart' as shell;
import 'support.dart';

class _Local extends LocalConnectionController {
  _Local(this.connection);

  final HostConnection connection;

  @override
  Future<HostConnection?> build() async => connection;
}

/// The drawer's workspace switcher would open a socket on the fake host.
class _Workspaces extends WorkspacesController {
  @override
  WorkspacesState build() => const WorkspacesState();
}

class _Sessions extends SessionsController {
  @override
  Future<List<SessionSummary>> build() async => const [];

  @override
  Future<void> archive(String sessionId) async {
    ref.read(currentSessionProvider.notifier).select(null);
    state = const AsyncData([]);
  }
}

void main() {
  late FakeNotifyChannel channel;
  late FakeAlertSource source;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    channel = FakeNotifyChannel();
    source = FakeAlertSource()..sessions = [session('s1', title: '修复登录按钮'), session('s2', title: '深色模式')];
  });

  Future<ProviderContainer> pumpHome(
    WidgetTester tester, {
    NotifySystemStatus? system,
    Widget? page,
    bool chatOpen = false,
  }) async {
    if (system != null) channel.system = system;
    final conn = fakeHostConnection();
    await tester.pumpWidget(
      testApp(
        chatOpen
            // 会话被打开时 shell 推入的全屏聊天页替身，用文字断言它在最前。
            ? HomeShell(chatBuilder: const Scaffold(body: Center(child: Text('聊天页替身'))))
            : Scaffold(
                body: Builder(
                  builder: (context) => Column(
                    children: [
                      const ChatAlertHost(),
                      TextButton(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => page ?? const Scaffold(body: Center(child: Text('设置页'))),
                          ),
                        ),
                        child: const Text('打开设置'),
                      ),
                    ],
                  ),
                ),
              ),
        overrides: [
          localRuntimeProvider.overrideWith(StaticRuntime.new),
          settingsProvider.overrideWith(() => shell.FakeSettings(const AppSettings(loaded: true))),
          sessionsProvider.overrideWith(_Sessions.new),
          workspacesProvider.overrideWith(_Workspaces.new),
          dsBotApiFactoryProvider.overrideWithValue((_) => null),
          notifyChannelProvider.overrideWithValue(channel),
          alertSourceFactoryProvider.overrideWithValue((_) => source),
          alertTimingProvider.overrideWithValue((announce: Duration.zero, reconcile: const Duration(seconds: 1))),
          localConnectionProvider.overrideWith(() => _Local(conn)),
          activeConnectionProvider.overrideWithValue(AsyncData(conn)),
        ],
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    return ProviderScope.containerOf(tester.element(find.byType(ChatAlertHost)));
  }

  Future<void> openPage(WidgetTester tester) async {
    await tester.tap(find.text('打开设置'));
    await tester.pumpAndSettle();
    expect(find.text('设置页'), findsOneWidget);
  }

  testWidgets('a pushed page means the chat is not on screen', (tester) async {
    final container = await pumpHome(tester);
    expect(container.read(chatOnScreenProvider), isTrue);
    await openPage(tester);
    expect(container.read(chatOnScreenProvider), isFalse);
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    expect(container.read(chatOnScreenProvider), isTrue);
  });

  testWidgets('the reveal request opens the conversation over the tabs', (tester) async {
    await pumpHome(tester, chatOpen: true);
    expect(find.text('聊天页替身'), findsNothing);
    final container = ProviderScope.containerOf(tester.element(find.byType(HomeShell)));
    container.read(chatRevealProvider.notifier).request();
    await tester.pumpAndSettle();
    expect(find.text('聊天页替身'), findsOneWidget);
  });

  testWidgets('a notification tap pops back to the chat and opens the session', (tester) async {
    final container = await pumpHome(tester);
    await openPage(tester);
    channel.tapController.add(const NotifyTap(host: HostRef.local, sessionId: 's2', kind: 'done'));
    await tester.pumpAndSettle();
    expect(find.text('设置页'), findsNothing);
    expect(container.read(currentSessionProvider), 's2');
    expect(container.read(activeHostProvider), HostRef.local);
  });

  testWidgets('升级完成告知的点击只把 app 带回前台，不开会话', (tester) async {
    final container = await pumpHome(tester);
    await openPage(tester);
    channel.tapController.add(const NotifyTap(host: HostRef.local, sessionId: 'wxapp', kind: 'update'));
    await tester.pumpAndSettle();
    // 不跳页、不弹「离开未保存表单」、不路由会话(契约 §6.4)。
    expect(find.text('设置页'), findsOneWidget);
    expect(container.read(currentSessionProvider), isNull);
  });

  testWidgets('the banner shows over a pushed page and opens its conversation', (tester) async {
    final container = await pumpHome(tester);
    await openPage(tester);
    source.emit(approval('e1', 's1'));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('修复登录按钮'), findsOneWidget);
    expect(find.text('等你确认：运行命令'), findsOneWidget);

    await tester.tap(find.text('修复登录按钮'));
    await tester.pumpAndSettle();
    expect(find.text('设置页'), findsNothing);
    expect(container.read(currentSessionProvider), 's1');
    expect(find.text('等你确认：运行命令'), findsNothing);
    expect(channel.cancelledGroups, contains('local:local|s1'));
  });

  testWidgets('the banner hides by itself after a few seconds', (tester) async {
    await pumpHome(tester);
    source.outcomes['s2'] = outcome(9, 'completed', reply: '好了');
    source.emit(const SessionStatusEvent('s2', true));
    source.emit(const SessionStatusEvent('s2', false));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('已完成 · 好了'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(find.text('已完成 · 好了'), findsNothing);
    expect(channel.shown, isEmpty, reason: 'foreground: banner only');
  });

  testWidgets('swiping the banner up dismisses it', (tester) async {
    await pumpHome(tester);
    source.emit(question('q1', 's1', ['用哪个数据库？']));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('问你：用哪个数据库？'), findsOneWidget);
    await tester.drag(find.text('问你：用哪个数据库？'), const Offset(0, -80));
    await tester.pumpAndSettle();
    expect(find.text('问你：用哪个数据库？'), findsNothing);
  });

  testWidgets('通知先确认：取消保留表单、主机和对话，放弃才切换', (tester) async {
    final text = TextEditingController();
    addTearDown(text.dispose);
    final container = await pumpHome(
      tester,
      page: DiscardGuard(
        listenable: text,
        isDirty: () => text.text.isNotEmpty,
        child: Scaffold(
          body: Column(
            children: [
              const Text('设置页'),
              TextField(controller: text),
            ],
          ),
        ),
      ),
    );
    await openPage(tester);
    await tester.enterText(find.byType(TextField), '草稿');
    final beforeSession = container.read(currentSessionProvider);
    final beforeHost = container.read(activeHostProvider);
    const target = HostRef.ssh('lab');
    channel.tapController.add(const NotifyTap(host: target, sessionId: 's2', kind: 'done'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
    expect(find.text('设置页'), findsOneWidget);
    expect(text.text, '草稿');
    expect(container.read(currentSessionProvider), beforeSession);
    expect(container.read(activeHostProvider), beforeHost);
    channel.tapController.add(const NotifyTap(host: target, sessionId: 's2', kind: 'done'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('放弃'));
    await tester.pumpAndSettle();
    expect(find.text('设置页'), findsNothing);
    expect(container.read(currentSessionProvider), 's2');
    expect(container.read(activeHostProvider), target);
  });

  testWidgets('普通 PopScope 不拦截横幅回首页', (tester) async {
    final container = await pumpHome(
      tester,
      page: const PopScope(
        canPop: false,
        child: Scaffold(body: Center(child: Text('设置页'))),
      ),
    );
    await openPage(tester);
    source.emit(approval('e1', 's1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('修复登录按钮'));
    await tester.pumpAndSettle();
    expect(find.text('放弃修改？'), findsNothing);
    expect(find.text('设置页'), findsNothing);
    expect(container.read(currentSessionProvider), 's1');
  });

  /// 抽屉删除后「会话被打开」的唯一可见信号：shell 推入了聊天页替身。
  bool chatOpen(WidgetTester tester) => find.text('聊天页替身').evaluate().isNotEmpty;

  testWidgets('横幅打开对话后推入聊天页', (tester) async {
    final container = await pumpHome(tester, chatOpen: true);
    expect(chatOpen(tester), isFalse);
    source.emit(approval('e1', 's1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('修复登录按钮'));
    await tester.pumpAndSettle();
    expect(chatOpen(tester), isTrue);
    expect(container.read(currentSessionProvider), 's1');
  });

  testWidgets('系统通知直接推入聊天页', (tester) async {
    final container = await pumpHome(tester, chatOpen: true);
    channel.tapController.add(const NotifyTap(host: HostRef.local, sessionId: 's2', kind: 'done'));
    // The handler runs across a few microtask hops (discard check → select →
    // reveal), so let the push land before asserting.
    await tester.pumpAndSettle();
    expect(chatOpen(tester), isTrue);
    expect(container.read(currentSessionProvider), 's2');
  });

  testWidgets('切换主机和归档当前对话不推入聊天页', (tester) async {
    final container = await pumpHome(tester, chatOpen: true);
    container.read(activeHostProvider.notifier).select(const HostRef.ssh('lab'));
    await tester.pumpAndSettle();
    expect(chatOpen(tester), isFalse);
    container.read(currentSessionProvider.notifier).select('s1');
    await container.read(sessionsProvider.notifier).archive('s1');
    await tester.pumpAndSettle();
    expect(chatOpen(tester), isFalse);
  });

  testWidgets('横幅读屏提供点按和关闭动作', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpHome(tester);
    source.emit(approval('e1', 's1'));
    await tester.pumpAndSettle();
    expect(
      tester.getSemantics(find.byType(AlertBanner)),
      matchesSemantics(
        label: '修复登录按钮，等你确认：运行命令',
        isButton: true,
        isLiveRegion: true,
        hasTapAction: true,
        hasDismissAction: true,
      ),
    );
    semantics.dispose();
  });

  testWidgets('读屏审批不自动消失，完成通知停留十二秒', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(
      accessibleNavigation: true,
    );
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final container = await pumpHome(tester);
    source.emit(approval('e1', 's1'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 30));
    expect(find.text('等你确认：运行命令'), findsOneWidget);
    container.read(chatAlertsProvider.notifier).dismissBanner(container.read(chatAlertsProvider)!);
    await tester.pumpAndSettle();
    source.outcomes['s2'] = outcome(9, 'completed', reply: '好了');
    source.emit(const SessionStatusEvent('s2', true));
    source.emit(const SessionStatusEvent('s2', false));
    await tester.pumpAndSettle();
    expect(find.text('已完成 · 好了'), findsOneWidget);
    await tester.pump(const Duration(seconds: 11));
    expect(find.text('已完成 · 好了'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('已完成 · 好了'), findsNothing);
  });

  testWidgets('without the native module nothing starts', (tester) async {
    await pumpHome(tester, system: const NotifySystemStatus.unavailable());
    source.emit(approval('e1', 's1'));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('修复登录按钮'), findsNothing);
    expect(source.listCalls, 0);
  });
}
