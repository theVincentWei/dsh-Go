import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'companion/companion_initiative_owner.dart' show companionInitiativeProvider;
import 'l10n/l10n.dart';
import 'performance/performance_state.dart';
import 'performance/refresh_rate.dart';
import 'state/app_info.dart';
import 'state/appearance_state.dart';
import 'state/hub_desktop_sync.dart' show hubDesktopSyncProvider;
import 'state/locale_state.dart';
import 'state/star_prompt.dart' show starPromptGateProvider, starPromptProvider;
import 'ui/applet/dimina/float_ball.dart';
import 'state/tile_style_state.dart';
import 'ui/chat/dsh_ui/dsh_ui_model.dart' show DshUiAppAccent;
import 'ui/applet/dimina/dimina_host.dart' show DiminaHost;
import 'ui/common/side_insets.dart';
import 'ui/launch/launch_overlay.dart';
import 'ui/shell/root_navigator_key.dart' show rootNavigatorKey;
import 'ui/shell/root_gate.dart';
import 'ui/theme/theme.dart';
import 'ui_config/ui_config_state.dart';
import 'usage/usage_stats.dart';

class DshApp extends ConsumerStatefulWidget {
  const DshApp({super.key, this.home});

  /// Replaces the root gate (widget tests).
  final Widget? home;

  @override
  ConsumerState<DshApp> createState() => _DshAppState();
}

class _DshAppState extends ConsumerState<DshApp> with WidgetsBindingObserver {
  /// Themes of the palette last built: rebuilt only when the palette or the
  /// language changes.
  AppAccent? _accent;
  bool? _english;
  bool? _glassBlur;
  bool? _instantPages;
  bool? _fluid;
  late ThemeData _light;
  late ThemeData _dark;

  /// The language last shown; a change after the first frame rebuilds the
  /// whole tree (text read through `appL10n` has no dependency to notify).
  Locale? _shown;

  /// The stored palette arrives a moment after launch; that first switch
  /// lands without a cross-fade, later ones fade (切换配色).
  bool _settled = false;

  @override
  void initState() {
    super.initState();
    // Start loading the stored tile style now, so 全部功能 opens in it rather
    // than flashing the default first.
    ref.read(tileStyleProvider);
    // Anonymous usage statistics live as long as the app, in either 界面
    // (release builds: today is noted, and earlier days go out).
    ref.read(usageStatsProvider);
    // 公测版: the star prompt counts time in front from launch, in either 界面.
    if (ref.read(starPromptGateProvider)) ref.read(starPromptProvider);
    // 伙伴小屋: her invitation ledger is read now, so it is known before the room opens.
    ref.read(companionInitiativeProvider);
    // 刷新率: some systems cap third-party apps at 60 Hz and then show their per-app
    // switch as an in-app setting; the app answers frames to run at the fastest rate
    // while it is actually drawing (see RefreshRateService).
    RefreshRateService.instance.start();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 跟随系统: the system language changed while the app was open.
  @override
  void didChangeLocales(List<Locale>? locales) {
    if (ref.read(appLanguageProvider) == AppLanguage.system) setState(() {});
  }

  /// The system's remove-animations setting changed while the app was open: page
  /// transitions are chosen in [build], so they would keep the old answer.
  @override
  void didChangeAccessibilityFeatures() => setState(() {});

  void _themesFor(AppAccent accent, bool english, bool glassBlur, bool instantPages, bool fluid) {
    if (accent == _accent &&
        english == _english &&
        glassBlur == _glassBlur &&
        instantPages == _instantPages &&
        fluid == _fluid) {
      return;
    }
    _accent = accent;
    _english = english;
    _glassBlur = glassBlur;
    _instantPages = instantPages;
    _fluid = fluid;
    // Plugin views that ask for `accent: "app"` follow the palette.
    DshUiAppAccent.set(accent.seed.toARGB32());
    // English UI still shows Chinese content: keep its glyphs Chinese.
    final glyphs = english ? AppLocale.zhCN : null;
    _light = buildLightTheme(
      accent: accent,
      glyphLocale: glyphs,
      glassBlur: glassBlur,
      instantPages: instantPages,
      fluid: fluid,
    );
    _dark = buildDarkTheme(
      accent: accent,
      glyphLocale: glyphs,
      glassBlur: glassBlur,
      instantPages: instantPages,
      fluid: fluid,
    );
  }

  Locale _resolveLocale() {
    final locale = AppLocale.resolve(
      ref.watch(appLanguageProvider).locale,
      WidgetsBinding.instance.platformDispatcher.locales,
    );
    if (locale != _shown) {
      final first = _shown == null;
      _shown = locale;
      AppLocale.use(locale);
      if (!first) WidgetsBinding.instance.addPostFrameCallback((_) => _rebuildAll());
    }
    return locale;
  }

  void _rebuildAll() {
    void mark(Element e) {
      e.markNeedsBuild();
      e.visitChildren(mark);
    }

    if (mounted) (context as Element).visitChildren(mark);
  }

  @override
  Widget build(BuildContext context) {
    // 桌面目录与角标的宿主注册者(keep-alive):根装配 watch 一次养活,
    // 应用生命周期在线——桌面页不在场的路径(push/通知)角标也照常同步;
    // 引擎保持被动,启动与养活都是宿主的事(见 state/hub_desktop_sync)。
    ref.watch(hubDesktopSyncProvider);
    // 刷新率设置改动时告诉原生;setMode 对同一个值不做任何事。
    unawaited(
      RefreshRateService.instance.setMode(ref.watch(performancePrefsProvider.select((p) => p.refreshRate))),
    );
    final themeMode = ref.watch(uiThemeModeProvider.select((s) => s.value));
    // Dimina 容器主题集中同步:宿主当前亮度(跟随系统或用户显式选择),
    // 所有 DiminaHost.open 调用点缺省用它——调用点无需各自关心主题。
    DiminaHost.themeDark = switch (themeMode) {
      ThemeMode.dark => true,
      ThemeMode.light => false,
      ThemeMode.system => MediaQuery.platformBrightnessOf(context) == Brightness.dark,
    };
    final appearance = ref.watch(appearanceProvider);
    final waiting =
        !appearance.loaded ||
        (appearance.source == AccentSource.wallpaper && ref.watch(wallpaperAccentProvider).isLoading);
    final locale = _resolveLocale();
    final performance = ref.watch(performanceDefaultsProvider);
    final reduced =
        performance.reduceMotion || WidgetsBinding.instance.platformDispatcher.accessibilityFeatures.disableAnimations;
    final fluid = performance.fluidMotion && !reduced;
    FrameClock.instance.enabled = fluid;
    _themesFor(ref.watch(accentProvider), locale.languageCode == 'en', performance.blur, reduced, fluid);
    if (!waiting && !_settled) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _settled = true);
    }
    return MaterialApp(
      title: AppInfo.name,
      debugShowCheckedModeBanner: false,
      // 根导航器键:桌面卸载钩子这类无 BuildContext 的宿主回调经它弹全局
      // 对话框(共用卸载弹窗,见 root_navigator_key.dart)。
      navigatorKey: rootNavigatorKey,
      theme: _light,
      darkTheme: _dark,
      themeMode: themeMode,
      // Palette and light / dark changes cross-fade the whole app (AppMotion).
      // A reveal from the finger brings the new colours in itself.
      themeAnimationStyle: _settled && !reduced && !ThemeRevealHost.active
          ? AnimationStyle(duration: AppMotion.standard, curve: AppMotion.std)
          : AnimationStyle.noAnimation,
      // zh_CN, not bare zh: otherwise CJK falls back to Japanese glyph shapes
      // on non-Chinese system locales. English keeps Chinese glyphs through
      // the theme's text locale (_themesFor).
      locale: locale,
      supportedLocales: AppLocale.supported,
      localizationsDelegates: const [L10n.delegate, ...GlobalMaterialLocalizations.delegates],
      // A phone on its side: the cutout's inset on both sides (side_insets). Over everything,
      // the launch screen of a cold start (启动画面).
      builder: (context, child) {
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(disableAnimations: media.disableAnimations || performance.reduceMotion),
          child: AppMotionScope(
            fluid: fluid,
            child: ThemeRevealHost(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  MirroredSideInsets(child: child!),
                  // 小程序浮窗单球(2026-11-12):⋯菜单「浮窗」收后台后贴边常驻,
                  // 点击原地恢复;盖在所有路由之上、冷启动层之下。
                  DiminaFloatBall(child: child),
                  const LaunchLayer(),
                ],
              ),
            ),
          ),
        );
      },
      home: widget.home ?? const RootGate(),
    );
  }
}
