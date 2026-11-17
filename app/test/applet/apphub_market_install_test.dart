// 应用市场页(2026-11-17 语义拍板):
//
// - 小程序一律由后台安装(主机上的万器 CLI 发布 + APP 侧静默同步落地),所以
//   用户能看到的小程序都在「已安装」;「应用」页留给后续接入外部小程序,当前
//   只给「开发中，敬请期待」占位,不再把市场目录当安装入口。
// - 「已安装」数据源与桌面同一份 `hubInstalledProvider`(市场目录 × 本机已装
//   核对 × 快照档案兜底);目录请求异常(网络层抛错)时仍是旧的「AppHub 未
//   连接」行动卡:远程主机给「一键安装 App Hub」,本机模式纯文案;自愈交给
//   Riverpod 的失败自动重试 + 下拉刷新。
// - 行点击进整页详情(ApphubAppDetailPage,截图/简介/权限/版本历史),不再
//   直接拉起小程序;直开语义收在行内「打开」按钮上。
//
// 测试注记:已装清单经 HubInstalledController.fetcher 替身注入(与桌面已装
// 清单测试同一注入点);默认替身命中 flutter_test 的 HttpClient 替身(400),
// 目录按空处理,页面落空态。

import 'package:dsh_app/state/ask_ai.dart';
import 'package:dsh_app/state/compose_inbox.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/applet/apphub_app_detail_page.dart';
import 'package:dsh_app/ui/applet/apphub_install_guide.dart';
import 'package:dsh_app/ui/applet/apphub_market_page.dart';
import 'package:dsh_app/ui/applet/hub_apps_group.dart'
    show HubInstalledApp, HubInstalledController;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../phone/support.dart' show FixedActiveHost;
import '../shell/golden_harness.dart';

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));

/// 已装清单替身的数据行(固定版本号,断言直接认)。
HubInstalledApp _installed(String appId, String name, {int version = 3}) => HubInstalledApp(
      appId: appId,
      name: name,
      iconKey: 'book',
      installedVersionCode: version,
    );

void main() {
  late Future<List<HubInstalledApp>> Function() originalFetcher;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    originalFetcher = HubInstalledController.fetcher;
  });
  tearDown(() => HubInstalledController.fetcher = originalFetcher);

  Future<void> pumpMarket(
    WidgetTester tester, {
    HostRef host = const HostRef.ssh('pc'),
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
                    builder: (_) => const ApphubMarketPage(),
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
    await tester.pump(); // 路由推入 + initState 发起首拉
    await tester.pumpAndSettle();
  }

  testWidgets('installed tab is the default: installed apps list with Open, no Get/Update', (tester) async {
    HubInstalledController.fetcher = () async => <HubInstalledApp>[
          _installed('wx5c7d8e9f1a2b3c4d', '刷题本'),
        ];
    await pumpMarket(tester);

    expect(find.text('刷题本'), findsOneWidget);
    expect(find.text('版本 3'), findsOneWidget);
    expect(find.text('打开'), findsOneWidget);
    // 市场语义已下线:不再有「获取 / 安装 / 更新」这类安装入口。
    expect(find.text('获取'), findsNothing);
    expect(find.text('安装'), findsNothing);
    expect(find.text('更新'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('tapping an installed row opens the detail page, not the mini program', (tester) async {
    HubInstalledController.fetcher = () async => <HubInstalledApp>[
          _installed('wx5c7d8e9f1a2b3c4d', '刷题本'),
        ];
    await pumpMarket(tester);

    await tester.tap(find.text('刷题本'));
    await tester.pumpAndSettle();

    // 行点击 = 详情页;市场页还在路由栈下(opaque 路由下层 offstage,
    // finder 要显式带上),返回即回清单。
    expect(find.byType(ApphubAppDetailPage), findsOneWidget);
    expect(find.byType(ApphubMarketPage, skipOffstage: false), findsOneWidget);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(ApphubAppDetailPage), findsNothing);
    expect(find.text('刷题本'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('apps tab shows the coming-soon placeholder instead of the catalog', (tester) async {
    HubInstalledController.fetcher = () async => <HubInstalledApp>[
          _installed('wx5c7d8e9f1a2b3c4d', '刷题本'),
        ];
    await pumpMarket(tester);

    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();

    expect(find.text('应用市场开发中，敬请期待'), findsOneWidget);
    expect(find.textContaining('后续会接入外部小程序'), findsOneWidget);
    expect(find.text('刷题本'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('empty installed list explains that programs are installed in the background', (tester) async {
    HubInstalledController.fetcher = () async => const <HubInstalledApp>[];
    await pumpMarket(tester);

    expect(find.text('还没有已安装的小程序'), findsOneWidget);
    expect(find.textContaining('后台自动安装'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('remote host: read failure card offers one-tap install that queues the guide prompt',
      (tester) async {
    HubInstalledController.fetcher = () async => throw Exception('market unreachable (stub)');
    await pumpMarket(tester);

    expect(find.text('AppHub 未连接'), findsOneWidget);
    final Finder cta = find.text('一键安装 App Hub');
    expect(cta, findsOneWidget);

    await tester.tap(cta);
    await tester.pumpAndSettle();

    final List<ComposeRequest> inbox = _container(tester).read(composeInboxProvider);
    expect(inbox, isNotEmpty);
    // 填好等确认:问AI管线加「关于<App 品牌>App：」前缀,引导词原样跟随;只入队不自动发送。
    expect(inbox.last.text, matches(RegExp(r'^关于.+App：请在这台主机上安装万器 CLI')));
    expect(inbox.last.text, contains(apphubInstallPrompt));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('local host: plain text only, no install CTA', (tester) async {
    HubInstalledController.fetcher = () async => throw Exception('market unreachable (stub)');
    await pumpMarket(tester, host: HostRef.local);

    expect(find.text('AppHub 未连接'), findsOneWidget);
    expect(find.text('一键安装 App Hub'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('first fetch failing heals on its own: Riverpod auto-retry lands the list', (tester) async {
    int calls = 0;
    HubInstalledController.fetcher = () async {
      calls++;
      if (calls == 1) throw Exception('market unreachable (stub)');
      return <HubInstalledApp>[_installed('wx7c3e9d2a1b4f5e68', '记账本')];
    };

    await pumpMarket(tester);

    // 页面不挂自愈定时器:失败 provider 由 Riverpod 自动重试,替身第二次
    // 返回真数据后页面直接落已装清单(pumpAndSettle 已把重试泵完)。
    expect(calls, greaterThanOrEqualTo(2), reason: '失败后应有自动重试');
    expect(find.text('AppHub 未连接'), findsNothing);
    expect(find.text('记账本'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
