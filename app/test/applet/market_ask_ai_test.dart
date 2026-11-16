// 市场页的「问 AI」（apphub_market_page.dart 的 AppBar actions）：点一下就把
// 「市场后端怎么装」的问题填进新对话的输入框（本机引擎走 /dsh-go-guide
// skill 问法，lib/state/ask_ai.dart 的 AskAiTopic.market）。测试里目录请求被
// flutter_test 的 HttpClient 替身拦成 400 → 已装清单按空处理，页面落空态
// （没有真的市场后端可连）。

import 'package:dsh_app/state/compose_inbox.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/applet/apphub_market_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../phone/support.dart' show FixedActiveHost;
import '../shell/golden_harness.dart' show goldenApp, usePhoneSurface;

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('问 AI：装市场后端的问题进输入框，本机引擎走 /dsh-go-guide 问法', (tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        brightness: Brightness.light,
        overrides: [
          activeHostProvider.overrideWith(() => FixedActiveHost(HostRef.local)),
          activeConnectionProvider.overrideWithValue(const AsyncValue.data(null)),
        ],
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () =>
                    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ApphubMarketPage())),
                child: const Text('打开应用市场'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开应用市场'));
    await tester.pump();
    await tester.pumpAndSettle();
    // 没有市场后端/没有已装小程序：「已安装」页落空态（2026-11-17 起市场页
    // 默认就是已安装），断言用空态文案。
    expect(find.text('还没有已安装的小程序'), findsOneWidget);
    expect(find.byTooltip('问 AI'), findsOneWidget);

    await tester.tap(find.byTooltip('问 AI'));
    await tester.pumpAndSettle();
    final List<ComposeRequest> inbox = _container(tester).read(composeInboxProvider);
    expect(inbox, hasLength(1));
    expect(inbox.single.text, '/dsh-go-guide 应用市场打不开或列表是空的，怎么在主机上装好市场后端（wanqi 服务）和它需要的插件？');
  });
}
