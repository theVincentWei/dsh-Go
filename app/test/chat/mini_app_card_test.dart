// 回复里的 `<miniapp …>` 标签渲染成跳转卡片:页名 + App名 + 「小程序」角标,
// 目录里没图时落首字母瓦片;整卡可点,打不开时一行提示;缺 `app` 属性的
// 标记画不出来。

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/ui/applet/hub_apps_group.dart';
import 'package:dsh_app/ui/chat/render/markdown_body.dart';
import 'package:dsh_app/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _tag = '<miniapp app="wx7c3e9d2a1b4f5e68" title="记一笔" path="pages/list/list"></miniapp>';

class _FixedInstalled extends HubInstalledController {
  _FixedInstalled(this.apps);

  final List<HubInstalledApp> apps;

  @override
  Future<List<HubInstalledApp>> build() async => apps;
}

Future<void> pumpReply(
  WidgetTester tester,
  String markdown, {
  List<HubInstalledApp> minis = const <HubInstalledApp>[],
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [hubInstalledProvider.overrideWith(() => _FixedInstalled(minis))],
      child: MaterialApp(
        locale: AppLocale.zhCN,
        supportedLocales: AppLocale.supported,
        localizationsDelegates: const [L10n.delegate, ...GlobalMaterialLocalizations.delegates],
        theme: buildLightTheme(),
        home: Scaffold(body: SingleChildScrollView(child: MarkdownBody(text: markdown, selectable: false))),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  const app = HubInstalledApp(appId: 'wx7c3e9d2a1b4f5e68', name: '记账本');

  testWidgets('a miniapp tag renders the card with app name, badge and page subtitle', (tester) async {
    await pumpReply(tester, '看这里：\n$_tag', minis: [app]);
    expect(find.text('记一笔'), findsOneWidget);
    expect(find.text('记账本'), findsOneWidget);
    expect(find.text('小程序'), findsOneWidget);
    // 目录里没带图标:首字母瓦片兜底。
    expect(find.text('记'), findsOneWidget);
    // 主行 = 应用名(带角标),副行 = 页名:应用名在页名上方。
    final appRow = tester.getRect(find.text('记账本'));
    final pageRow = tester.getRect(find.text('记一笔'));
    expect(appRow.top, lessThan(pageRow.top));
  });

  testWidgets('an unknown app still shows the card (title first, no app line)', (tester) async {
    await pumpReply(tester, _tag);
    expect(find.text('记一笔'), findsOneWidget);
    expect(find.text('记账本'), findsNothing);
    expect(find.text('小程序'), findsOneWidget);
  });

  testWidgets('a tag without the app attribute draws nothing', (tester) async {
    await pumpReply(tester, '<miniapp title="记一笔"></miniapp>');
    expect(find.text('记一笔'), findsNothing);
    expect(find.text('小程序'), findsNothing);
  });

  testWidgets('tapping the card says one line when the app cannot open', (tester) async {
    // 无人认领的通道 = 原生回 MissingPluginException(测试里 mock 回 null)。
    const channel = MethodChannel('dsh/dimina');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async => null);
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    await pumpReply(tester, _tag, minis: [app]);
    await tester.tap(find.text('记一笔'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('无法打开这个链接'), findsOneWidget);
  });
}
