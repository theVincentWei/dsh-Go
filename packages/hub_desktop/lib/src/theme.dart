// 引擎的主题基建:从宿主 app/lib/ui/theme 剪裁的桌面所需子集(数值与语义
// 一一对应;motion/glass 系 PiPilot 派生代码,同一仓库内移动,出处见
// 仓库 THIRD_PARTY_NOTICES.md)。主题色经 HubColors / HubGlassTheme 两个
// ThemeExtension 由宿主适配层翻译注入;包内缺省(引擎单独跑、测试)时
// 退回 ColorScheme 推导值。
//
// Portions derived from PiPilot (https://github.com/CikeSeven/pi_pilot), MIT,
// Copyright (c) 2026 CikeSeven.

import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

/// 动效 token(宿主 AppMotion 的桌面子集,数值不改)。
abstract final class HubMotion {
  /// 列表里按压显现前的等待,和显现后至少停留的时长。
  static const press = Duration(milliseconds: 90);

  /// 淡入淡出、图标交叉切换。
  static const quick = Duration(milliseconds: 160);

  /// 底部弹层进 / 出(showModalBottomSheet 只认时长)。
  static const sheetIn = Duration(milliseconds: 380);
  static const sheetOut = Duration(milliseconds: 260);

  /// 弹层停稳后,模糊透出来。
  static const glassIn = Duration(milliseconds: 120);

  /// 按压落位。
  static final pressSpring = SpringDescription.withDurationAndBounce(
    duration: const Duration(milliseconds: 150),
  );

  /// 跟手之后的落位:弹层。
  static final sheetSpring = SpringDescription.withDurationAndBounce(
    duration: const Duration(milliseconds: 500),
  );

  /// 松手回弹:按压回到 1 时越过一点点。
  static final releaseSpring = SpringDescription.withDurationAndBounce(
    duration: const Duration(milliseconds: 320),
    bounce: 0.45,
  );

  /// 数字滚动的曲线版弹簧(组头未读计数)。
  static final thumbSpring = SpringDescription.withDurationAndBounce(
    duration: const Duration(milliseconds: 320),
    bounce: 0.15,
  );
  static final thumbCurve = HubSpringCurve(thumbSpring);

  /// 按压缩放:按下缩到 [pressScale],松手回到 1。
  static const pressScale = 0.97;

  /// 弹层升起:快出、长尾减速;不回弹。
  static const sheetRise = Cubic(0.2, 0.9, 0.25, 1.0);

  /// 弹层收起(reverseCurve:反向播放时先慢后快)。
  static const sheetFall = Curves.easeOutCubic;

  /// 系统是否要求减少动画。
  static bool reduced(BuildContext context) => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  /// 灵动档:宿主经 [HubMotionScope] 注入(数值来自宿主的性能设置);
  /// 树上没有它(测试、独立预览)就是标准档。
  static bool fluid(BuildContext context) =>
      !reduced(context) && (context.dependOnInheritedWidgetOfExactType<HubMotionScope>()?.fluid ?? false);

  /// 灵动档下列表拉过头时回弹;否则交给平台默认(null)。
  static ScrollPhysics? scrollPhysics(BuildContext context) =>
      fluid(context) ? const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()) : null;

  /// 按系统设置取时长:要求减少动画时返回 0。
  static Duration of(BuildContext context, Duration duration) => reduced(context) ? Duration.zero : duration;

  /// 弹簧从 [from] 带着速度 [velocity] 落到 [to],准确停在 [to] 上(与宿主
  /// AppMotion.settle 同一实现)。
  static SpringSimulation settle(
    SpringDescription spring,
    double from,
    double to,
    double velocity, {
    bool landing = true,
    double extent = 1,
  }) {
    var start = velocity;
    if (landing) {
      final limit = (to - from) * spring.damping / (2 * spring.mass);
      start = limit > 0 ? math.min(velocity, limit) : math.max(velocity, limit);
    }
    return SpringSimulation(
      spring,
      from,
      to,
      start,
      snapToEnd: true,
      tolerance: Tolerance(distance: 0.001 * extent, velocity: double.infinity),
    );
  }
}

/// 告诉子树当前是不是灵动档([HubMotion.fluid])。宿主适配层按自家性能
/// 设置在 HubDesktopView 外挂一层;不挂就是标准档。
class HubMotionScope extends InheritedWidget {
  const HubMotionScope({super.key, required this.fluid, required super.child});

  final bool fluid;

  @override
  bool updateShouldNotify(HubMotionScope oldWidget) => fluid != oldWidget.fluid;
}

/// 把弹簧换算成曲线,给只认「曲线 + 时长」的接口(与宿主 SpringCurve 同一实现)。
class HubSpringCurve extends Curve {
  HubSpringCurve(SpringDescription spring, {double within = 0.002}) : this._(SpringSimulation(spring, 0, 1, 0), within);

  HubSpringCurve._(this._simulation, double within) : _seconds = _settleSeconds(_simulation, within);

  final SpringSimulation _simulation;
  final double _seconds;

  /// 配套的动画时长。
  Duration get duration => Duration(microseconds: (_seconds * Duration.microsecondsPerSecond).round());

  static double _settleSeconds(SpringSimulation simulation, double within) {
    const step = 0.004;
    var last = step;
    for (var t = step; t < 4; t += step) {
      if ((simulation.x(t) - 1).abs() > within) last = t + step;
    }
    return last;
  }

  @override
  double transformInternal(double t) => _simulation.x(t * _seconds);
}

/// 主题桥:宿主把自家 DshColors 的文字色翻译进来。缺省退 onSurfaceVariant。
class HubColors extends ThemeExtension<HubColors> {
  const HubColors({required this.textTertiary});

  /// 三级文字:分组小标题、搜索占位、整理提示、箭头。
  final Color textTertiary;

  static HubColors of(BuildContext context) =>
      Theme.of(context).extension<HubColors>() ??
      HubColors(textTertiary: Theme.of(context).colorScheme.onSurfaceVariant);

  @override
  HubColors copyWith({Color? textTertiary}) => HubColors(textTertiary: textTertiary ?? this.textTertiary);

  @override
  HubColors lerp(HubColors? other, double t) {
    if (other is! HubColors) return this;
    return HubColors(textTertiary: Color.lerp(textTertiary, other.textTertiary, t)!);
  }
}

/// 一种玻璃材质的全部参数(与宿主 GlassStyle 同构,值由宿主翻译注入)。
@immutable
class HubGlassStyle {
  const HubGlassStyle({
    required this.fill,
    required this.fallbackFill,
    required this.hairline,
    required this.rim,
    this.blurSigma = 0,
    this.saturation = 1,
    this.hairlineWidth = 0.5,
    this.shadows = const [],
  });

  /// 开启模糊时的填充(带透明度)。
  final Color fill;

  /// 关闭模糊时的填充(低端机、省电、「减少透明度」、高对比度模式)。
  final Color fallbackFill;

  /// 发丝描边:界定玻璃边缘。
  final Color hairline;
  final double hairlineWidth;

  /// 顶边高光起始色,向下 45% 渐隐到透明。
  final Color rim;

  /// 高斯模糊 σ(逻辑像素)。0 = 不模糊。
  final double blurSigma;

  /// 模糊后的饱和度增益(1 = 不变)。
  final double saturation;

  /// 只画在形状**外部**的投影。
  final List<BoxShadow> shadows;

  bool get blurs => blurSigma > 0;

  HubGlassStyle copyWith({
    Color? fill,
    Color? fallbackFill,
    Color? hairline,
    Color? rim,
    double? blurSigma,
    double? saturation,
    double? hairlineWidth,
    List<BoxShadow>? shadows,
  }) {
    return HubGlassStyle(
      fill: fill ?? this.fill,
      fallbackFill: fallbackFill ?? this.fallbackFill,
      hairline: hairline ?? this.hairline,
      rim: rim ?? this.rim,
      blurSigma: blurSigma ?? this.blurSigma,
      saturation: saturation ?? this.saturation,
      hairlineWidth: hairlineWidth ?? this.hairlineWidth,
      shadows: shadows ?? this.shadows,
    );
  }

  static HubGlassStyle lerp(HubGlassStyle a, HubGlassStyle b, double t) {
    return HubGlassStyle(
      fill: Color.lerp(a.fill, b.fill, t)!,
      fallbackFill: Color.lerp(a.fallbackFill, b.fallbackFill, t)!,
      hairline: Color.lerp(a.hairline, b.hairline, t)!,
      rim: Color.lerp(a.rim, b.rim, t)!,
      blurSigma: lerpDouble(a.blurSigma, b.blurSigma, t)!,
      saturation: lerpDouble(a.saturation, b.saturation, t)!,
      hairlineWidth: lerpDouble(a.hairlineWidth, b.hairlineWidth, t)!,
      shadows: BoxShadow.lerpList(a.shadows, b.shadows, t) ?? const [],
    );
  }
}

/// 玻璃层级(引擎只用得到这两档:card 躺在页面上不模糊,sheet 是弹层)。
enum HubGlassTier { sheet, card }

/// 主题桥:宿主把自家 DshSurfaces 的 card/sheet 材质与模糊总开关翻译进来。
/// 缺省退 ColorScheme 推导的实底面(测试够用)。
class HubGlassTheme extends ThemeExtension<HubGlassTheme> {
  const HubGlassTheme({
    required this.sheet,
    required this.card,
    this.blurEnabled = true,
  });

  final HubGlassStyle sheet;
  final HubGlassStyle card;

  /// 总开关。关掉后所有档都走 fallbackFill,不再创建 BackdropFilter。
  final bool blurEnabled;

  static HubGlassTheme of(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final HubGlassTheme? ext = theme.extension<HubGlassTheme>();
    if (ext != null) return ext;
    final ColorScheme scheme = theme.colorScheme;
    final Color ink = scheme.onSurface;
    return HubGlassTheme(
      sheet: HubGlassStyle(
        fill: scheme.surface.withValues(alpha: 0.9),
        fallbackFill: scheme.surface,
        hairline: ink.withValues(alpha: 0.07),
        rim: scheme.onSurface.withValues(alpha: 0.1),
        blurSigma: 24,
        saturation: 1.2,
        shadows: [BoxShadow(color: ink.withValues(alpha: 0.1), blurRadius: 32, offset: const Offset(0, 8))],
      ),
      card: HubGlassStyle(
        fill: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        fallbackFill: scheme.surfaceContainerHighest.withValues(alpha: 0.7),
        hairline: ink.withValues(alpha: 0.06),
        rim: scheme.onSurface.withValues(alpha: 0.06),
      ),
    );
  }

  @override
  HubGlassTheme copyWith({HubGlassStyle? sheet, HubGlassStyle? card, bool? blurEnabled}) => HubGlassTheme(
    sheet: sheet ?? this.sheet,
    card: card ?? this.card,
    blurEnabled: blurEnabled ?? this.blurEnabled,
  );

  @override
  HubGlassTheme lerp(HubGlassTheme? other, double t) {
    if (other is! HubGlassTheme) return this;
    return HubGlassTheme(
      sheet: HubGlassStyle.lerp(sheet, other.sheet, t),
      card: HubGlassStyle.lerp(card, other.card, t),
      blurEnabled: t < 0.5 ? blurEnabled : other.blurEnabled,
    );
  }
}

/// 分组小标题的字(与宿主 groupTitleStyle 同一种)。
TextStyle? hubGroupTitleStyle(BuildContext context) =>
    Theme.of(context).textTheme.labelLarge?.copyWith(color: HubColors.of(context).textTertiary);

/// 数字用等宽表格字(与宿主 AppType.tabular 同义)。
TextStyle hubTabular(TextStyle style) => style.copyWith(fontFeatures: const <FontFeature>[FontFeature.tabularFigures()]);
