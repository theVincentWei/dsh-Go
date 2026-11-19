// Development entry point (GLB model viewer): boots straight into the
// viewer page with the bundled sample.glb (Khronos "Fox", CC0), so the
// emulator can verify GLTFLoader rendering (embedded textures, Y-up, no
// rotation), gestures and load reporting without the engine runtime.
// Never talks to the network. Not part of any release.
//
//   tooling/build-apk.sh --debug -f x64 -t lib/dev/model_glb_probe_main.dart
//
// What to see: the textured fox on a grid (already Y-up, loaded as-is),
// one finger orbiting, two fingers zoom/pan, a chip with the triangle/part
// count once loaded.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../l10n/l10n.dart';
import '../ui/model3d/model_3mf_viewer_page.dart';

void main() {
  runApp(const _ModelGlbProbeApp());
}

class _ModelGlbProbeApp extends StatelessWidget {
  const _ModelGlbProbeApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GLB viewer probe',
      theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
      locale: AppLocale.zhCN,
      supportedLocales: AppLocale.supported,
      localizationsDelegates: const [L10n.delegate, ...GlobalMaterialLocalizations.delegates],
      home: const Model3mfViewerPage(assetPath: Model3mfViewerPage.sampleGlbAssetPath),
    );
  }
}
