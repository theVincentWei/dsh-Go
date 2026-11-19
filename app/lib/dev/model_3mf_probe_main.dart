// Development entry point (3MF model viewer, route A): boots straight into the
// viewer page with the bundled sample model, so the emulator can verify
// three.js rendering, gestures and load reporting without the engine runtime.
// Never talks to the network. Not part of any release.
//
//   tooling/build-apk.sh --debug -f x64 -t lib/dev/model_3mf_probe_main.dart
//
// What to see: the generated sample cup (底座 + 杯身, two coloured parts from
// app/tool/make_sample_3mf.py) on a grid, one finger orbiting, two fingers
// zoom/pan, a chip with the triangle/part count once loaded.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../l10n/l10n.dart';
import '../ui/model3d/model_3mf_viewer_page.dart';

void main() {
  runApp(const _Model3mfProbeApp());
}

class _Model3mfProbeApp extends StatelessWidget {
  const _Model3mfProbeApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '3MF viewer probe',
      theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
      locale: AppLocale.zhCN,
      supportedLocales: AppLocale.supported,
      localizationsDelegates: const [
        L10n.delegate,
        ...GlobalMaterialLocalizations.delegates,
      ],
      home: const Model3mfViewerPage(),
    );
  }
}
