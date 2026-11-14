import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../state/app_info.dart';

/// The 万器 mark: the launcher's infinity ring and star, traced as vectors from
/// the 1024px icon master into the launcher's 108 grid, on the brand's navy
/// gradient circle. Silver ring #D9D9D9, gold star #CEC045, navy #071328.
/// The ring's fills are even-odd, so the weave gaps in the crossing stay open.
class WanqiMark extends StatelessWidget {
  const WanqiMark({super.key, this.size = 96});

  /// Side of the square the mark paints in (the navy circle's diameter).
  final double size;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: AppInfo.wordmark,
      image: true,
      child: CustomPaint(size: Size.square(size), painter: _WanqiPainter()),
    );
  }
}

class _WanqiPainter extends CustomPainter {
  static const _navy = Color(0xFF071328);
  static const _navyLight = Color(0xFF143059);
  static const _silver = Color(0xFFD9D9D9);
  static const _gold = Color(0xFFCEC045);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 108);

    // The circle: the icon's navy, lit a little towards the top left.
    canvas.drawCircle(
      const Offset(54, 54),
      54,
      Paint()
        ..shader = ui.Gradient.radial(
          const Offset(54, 42),
          62,
          [_navyLight, _navy],
        ),
    );

    // The infinity ring (thin double-line left loop, thick right loop) with
    // its weave gaps; even-odd keeps the loop's eye open.
    final ring = Path()..fillType = PathFillType.evenOdd;
    ring.moveTo(66.71, 41.0);
    ring.cubicTo(67.54, 44.26, 67.48, 45.24, 67.0, 45.56);
    ring.cubicTo(66.52, 45.88, 65.52, 45.64, 64.75, 45.92);
    ring.cubicTo(63.98, 46.2, 64.79, 44.22, 62.38, 47.25);
    ring.cubicTo(59.96, 50.28, 53.1, 60.68, 50.25, 64.11);
    ring.cubicTo(47.4, 67.54, 46.58, 67.08, 45.25, 67.83);
    ring.cubicTo(43.92, 68.58, 43.54, 68.54, 42.25, 68.62);
    ring.cubicTo(40.96, 68.7, 39.06, 68.81, 37.5, 68.33);
    ring.cubicTo(35.94, 67.85, 34.16, 66.76, 32.89, 65.75);
    ring.cubicTo(31.63, 64.74, 30.71, 63.71, 29.92, 62.25);
    ring.cubicTo(29.13, 60.79, 28.47, 58.58, 28.17, 57.0);
    ring.cubicTo(27.87, 55.42, 28.01, 54.0, 28.13, 52.75);
    ring.cubicTo(28.26, 51.5, 28.44, 50.64, 28.92, 49.5);
    ring.cubicTo(29.4, 48.36, 30.21, 46.94, 31.0, 45.89);
    ring.cubicTo(31.79, 44.85, 32.81, 43.91, 33.64, 43.25);
    ring.cubicTo(34.48, 42.59, 35.11, 42.28, 36.0, 41.92);
    ring.cubicTo(36.89, 41.57, 37.92, 41.26, 39.0, 41.13);
    ring.cubicTo(40.08, 41.0, 40.94, 40.69, 42.5, 41.13);
    ring.cubicTo(44.06, 41.57, 46.68, 42.48, 48.36, 43.75);
    ring.cubicTo(50.04, 45.02, 51.79, 47.67, 52.58, 48.75);
    ring.cubicTo(53.37, 49.83, 53.03, 50.0, 53.12, 50.25);
    ring.cubicTo(51.73, 49.65, 49.11, 46.23, 47.86, 45.0);
    ring.cubicTo(46.61, 43.77, 45.93, 43.61, 45.0, 43.17);
    ring.cubicTo(44.07, 42.74, 43.29, 42.5, 42.25, 42.38);
    ring.cubicTo(41.21, 42.25, 39.88, 42.21, 38.75, 42.42);
    ring.cubicTo(37.62, 42.64, 36.81, 42.7, 35.5, 43.67);
    ring.cubicTo(34.19, 44.64, 31.94, 46.69, 30.92, 48.25);
    ring.cubicTo(29.9, 49.81, 29.58, 51.29, 29.38, 53.0);
    ring.cubicTo(29.17, 54.71, 29.41, 57.08, 29.67, 58.5);
    ring.cubicTo(29.93, 59.92, 29.95, 60.24, 30.92, 61.5);
    ring.cubicTo(31.89, 62.76, 34.19, 65.11, 35.5, 66.08);
    ring.cubicTo(36.81, 67.05, 37.67, 67.11, 38.75, 67.33);
    ring.cubicTo(39.83, 67.54, 41.08, 67.45, 42.0, 67.37);
    ring.cubicTo(42.92, 67.29, 43.25, 67.29, 44.25, 66.83);
    ring.cubicTo(45.25, 66.37, 46.69, 65.84, 48.0, 64.62);
    ring.cubicTo(49.31, 63.4, 51.36, 60.6, 52.08, 59.5);
    ring.cubicTo(52.8, 58.4, 52.28, 58.25, 52.32, 58.0);
    ring.cubicTo(50.24, 58.6, 48.27, 61.65, 47.0, 62.87);
    ring.cubicTo(45.73, 64.09, 44.58, 64.66, 43.25, 65.08);
    ring.cubicTo(41.92, 65.49, 40.17, 65.5, 39.0, 65.37);
    ring.cubicTo(37.83, 65.25, 37.26, 65.06, 36.25, 64.33);
    ring.cubicTo(35.24, 63.6, 33.77, 62.47, 32.92, 61.0);
    ring.cubicTo(32.07, 59.53, 31.34, 57.08, 31.13, 55.5);
    ring.cubicTo(30.92, 53.92, 31.26, 52.79, 31.67, 51.5);
    ring.cubicTo(32.09, 50.21, 32.99, 48.68, 33.63, 47.75);
    ring.cubicTo(34.27, 46.82, 34.77, 46.43, 35.5, 45.92);
    ring.cubicTo(36.23, 45.41, 36.71, 44.88, 38.0, 44.67);
    ring.cubicTo(39.29, 44.46, 41.92, 44.43, 43.25, 44.67);
    ring.cubicTo(44.58, 44.91, 44.7, 44.86, 46.0, 46.13);
    ring.cubicTo(47.3, 47.39, 50.23, 51.23, 51.08, 52.25);
    ring.cubicTo(46.0, 47.74, 44.98, 46.81, 44.25, 46.42);
    ring.cubicTo(43.52, 46.03, 43.08, 45.71, 42.0, 45.67);
    ring.cubicTo(40.92, 45.63, 39.01, 45.66, 37.75, 46.17);
    ring.cubicTo(36.49, 46.69, 35.27, 47.65, 34.42, 48.75);
    ring.cubicTo(33.57, 49.85, 32.92, 51.33, 32.63, 52.75);
    ring.cubicTo(32.34, 54.17, 32.46, 56.0, 32.67, 57.25);
    ring.cubicTo(32.89, 58.5, 33.34, 59.33, 33.92, 60.25);
    ring.cubicTo(34.5, 61.17, 35.42, 62.15, 36.14, 62.75);
    ring.cubicTo(36.87, 63.35, 37.23, 63.61, 38.25, 63.83);
    ring.cubicTo(39.27, 64.05, 41.17, 64.2, 42.25, 64.08);
    ring.cubicTo(43.33, 63.95, 44.03, 63.51, 44.75, 63.08);
    ring.cubicTo(45.47, 62.65, 44.19, 64.66, 46.56, 61.5);
    ring.cubicTo(48.94, 58.34, 56.34, 47.39, 59.0, 44.13);
    ring.cubicTo(61.66, 40.86, 61.22, 42.44, 62.5, 41.92);
    ring.cubicTo(63.78, 41.4, 65.54, 41.12, 66.71, 41.0);
    ring.cubicTo(67.87, 40.88, 68.74, 40.99, 69.5, 41.17);
    ring.cubicTo(70.26, 41.35, 70.96, 41.94, 71.25, 42.09);
    ring.close();
    ring.moveTo(77.4, 47.75);
    ring.cubicTo(61.67, 61.69, 62.62, 62.87, 63.75, 63.33);
    ring.cubicTo(64.88, 63.79, 66.79, 64.16, 68.0, 64.12);
    ring.cubicTo(69.21, 64.08, 69.95, 63.85, 71.0, 63.08);
    ring.cubicTo(72.05, 62.31, 73.6, 60.72, 74.33, 59.5);
    ring.cubicTo(75.05, 58.28, 75.23, 57.04, 75.37, 55.75);
    ring.cubicTo(75.51, 54.46, 74.86, 53.06, 75.17, 51.75);
    ring.cubicTo(75.49, 50.44, 76.77, 48.54, 77.25, 47.88);
    ring.cubicTo(77.73, 47.21, 77.71, 47.31, 78.06, 47.75);
    ring.cubicTo(78.41, 48.19, 79.03, 49.04, 79.33, 50.5);
    ring.cubicTo(79.63, 51.96, 80.08, 54.58, 79.87, 56.5);
    ring.cubicTo(79.66, 58.42, 79.0, 60.38, 78.08, 62.0);
    ring.cubicTo(77.16, 63.62, 75.66, 65.2, 74.36, 66.25);
    ring.cubicTo(73.05, 67.3, 71.93, 67.98, 70.25, 68.33);
    ring.cubicTo(68.57, 68.67, 66.21, 68.87, 64.25, 68.33);
    ring.cubicTo(62.29, 67.78, 60.04, 66.45, 58.5, 65.06);
    ring.cubicTo(56.96, 63.67, 55.16, 61.47, 54.99, 60.0);
    ring.cubicTo(54.82, 58.53, 57.08, 56.87, 57.5, 56.24);
    ring.close();
    canvas.drawPath(ring, Paint()..color = _silver);

    // The four-point gold star, on the ring's top right.
    final star = Path();
    star.moveTo(73.65, 39.5);
    star.lineTo(74.25, 51.1);
    star.cubicTo(72.9, 49.94, 72.33, 47.96, 71.5, 47.13);
    star.cubicTo(70.67, 46.29, 68.73, 45.77, 68.18, 45.5);
    star.cubicTo(72.3, 42.44, 73.13, 40.23, 73.5, 39.65);
    star.cubicTo(73.87, 39.06, 73.89, 38.88, 74.31, 39.5);
    star.cubicTo(74.72, 40.12, 75.12, 42.41, 76.0, 43.37);
    star.cubicTo(76.88, 44.33, 79.01, 44.94, 79.61, 45.25);
    star.close();
    canvas.drawPath(star, Paint()..color = _gold);

    canvas.restore();
  }

  @override
  bool shouldRepaint(_WanqiPainter oldDelegate) => false;
}
