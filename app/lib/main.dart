import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'dev/download_perf_probe.dart';
import 'dev/frame_probe.dart';
import 'diagnostics/app_error_log.dart';
import 'launch/launch_state.dart';
import 'notify/apphub_notices.dart';
import 'state/locale_state.dart';
import 'ui/common/third_party_licenses.dart';
import 'ui/settings/font_licenses.dart';
import 'ui/theme/theme.dart';
import 'ui/applet/dimina/dimina_poc_screen.dart' show DiminaPocScreen, kDiminaPoc;

Future<void> main() => runWithFrameProbe(_startApp);

Future<void> _startApp() async {
  if (!frameProbeEnabled) SteadyFrameBinding();
  WidgetsFlutterBinding.ensureInitialized();
  startDownloadPerfProbe();
  appErrorCapture.install();
  // The first frame is already in the chosen language (设置 → 语言), and is the launch
  // window's own picture (启动画面, lib/launch/launch_state.dart).
  await Future.wait([AppLanguageController.load(), LaunchController.begin()]);
  // MIT / OFL notices must ship with the APK, not just the sources.
  registerThirdPartyLicenses();
  registerFontLicenses();
  // AppHub 小程序通知:60s 轮询 notices,进程活着期间推送本地通知(M3)。
  AppHubNoticeService.start();
  // Edge-to-edge with transparent system bars; pages refine the icon brightness
  // through AnnotatedRegion(dshSystemOverlay(...)).
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(dshSystemOverlay(PlatformDispatcher.instance.platformBrightness));
  // DSH_DIMINA_POC=1 boots straight into the Dimina POC page instead of the
  // connection root gate — AppHub M0 bring-up on an emulator without an engine
  // (feat/apphub-dimina). Without the define this line compiles to plain DshApp.
  runApp(const ProviderScope(child: DshApp(home: kDiminaPoc ? DiminaPocScreen() : null)));
}
