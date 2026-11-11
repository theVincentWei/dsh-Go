// Real fonts for the engine's widget tests, loaded once per run by
// `flutter_test_config.dart`: geometry assertions measure the glyphs a phone
// shows. Material Icons (the engine uses Icons.* chrome), DshIcons (the
// host-bundled glyph subset the engine's small widgets reference) and
// Roboto/Noto Sans CJK (text). Strict: a missing font fails the run.

import 'dart:io';

import 'package:flutter/services.dart';

/// The family Material's Android typography asks for. On a phone it is the
/// system sans; here Noto Sans CJK stands in for it.
const sansFamily = 'Roboto';

bool _loaded = false;

Future<void> loadTestFonts() async {
  if (_loaded) return;
  _loaded = true;
  final flutterRoot =
      Platform.environment['FLUTTER_ROOT'] ??
      File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.parent.path;
  final material = '$flutterRoot/bin/cache/artifacts/material_fonts';

  Future<void> family(String name, List<String> paths) async {
    final loader = FontLoader(name);
    for (final path in paths) {
      final file = File(path);
      if (!file.existsSync()) {
        throw StateError('Test font missing: $path');
      }
      loader.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
    }
    await loader.load();
  }

  final fontDir = Platform.environment['DSH_TEST_FONT_DIR'] ?? '/usr/share/fonts/noto-cjk';
  final cjk = ['$fontDir/NotoSansCJK-Regular.ttc', '$fontDir/NotoSansCJK-Bold.ttc'];
  // The display sizes are w300: the light face, as on ROMs whose system sans
  // has one.
  final sans = ['$fontDir/NotoSansCJK-Light.ttc', ...cjk];
  await family('MaterialIcons', ['$material/MaterialIcons-Regular.otf']);
  // DshIcons ships with the host app (assets/fonts), one checkout up.
  await family('DshIcons', ['../../app/assets/fonts/DshIcons.ttf']);
  await family(sansFamily, sans);
  await family('Noto Sans CJK SC', cjk);
}
