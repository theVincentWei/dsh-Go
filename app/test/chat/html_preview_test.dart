// 应用内 HTML 预览页:默认交给 WebView 渲染,一键切源码。WebView 用测试
// 替身,只看「加载了哪一回环地址、能不能切」;服务器本体在
// html_preview_server_test.dart(真 socket 不能进这个文件:套件里有
// testWidgets 时 TestWidgetsFlutterBinding 把一切 HttpClient 拦成 400)。

// ignore_for_file: depend_on_referenced_packages

import 'package:dsh_app/state/artifacts.dart';
import 'package:dsh_app/ui/shell/page_frame.dart' show GlassIconButton;
import 'package:dsh_app/ui/chat/artifact_preview.dart';
import 'package:dsh_app/ui/chat/render/code_block.dart';
import 'package:dsh_app/ui/chat/widgets/artifact_card.dart' show showArtifactMenu;
import 'package:dsh_app/ui/plugins/islands/island_platform.dart';
import 'package:dsh_app/ui/session/workspace_files.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import '../files/support/files_harness.dart';
import '../web/support/fake_webview.dart';
import 'support/harness.dart';

/// 当下测试装上的 WebView 替身(setUp 里换进 [WebViewPlatform.instance])。
FakeWebViewPlatform get _web => WebViewPlatform.instance as FakeWebViewPlatform;

/// 按提示文案找玻璃圆钮(byTooltip 在测试里靠语义树,不可靠)。
Finder _tip(String tip) => find.byWidgetPredicate((w) => w is GlassIconButton && w.tooltip == tip);

void main() {
  group('HTML preview page', () {
    late IslandPlatform realIslands;

    setUp(() {
      WebViewPlatform.instance = FakeWebViewPlatform();
      realIslands = IslandPlatform.instance;
      IslandPlatform.instance = FakeIslandPlatform();
    });

    tearDown(() => IslandPlatform.instance = realIslands);

    /// 服务器的回环绑定是真实 I/O:给它真实时间,其余(替身记录)随后就绪。
    Future<void> waitLoaded(WidgetTester tester, {int controllers = 1}) async {
      await tester.runAsync(() async {
        for (var i = 0; i < 50 && _web.controllers.length < controllers; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await pumpFrames(tester, 4);
    }

    testWidgets('renders by default through the loopback server, and switches to source on demand', (tester) async {
      usePhoneView(tester);
      const source = '<h1>Preview contract</h1><p>渲染,不执行给测试看的错误。</p>';
      final workspace = sampleWorkspace()..write('page.html', source);
      // 真实导航:文件页是 push 进来的(AppPage 依 ModalRoute 判定头型)。
      await tester.pumpWidget(
        filesApp(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(FilePreviewPage.route(sessionId: 's1', path: '${workspace.root}/page.html')),
              child: const Text('open'),
            ),
          ),
          workspace,
        ),
      );
      await tester.tap(find.text('open'));
      await pumpFrames(tester, 4);
      await waitLoaded(tester);
      expect(previewModeOf('page.html'), PreviewMode.web);
      expect(_web.controllers.single.loads.single.host, '127.0.0.1');
      expect(_web.controllers.single.loads.single.path, '/page.html');
      expect(find.byType(CodeBlock), findsNothing);
      // 源码 ⇄ 渲染。
      await tester.tap(_tip('源码'));
      await pumpFrames(tester, 8);
      expect(tester.widget<CodeBlock>(find.byType(CodeBlock)).code, contains(source));
      await tester.tap(_tip('渲染'));
      await waitLoaded(tester, controllers: 2);
      expect(find.byType(CodeBlock), findsNothing);
      expect(_web.controllers.last.loads.single.path, '/page.html');
    });

    testWidgets('an html artifact card offers 预览 like any previewable file', (tester) async {
      usePhoneView(tester);
      final workspace = sampleWorkspace()..write('page.html', '<h1>hi</h1>');
      await tester.pumpWidget(
        filesApp(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showArtifactMenu(
                context,
                artifact: Artifact(path: '${workspace.root}/page.html', origin: ArtifactOrigin.linked, turn: 1),
                canFetch: true,
              ),
              child: const Text('open menu'),
            ),
          ),
          workspace,
        ),
      );
      await tester.tap(find.text('open menu'));
      await tester.pumpAndSettle();
      expect(find.text('预览'), findsOneWidget);
      expect(find.text('用其他应用打开'), findsOneWidget);
    });
  });
}
