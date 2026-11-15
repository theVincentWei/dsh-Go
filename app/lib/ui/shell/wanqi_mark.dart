import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../state/app_info.dart';
import '../theme/theme.dart';
import 'wanqi_glyph.g.dart';

/// The 万器 mark: the infinity ring and the four-point star from the launcher
/// icon, drawn from the 108-grid masters in `assets/brand/` (generated into
/// [WanqiGlyph] by `tool/make_wanqi_mark.py`).
///
/// Two colorways, the same two the launcher ships:
/// - dark pages: silver ring `#D9D9D9`, gold star `#CEC045`;
/// - light pages: the brand navy ring `#071328`, gold star.
///
/// - Plain mark: the ring + star at [size] on whatever is behind them — the
///   welcome page's gradient is the disc.
/// - [disc]: the launcher's badge, a navy circle with the mark at the icon's
///   own 48 % (splash, about, update sheet, QR plate).
/// - [color]: one flat tint for ring and star (quiet footers, watermarks).
class WanqiMark extends StatelessWidget {
  const WanqiMark({super.key, this.size = 96, this.disc = false, this.color});

  /// Side of the square the mark is drawn in (its 108-unit grid, scaled).
  final double size;

  /// Draw the launcher badge: a navy disc with the mark at the icon's scale.
  final bool disc;

  /// A flat tint for ring and star instead of the two brand colors.
  final Color? color;

  static const navy = Color(0xFF071328);
  static const silver = Color(0xFFD9D9D9);
  static const gold = Color(0xFFCEC045);

  /// Width / height of the mark's ink (ring + star): a wide, low emblem.
  static final aspect = WanqiGlyph.inkBox.width / WanqiGlyph.inkBox.height;

  /// The mark is balanced inside its ink box, so a centred glyph is already
  /// optically centred; the shift stays for layouts that ask for it.
  static const visualCentre = Offset(0.5, 0.5);

  /// How far to move a glyph of [size] so its visual centre sits on the centre
  /// of the space it is centred in (zero: it already does).
  static Offset opticalShift(double size) => Offset.zero;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final ring = color ?? (disc || dark ? silver : navy);
    return Semantics(
      label: AppInfo.name,
      image: true,
      child: CustomPaint(
        size: Size.square(size),
        painter: _WanqiPainter(ring: ring, star: color ?? gold, disc: disc),
      ),
    );
  }
}

class _WanqiPainter extends CustomPainter {
  const _WanqiPainter({required this.ring, required this.star, required this.disc});

  final Color ring;
  final Color star;
  final bool disc;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / WanqiGlyph.grid);
    if (disc) {
      canvas.drawCircle(const Offset(54, 54), 54, Paint()..color = WanqiMark.navy);
      // The launcher's foreground layer: the mark at 48 % of the icon's square.
      canvas
        ..save()
        ..translate(54, 54)
        ..scale(0.48)
        ..translate(-54, -54);
    }
    canvas.drawPath(WanqiGlyph.ring, Paint()..color = ring);
    canvas.drawPath(WanqiGlyph.star, Paint()..color = star);
    if (disc) canvas.restore();
    canvas.restore();
  }

  @override
  bool shouldRepaint(_WanqiPainter oldDelegate) =>
      oldDelegate.ring != ring || oldDelegate.star != star || oldDelegate.disc != disc;
}

/// The mark and a wordmark on one line.
///
/// Everything follows the word's size (0.95 × [height] by default, times the
/// app's text scale):
/// - the glyph is [glyphScale] × the word's size tall;
/// - its box centre sits on the centre of the word's main band: the x-height
///   for a lowercase word, the cap height for capitals;
/// - [gapScale] × the word's size separates the glyph's ink from the word.
class WanqiLockup extends StatelessWidget {
  const WanqiLockup({
    super.key,
    this.height = 20,
    this.fontSize,
    this.label = AppInfo.wordmark,
    this.color,
    this.glyphColor,
  });

  /// The lockup's size; the word is set at 0.95 × this unless [fontSize] is given.
  final double height;

  /// The word's size, overriding the one derived from [height].
  final double? fontSize;

  final String label;

  /// The word's colour (default: onSurface).
  final Color? color;

  /// A flat glyph tint instead of the colour mark.
  final Color? glyphColor;

  /// Glyph height / word size.
  static const glyphScale = 1.25;

  /// Gap between the glyph and the word / word size.
  static const gapScale = 0.36;

  /// x-height and cap height of the system sans, in ems (Roboto: 1082 and 1456 of
  /// 2048 units).
  static const xHeight = 0.528;
  static const capHeight = 0.711;

  /// Height above the baseline of the line the glyph centres on, for [label] set at
  /// [size].
  static double centreRise(String label, double size) =>
      (label.contains(RegExp('[a-z]')) ? xHeight : capHeight) * size / 2;

  /// Where the word starts, from the lockup's left edge, for a word drawn at [size]
  /// (after text scaling): glyph width + gap.
  static double wordInset(double size) => size * glyphScale * WanqiMark.aspect + size * gapScale;

  double get _size => fontSize ?? height * 0.95;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // The word's drawn size: the glyph and the gap scale with the text.
    final drawn = MediaQuery.textScalerOf(context).scale(_size);
    final glyph = drawn * glyphScale;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        _GlyphBaseline(
          // A baseline this far below the glyph's top puts its centre on the
          // word's x-height (or cap-height) centre when the row aligns baselines.
          baseline: glyph * WanqiMark.visualCentre.dy + centreRise(label, drawn),
          child: WanqiMark(size: glyph, color: glyphColor),
        ),
        SizedBox(width: drawn * gapScale),
        Text(
          label,
          style: AppType.wordmark(size: _size, color: color ?? scheme.onSurface),
        ),
      ],
    );
  }
}

/// Reports [baseline] as its child's alphabetic baseline.
class _GlyphBaseline extends SingleChildRenderObjectWidget {
  const _GlyphBaseline({required this.baseline, required super.child});

  final double baseline;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderGlyphBaseline(baseline);

  @override
  void updateRenderObject(BuildContext context, _RenderGlyphBaseline renderObject) {
    renderObject.baseline = baseline;
  }
}

class _RenderGlyphBaseline extends RenderProxyBox {
  _RenderGlyphBaseline(this._baseline);

  double _baseline;

  set baseline(double value) {
    if (value == _baseline) return;
    _baseline = value;
    markNeedsLayout();
  }

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) => _baseline;

  @override
  double? computeDryBaseline(BoxConstraints constraints, TextBaseline baseline) => _baseline;
}
