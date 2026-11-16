import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_app/state/artifact_files.dart';
import 'package:dsh_app/state/artifacts.dart' show FilesChannel;
import 'package:dsh_app/state/connection_state.dart' show HostConnection;
import 'package:dsh_app/ui/session/workspace_files.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';
import '../files/support/files_harness.dart';

/// The preview is a pushed page: a blank page underneath keeps
/// `Navigator.canPop` true, so the page's back key renders.
Widget _pushed(Widget page) => Navigator(
  onPopPage: (route, result) {
    if (!route.didPop(result)) return false;
    return true;
  },
  pages: [
    MaterialPage<void>(child: const SizedBox.shrink()),
    MaterialPage<void>(child: page),
  ],
);

void main() {
  setUpAll(loadTestFonts);
  for (final file in ['README.md', 'out/sales.csv', 'bundle.zip', 'out/chart.png']) {
    testWidgets('preview controls are symmetric for $file', (tester) async {
      usePhoneView(tester);
      final ws = sampleWorkspace()..write('bundle.zip', 'PK');
      await tester.pumpWidget(
        filesApp(_pushed(FilePreviewPage(sessionId: 's1', path: '${ws.root}/$file', bytes: 2048)), ws),
      );
      await pumpFrames(tester, 8);
      final share = tester.getRect(find.byTooltip('分享'));
      final more = tester.getRect(find.byTooltip('更多操作'));
      final back = tester.getRect(find.byTooltip('返回'));
      final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
      expect(more.left - share.right, closeTo(8, 0.01));
      expect(width - more.right, closeTo(12, 0.01));
      expect(share.center.dy, closeTo(back.center.dy, 0.01));
      expect(more.center.dy, closeTo(back.center.dy, 0.01));
      if (file == 'out/sales.csv' || file == 'bundle.zip') {
        final title = tester.getRect(find.byKey(const ValueKey('preview-frame-title')));
        final meta = tester.getRect(find.byKey(const ValueKey('preview-frame-meta')));
        expect(title.left, closeTo(68, 0.01));
        expect(meta.left, closeTo(title.left, 0.01));
        expect(
          tester.widget<Text>(find.byKey(const ValueKey('preview-frame-meta'))).data,
          file == 'bundle.zip' ? '工作区 · 2.0 KB' : 'out · 2.0 KB',
        );
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('an SVG previews as a drawing on paper, not as its source', (tester) async {
    usePhoneView(tester);
    const svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 5">'
        '<rect width="10" height="5" fill="#f00"/></svg>';
    final ws = sampleWorkspace()..write('out/logo.svg', svg);
    final path = '${ws.root}/out/logo.svg';
    final cache = Directory.systemTemp.createTempSync('svg-preview');
    addTearDown(() => cache.deleteSync(recursive: true));
    final remote = HostConnection(
      client: DshClient.withCarrier(_SvgCarrier(Uint8List.fromList(utf8.encode(svg)), path)),
      label: '工作站',
      isLocal: false,
      hostId: 'h1',
    );
    await tester.pumpWidget(
      filesApp(
        _pushed(FilePreviewPage(sessionId: 's1', path: path, bytes: svg.length)),
        ws,
        connection: remote,
        overrides: [
          artifactFilesProvider.overrideWithValue(
            ArtifactFiles(connection: remote, channel: const FilesChannel(), cacheRoot: () async => cache),
          ),
        ],
      ),
    );
    // materialize writes a real cache file: give its IO real event-loop turns.
    await tester.runAsync(() async {
      for (var i = 0; i < 50 && find.byType(SvgPicture).evaluate().isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
    });
    await pumpFrames(tester, 8);
    expect(find.byType(SvgPicture), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

/// A remote Host that serves one SVG document for every stat / readBytes.
class _SvgCarrier extends DshCarrier {
  _SvgCarrier(this.content, this.absolutePath);

  final Uint8List content;
  final String absolutePath;

  @override
  String get kind => 'memory';

  @override
  DshTracer? get tracer => null;

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    final stat = {'absolutePath': absolutePath, 'version': 'v1', 'bytes': content.length};
    return switch (endpoint) {
      'workspaceFiles/stat' => RpcOk(stat),
      'workspaceFiles/readBytes' => RpcOk({...stat, 'offset': 0, 'data': base64Encode(content), 'eof': true}),
      _ => const RpcError(DshRemoteException('gateway/not-found', 'missing')),
    };
  }

  @override
  Future<DshMuxLink> openLink(MuxOptions options) => throw UnsupportedError('no streams');

  @override
  Future<void> close() async {}
}
