// 「小程序问AI」进场链路(ask_ai_entry,2026-11-15 拍板)测试:
// - onAskAi 事件 → DistortionWaveRoute(ask-ai-chat)先推入、再调收后台
//   (float),compose 预填「我正在看小程序 X 的 Y 页面」+ 标题预定「问AI · X」;
// - 聊天页路由退场且小程序仍在后台保留 → open 恢复(appId/name/iconPng
//   来自事件与 floated 事件带的图标);
// - foregrounded/destroyed(用户自己回前台/运行时销毁)→ 返回不再恢复;
// - float 返回 false(无前台小程序)→ 忽略:聊天页照常进场,返回不恢复;
// - 任一退场都清标题预定,无关新会话不接手。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:dsh_app/l10n/l10n.dart' show appL10n;
import 'package:dsh_app/state/ask_ai.dart' show askAiMiniappRequest, askAiSessionTitleProvider;
import 'package:dsh_app/state/compose_inbox.dart' show composeInboxProvider;
import 'package:dsh_app/ui/applet/dimina/ask_ai_entry.dart';
import 'package:dsh_app/ui/applet/dimina/dimina_host.dart';
import 'package:dsh_app/ui/fx/waves/distortion_wave.dart';
import 'package:dsh_app/ui/shell/root_navigator_key.dart' show rootNavigatorKey;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderContainer, UncontrolledProviderScope;
import 'package:flutter_test/flutter_test.dart';

class _RecordingObserver extends NavigatorObserver {
  final List<Route<dynamic>> pushed = <Route<dynamic>>[];

  /// 事件时序:didPush 与收后台的相对次序(进场先推聊天页再收后台)。
  final List<String> trace = <String>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route);
    trace.add('push:${route.settings.name}');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late StreamController<DiminaAskAiEvent> askAi;
  late StreamController<DiminaFloatEvent> floats;
  late _RecordingObserver observer;
  final List<Uint8List?> floatedIcons = <Uint8List?>[];
  final List<({String appId, String name, Uint8List? iconPng})> opened =
      <({String appId, String name, Uint8List? iconPng})>[];
  int floatCalls = 0;
  bool floatOk = true;

  setUp(() {
    container = ProviderContainer();
    askAi = StreamController<DiminaAskAiEvent>.broadcast();
    floats = StreamController<DiminaFloatEvent>.broadcast();
    observer = _RecordingObserver();
    floatedIcons.clear();
    opened.clear();
    floatCalls = 0;
    floatOk = true;
  });

  tearDown(() async {
    await askAi.close();
    await floats.close();
    container.dispose();
  });

  Future<void> pumpHost(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorKey: rootNavigatorKey,
          navigatorObservers: [observer],
          home: AskAiEntryHost(
            events: askAi.stream,
            hostFloatEvents: floats.stream,
            floatCurrent: () async {
              floatCalls++;
              observer.trace.add('float');
              return floatOk;
            },
            open: ({required String appId, required String name, Uint8List? iconPng}) async {
              opened.add((appId: appId, name: name, iconPng: iconPng));
              return true;
            },
            chatBuilder: (_) => const SizedBox(key: ValueKey('askai-chat-stub')),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> ask(WidgetTester tester) async {
    askAi.add(const DiminaAskAiEvent(
      appId: 'wx-demo',
      appName: '演示小程序',
      pageTitle: '首页',
      pagePath: 'pages/index/index',
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
  }

  Future<void> goBack(WidgetTester tester) async {
    rootNavigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('onAskAi → 水波路由先推入、再收后台 + compose 预填 + 标题预定', (tester) async {
    await pumpHost(tester);
    await ask(tester);

    expect(floatCalls, 1);
    // 进场次序:先推聊天页(水波把底下那页带上来),再调收后台。
    expect(observer.trace.indexOf('push:$askAiChatRouteName'), lessThan(observer.trace.indexOf('float')));
    final Route<dynamic>? pushed = observer.pushed.where((r) => r.settings.name == askAiChatRouteName).firstOrNull;
    expect(pushed, isA<DistortionWaveRoute<dynamic>>());
    expect(find.byKey(const ValueKey('askai-chat-stub')), findsOneWidget);

    final compose = container.read(composeInboxProvider);
    expect(compose, hasLength(1));
    expect(compose.single.text, appL10n.askAiMiniappContext('演示小程序', '首页'));
    expect(container.read(askAiSessionTitleProvider), appL10n.askAiMiniappTitle('演示小程序'));

    await goBack(tester);
    // 没发送就退:compose 预填留在收件箱等下一任 composer,标题预定被清。
    expect(container.read(composeInboxProvider), hasLength(1));
    expect(container.read(askAiSessionTitleProvider), isNull);
  });

  testWidgets('返回恢复:小程序仍在保留 → open 带事件与 floated 图标恢复现场', (tester) async {
    await pumpHost(tester);
    await ask(tester);
    // 容器 notifyFloated 到达:单球照常出现,包图标随事件到达(恢复时直通)。
    floats.add(DiminaFloatEvent(
      type: 'floated',
      appId: 'wx-demo',
      appName: '演示小程序',
      iconPng: Uint8List.fromList(<int>[1, 2, 3]),
    ));
    await tester.pump();

    await goBack(tester);
    expect(opened, hasLength(1));
    expect(opened.single.appId, 'wx-demo');
    expect(opened.single.name, '演示小程序');
    expect(opened.single.iconPng, <int>[1, 2, 3]);
  });

  testWidgets('用户已自己回前台(foregrounded)→ 返回不再恢复', (tester) async {
    await pumpHost(tester);
    await ask(tester);
    floats.add(const DiminaFloatEvent(type: 'foregrounded', appId: 'wx-demo'));
    await tester.pump();

    await goBack(tester);
    expect(opened, isEmpty);
    expect(container.read(askAiSessionTitleProvider), isNull);
  });

  testWidgets('收后台失败(无前台小程序,float 返回 false)→ 忽略:聊天页照常进场,返回不恢复', (tester) async {
    floatOk = false;
    await pumpHost(tester);
    await ask(tester);

    // 聊天页先盖上来(进场次序:先推聊天页再收后台),compose/标题照常就绪。
    expect(floatCalls, 1);
    expect(observer.pushed.where((r) => r.settings.name == askAiChatRouteName), isNotEmpty);
    expect(container.read(composeInboxProvider), hasLength(1));
    expect(container.read(askAiSessionTitleProvider), appL10n.askAiMiniappTitle('演示小程序'));

    await goBack(tester);
    // 没收成后台即谈不上保留:返回只清标题预定,不调 open。
    expect(opened, isEmpty);
    expect(container.read(askAiSessionTitleProvider), isNull);
  });

  test('askAiMiniappRequest:页标题缺省退到路径,都缺退到 app 名', () {
    expect(
      askAiMiniappRequest(appName: 'X', pageTitle: ' P ', pagePath: 'pages/i').text,
      appL10n.askAiMiniappContext('X', 'P'),
    );
    expect(
      askAiMiniappRequest(appName: 'X', pagePath: 'pages/i').text,
      appL10n.askAiMiniappContext('X', 'pages/i'),
    );
    expect(askAiMiniappRequest(appName: 'X').text, appL10n.askAiMiniappContextNoPage('X'));
  });
}
