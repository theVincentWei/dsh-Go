import 'package:flutter/material.dart';

import '../../state/app_info.dart';
import 'wanqi_glyph.g.dart';

/// The 万器 mark: the infinity ring and the four-point star from the launcher
/// icon, drawn from the 108-grid masters in `assets/brand/` (generated into
/// [WanqiGlyph] by `tool/make_wanqi_mark.py`).
///
/// Two colorways, the same two the launcher ships:
/// - dark pages: silver ring `#D9D9D9`, gold star `#CEC045`;
/// - light pages: the brand navy ring `#071328`, gold star.
///
/// No disc is drawn by default: the welcome page's own circular gradient is the
/// disc (the welcome page's gradient). Pass [disc] for a self-contained badge — splash,
/// about page, share cards.
class WanqiMark extends StatelessWidget {
  const WanqiMark({super.key, this.size = 96, this.disc = false});

  /// Side of the square the mark is drawn in (its 108-unit grid, scaled).
  final double size;

  /// Draw the navy disc behind the ring (the launcher icon look).
  final bool disc;

  static const navy = Color(0xFF071328);
  static const silver = Color(0xFFD9D9D9);
  static const gold = Color(0xFFCEC045);

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Semantics(
      label: AppInfo.name,
      image: true,
      child: CustomPaint(
        size: Size.square(size),
        painter: _WanqiPainter(ring: disc || dark ? silver : navy, disc: disc),
      ),
    );
  }
}

class _WanqiPainter extends CustomPainter {
  const _WanqiPainter({required this.ring, required this.disc});

  final Color ring;
  final bool disc;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / WanqiGlyph.grid);
    if (disc) {
      canvas.drawCircle(const Offset(54, 54), 54, Paint()..color = WanqiMark.navy);
    }
    canvas.drawPath(WanqiGlyph.ring, Paint()..color = ring);
    canvas.drawPath(WanqiGlyph.star, Paint()..color = WanqiMark.gold);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_WanqiPainter oldDelegate) => oldDelegate.ring != ring || oldDelegate.disc != disc;
}
