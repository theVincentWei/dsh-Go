// 玻璃表面,拷贝自宿主 glass.dart 的 card/sheet 两档(材质值经
// HubGlassTheme 由宿主翻译注入;宿主的 DshSurfaces/性能设置之外的能力
// —— chrome/pill 档、圆形/胶囊、共享采样 —— 引擎用不到,不搬)。
// 「小程序」桌面上用到它的是分组管理弹层(卡片玻璃)与底部弹层本体。
//
// Portions derived from PiPilot (https://github.com/CikeSeven/pi_pilot), MIT,
// Copyright (c) 2026 CikeSeven.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

export '../theme.dart' show HubGlassStyle, HubGlassTheme, HubGlassTier;

/// 玻璃表面:**模糊背后的内容 → 叠半透明填充 → 发丝描边 + 顶边高光 →
/// 外投影**。[settled] 给会动的玻璃(升起的弹层):0 = 在动,不采样背景,
/// 用不透明填充;停稳后走向 1,模糊立刻开、藏在填充后面渐显。
class HubGlassSurface extends StatelessWidget {
  const HubGlassSurface({
    super.key,
    required this.tier,
    this.borderRadius,
    this.settled,
    this.child,
  });

  final HubGlassTier tier;

  /// 缺省:card 用 20、sheet 用 28(顶角)。
  final BorderRadiusGeometry? borderRadius;

  /// 会动的玻璃(升起、被拖动的弹层);null = 一直是玻璃。
  final double? settled;

  final Widget? child;

  BorderRadiusGeometry get _radius => borderRadius ?? switch (tier) {
    HubGlassTier.card => const BorderRadius.all(Radius.circular(20)),
    HubGlassTier.sheet => const BorderRadius.vertical(top: Radius.circular(28)),
  };

  ShapeBorder get _shape => RoundedSuperellipseBorder(borderRadius: _radius);

  @override
  Widget build(BuildContext context) {
    final HubGlassTheme surfaces = HubGlassTheme.of(context);
    final HubGlassStyle s = switch (tier) {
      HubGlassTier.card => surfaces.card,
      HubGlassTier.sheet => surfaces.sheet,
    };
    final highContrast = MediaQuery.maybeHighContrastOf(context) ?? false;
    final reduce = !surfaces.blurEnabled || highContrast;
    final useBlur = !reduce && s.blurs;
    final fill = useBlur
        ? Color.lerp(s.fallbackFill, s.fill, settled ?? 1)!
        : (reduce || s.blurs ? s.fallbackFill : s.fill);
    final shape = _shape;
    final textDirection = Directionality.maybeOf(context);

    Widget content = child ?? const SizedBox.shrink();
    content = CustomPaint(
      foregroundPainter: _GlassEdgePainter(
        shape: shape,
        hairline: s.hairline,
        hairlineWidth: s.hairlineWidth,
        rim: s.rim,
        textDirection: textDirection,
      ),
      child: DecoratedBox(
        decoration: ShapeDecoration(shape: shape, color: fill),
        child: content,
      ),
    );

    if (useBlur) {
      final config = _filterFor(s.blurSigma, s.saturation);
      final sampling = settled != 0;
      content = BackdropFilter(filterConfig: config, enabled: sampling, child: content);
      content = ClipRSuperellipse(borderRadius: _radius, child: content);
    }

    if (s.shadows.isNotEmpty) {
      content = CustomPaint(
        painter: _GlassShadowPainter(shape: shape, shadows: s.shadows, textDirection: textDirection),
        child: content,
      );
    }
    return content;
  }

  static ImageFilterConfig _filterFor(double sigma, double saturation) {
    final blur = ImageFilterConfig.blur(sigmaX: sigma, sigmaY: sigma, bounded: true);
    if (saturation == 1) return blur;
    return ImageFilterConfig.compose(outer: ImageFilterConfig(ColorFilter.matrix(_saturate(saturation))), inner: blur);
  }

  /// 保亮度的饱和度矩阵(Rec. 709 权重)。
  static List<double> _saturate(double s) {
    final r = 0.2126 * (1 - s);
    final g = 0.7152 * (1 - s);
    final b = 0.0722 * (1 - s);
    return <double>[
      r + s, g, b, 0, 0, //
      r, g + s, b, 0, 0, //
      r, g, b + s, 0, 0, //
      0, 0, 0, 1, 0, //
    ];
  }
}

/// 发丝描边 + 顶边高光。描边画在形状内侧,裁剪时不会被切掉一半。
class _GlassEdgePainter extends CustomPainter {
  _GlassEdgePainter({
    required this.shape,
    required this.hairline,
    required this.hairlineWidth,
    required this.rim,
    required this.textDirection,
  });

  final ShapeBorder shape;
  final Color hairline;
  final double hairlineWidth;
  final Color rim;
  final TextDirection? textDirection;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final width = math.max(hairlineWidth, 0.5);
    final path = shape.getOuterPath(rect.deflate(width / 2), textDirection: textDirection);
    if (hairline.a > 0) {
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..color = hairline,
      );
    }
    if (rim.a > 0) {
      final highlight = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(width, 0.8)
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [rim, rim.withValues(alpha: 0)],
          stops: const [0, 0.45],
        ).createShader(rect);
      canvas.drawPath(path, highlight);
    }
  }

  @override
  bool shouldRepaint(_GlassEdgePainter old) =>
      old.shape != shape ||
      old.hairline != hairline ||
      old.hairlineWidth != hairlineWidth ||
      old.rim != rim ||
      old.textDirection != textDirection;
}

/// 只在形状外部画的投影。
class _GlassShadowPainter extends CustomPainter {
  _GlassShadowPainter({required this.shape, required this.shadows, required this.textDirection});

  final ShapeBorder shape;
  final List<BoxShadow> shadows;
  final TextDirection? textDirection;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    var extent = 0.0;
    for (final s in shadows) {
      extent = math.max(extent, s.blurRadius * 2 + s.spreadRadius.abs() + s.offset.distance);
    }
    final outside = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(rect.inflate(extent + 2))
      ..addPath(shape.getOuterPath(rect, textDirection: textDirection), Offset.zero);
    canvas.save();
    canvas.clipPath(outside);
    for (final s in shadows) {
      canvas.drawPath(
        shape.getOuterPath(rect.shift(s.offset).inflate(s.spreadRadius), textDirection: textDirection),
        s.toPaint(),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GlassShadowPainter old) =>
      old.shape != shape || !_sameShadows(old.shadows, shadows) || old.textDirection != textDirection;

  static bool _sameShadows(List<BoxShadow> a, List<BoxShadow> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
