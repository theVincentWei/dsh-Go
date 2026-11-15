// AppHub 一键安装(2026-11-15):市场页「未连接」失败态的行动卡——
// 远程主机上出「一键安装 App Hub」,点下经「问AI」通道把固化引导词填进
// 主机会话(填好等确认,用户可看可改再发);本机模式没有可装货架的远端,
// 保持纯文案。失败态另有周期补拉:货架后起(隧道侧 45s 补探已把转发补上)
// 时本页自愈转亮,不用下拉刷新/重进。
//
// 测试注记:自愈用例经 fetchApps 注入「先失败后成功」替身——widget 测试的
// FakeAsync 区里真 socket 的完成时机不可靠(拒连能到、活服务请求到不了),
// 纯 Dart 替身全程 fake 时区,pump 可精确驱动;appHubBase 钉 127.0.0.1:1
// 只是兜底,绝不碰本机真 7610 货架。

import 'package:dsh_app/notify/apphub_base.dart';
import 'package:dsh_app/state/ask_ai.dart';
import 'package:dsh_app/state/compose_inbox.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/applet/apphub_install_guide.dart';
import 'package:dsh_app/ui/applet/apphub_market_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../phone/support.dart' show FixedActiveHost;
import '../shell/golden_harness.dart';

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    appHubBase = 'http://127.0.0.1:1';
  });
  tearDown(resetAppHubBase);

  Future<void> pumpMarket(
    WidgetTester tester, {
    HostRef host = const HostRef.ssh('pc'),
    Duration retryInterval = const Duration(seconds: 20),
    Future<http.Response> Function(Uri uri)? fetchApps,
  }) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        brightness: Brightness.light,
        overrides: <Override>[
          activeHostProvider.overrideWith(() => FixedActiveHost(host)),
          activeConnectionProvider.overrideWithValue(const AsyncValue.data(null)),
          guidePageReaderProvider.overrideWithValue((String asset) async => '# 占位指引'),
        ],
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ApphubMarketPage(retryInterval: retryInterval, fetchApps: fetchApps),
                  ),
                ),
                child: const Text('进入'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('进入'));
    await tester.pump(); // 路由推入 + initState 发起 _load
    await tester.pumpAndSettle();
  }

  testWidgets('remote host: failure card offers one-tap install that queues the guide prompt', (tester) async {
    await pumpMarket(tester);

    expect(find.text('AppHub 未连接'), findsOneWidget);
    final Finder cta = find.text('一键安装 App Hub');
    expect(cta, findsOneWidget);

    await tester.tap(cta);
    await tester.pumpAndSettle();

    final List<ComposeRequest> inbox = _container(tester).read(composeInboxProvider);
    expect(inbox, isNotEmpty);
    // 填好等确认:问AI管线加「关于<App 品牌>App：」前缀(文案随品牌版本走,
    // DSH Go/万器 都合法),引导词原样跟随;只入队不自动发送。
    expect(inbox.last.text, matches(RegExp(r'^关于\S*App：请在这台主机上安装万器 CLI')));
    expect(inbox.last.text, contains(apphubInstallPrompt));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('local host: plain text only, no install CTA', (tester) async {
    await pumpMarket(tester, host: HostRef.local);

    expect(find.text('AppHub 未连接'), findsOneWidget);
    expect(find.text('一键安装 App Hub'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('shelf coming up later: retry timer heals the page on its own', (tester) async {
    // 注入「首拉失败 → 补拉成功」替身:全程 fake 时区,pump 精确驱动。
    int calls = 0;
    Future<http.Response> fetchApps(Uri uri) async {
      calls++;
      if (calls == 1) throw Exception('market unreachable (stub)');
      return http.Response('{"apps":[]}', 200);
    }

    await pumpMarket(tester, fetchApps: fetchApps);
    expect(find.text('AppHub 未连接'), findsOneWidget);

    // 补拉周期到点(市场页默认 20s;首响=武装时刻+20s,多推 10s 避开整点边界),
    // 第二次拉取替身返回 200 → 页面自愈转亮。
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();

    expect(calls, greaterThanOrEqualTo(2), reason: '补拉定时器应已发起至少一次重查');
    expect(find.text('AppHub 未连接'), findsNothing);
    expect(find.text('暂无应用'), findsOneWidget);
    expect(find.text('一键安装 App Hub'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
