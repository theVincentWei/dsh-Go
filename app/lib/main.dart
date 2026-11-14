import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'dev/download_perf_probe.dart';
import 'dev/frame_probe.dart';
import 'diagnostics/app_error_log.dart';
import 'launch/launch_state.dart';
import 'links/page_links.dart' show registerPageLink, tavernPageLink;
import 'notify/apphub_notices.dart';
import 'notify/apphub_proxy.dart';
import 'state/locale_state.dart';
import 'ui/common/third_party_licenses.dart';
import 'ui/fx/metal/metal_shader.dart';
import 'ui/fx/waves/distortion_wave.dart';
import 'ui/settings/font_licenses.dart';
import 'ui/tavern/tavern_home_page.dart';
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
  // dshgo://open/tavern: the page lives in ui/, which links/ does not import.
  registerPageLink(tavernPageLink, () => const TavernHomePage());
  // The effects' shaders load now, so the first wave or metal word is not a plain fallback.
  unawaited(DistortionWave.precache());
  unawaited(MetalShader.load());
  // AppHub 小程序通知:60s 轮询 notices,进程活着期间推送本地通知(M3)。
  AppHubNoticeService.start();
  // AppHub 固定端口本机反代:原生 Dimina 容器只认这个端口,SSH 隧道重连
  // 换动态端口不再打断它的 manifest/包拉取(否则小程序「打开即闪退」)。
  await AppHubProxy.ensureStarted();
  // Edge-to-edge with transparent system bars; pages refine the icon brightness
  // through AnnotatedRegion(dshSystemOverlay(...)).
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(dshSystemOverlay(PlatformDispatcher.instance.platformBrightness));
  // DSH_DIMINA_POC=1 boots straight into the Dimina POC page instead of the
  // connection root gate — AppHub M0 bring-up on an emulator without an engine
  // (feat/apphub-dimina). Without the define this line compiles to plain DshApp.
  runApp(const ProviderScope(child: DshApp(home: kDiminaPoc ? DiminaPocScreen() : null)));
}
