// 音频产物的预览入口:点开就是应用内的那一个播放器(整页替换,不落外部 App)。

import 'dart:io';

import 'package:dsh_app/state/artifact_files.dart';
import 'package:dsh_app/state/artifacts.dart';
import 'package:dsh_app/ui/chat/artifact_preview.dart';
import 'package:dsh_app/ui/chat/media/media_video_viewer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../files/support/files_harness.dart';
import '../support/test_fonts.dart';
import 'support/harness.dart' show usePhoneView;

class _Files extends ArtifactFiles {
  _Files() : super(connection: null, channel: const FilesChannel());
  int reads = 0;
  @override
  bool get isLocal => false;
  @override
  bool get canFetch => true;
  @override
  Future<File> materialize(
    String sessionId,
    Artifact artifact, {
    void Function(double?)? onProgress,
    int maxBytes = maxRemoteArtifactBytes,
    String? taskLabel,
  }) async {
    reads++;
    onProgress?.call(0.5);
    return File('/phone/voice.mp3');
  }
}

void main() {
  setUpAll(loadTestFonts);

  testWidgets('音频预览整页替换成应用内播放器', (tester) async {
    usePhoneView(tester);
    final ws = sampleWorkspace()..write('voice.mp3', 'ID3');
    await tester.pumpWidget(
      filesApp(
        ArtifactPreviewPage(
          sessionId: 's1',
          artifact: Artifact(path: '${ws.root}/voice.mp3', origin: ArtifactOrigin.written, turn: 1),
        ),
        ws,
        overrides: [artifactFilesProvider.overrideWithValue(_Files())],
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(find.byType(MediaVideoViewerPage), findsOneWidget, reason: '音频走应用内播放器');
    await tester.pump(const Duration(milliseconds: 400)); // 整页替换的过场走完
    expect(find.byType(ArtifactPreviewPage), findsNothing, reason: '预览页被整页替换');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('视频产物同样整页替换(与音频同一播放器)', (tester) async {
    usePhoneView(tester);
    final ws = sampleWorkspace()..write('clip.mp4', 'mp4');
    await tester.pumpWidget(
      filesApp(
        ArtifactPreviewPage(
          sessionId: 's1',
          artifact: Artifact(path: '${ws.root}/clip.mp4', origin: ArtifactOrigin.written, turn: 1),
        ),
        ws,
        overrides: [artifactFilesProvider.overrideWithValue(_Files())],
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(find.byType(MediaVideoViewerPage), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
