import 'package:dsh_app/state/artifacts.dart';
import 'package:dsh_app/ui/chat/artifact_preview.dart';
import 'package:dsh_app/ui/chat/widgets/artifact_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

void main() {
  for (final extension in ['docx', 'html']) {
    for (final converts in [false, true]) {
      testWidgets('$extension menu advertises only supported preview modes (converter: $converts)', (tester) async {
        final artifact = Artifact(path: '/root/workspace/document.$extension', origin: ArtifactOrigin.linked, turn: 1);
        await tester.pumpWidget(
          testApp(
            Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showArtifactMenu(context, artifact: artifact, canFetch: true, officeToPdf: converts),
                  child: const Text('open menu'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open menu'));
        await tester.pumpAndSettle();
        // HTML renders in-app now; the docx needs the Host's converter.
        expect(
          find.text('预览'),
          switch (extension) {
            'html' => findsOneWidget,
            'docx' => converts ? findsOneWidget : findsNothing,
            _ => findsNothing,
          },
        );
        expect(find.text('用其他应用打开'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }

  test('html previews render (web mode); mhtml stays source text', () {
    expect(previewModeOf('page.html'), PreviewMode.web);
    expect(previewModeOf('page.htm'), PreviewMode.web);
    expect(previewModeOf('page.mhtml'), PreviewMode.text);
    expect(previewModeOf('notes.txt'), PreviewMode.text);
  });
}
