// The pet's vanishing act (docs/design/pets.md §12 #21): when the layer starts
// showing the pet it pops out of its perch in a swirl of dust, and when it
// hides while still mounted (a panel over it, a hidden hour, a pack swap) it
// shrinks away in one. The layer drives the clock and the body's transform;
// this file only paints the dust.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Which way the magic goes.
enum PetMagic { enter, exit }

/// The dust the magic swirls: small diamonds flying into the body as it pops
/// in, out of it as it vanishes. Deterministic per [seed], so a rebuild never
/// reshuffles a spell mid-flight.
class PetDustPainter extends CustomPainter {
  PetDustPainter({
    required this.kind,
    required this.t,
    required this.seed,
    required this.body,
    required this.colors,
  }) : _specks = _motes(seed);

  final PetMagic kind;

  /// The spell's progress, 0..1.
  final double t;

  /// Re-seeded per spell.
  final int seed;

  /// The body's rect, in the same coordinates the painter draws in.
  final Rect body;

  final List<Color> colors;

  /// Dust motes per spell.
  static const count = 12;

  final List<_Mote> _specks;

  static List<_Mote> _motes(int seed) {
    final r = math.Random(seed);
    return [
      for (var i = 0; i < count; i++)
        _Mote(
          r.nextDouble() * math.pi * 2,
          0.45 + r.nextDouble() * 0.55,
          2.0 + r.nextDouble() * 2.0,
          r.nextDouble() * 0.3,
          (r.nextBool() ? 1 : -1) * (0.5 + r.nextDouble()),
        ),
    ];
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Near the foot: the dust gathers where the pet grows out of its perch.
    final centre = Offset(body.left + body.width / 2, body.top + body.height * 0.8);
    final reach = (body.width + body.height) * 0.55 + 16;
    for (final (i, m) in _specks.indexed) {
      final local = ((t - m.delay) / (1 - m.delay)).clamp(0.0, 1.0);
      if (local <= 0) continue;
      // In: the mote starts far and lands on the body. Out: the reverse.
      final flying = kind == PetMagic.enter ? 1 - Curves.easeIn.transform(local) : Curves.easeOut.transform(local);
      final o = (kind == PetMagic.enter ? Curves.easeOut.transform(local) * (1 - local) * 1.4 : 1 - local).clamp(
        0.0,
        1.0,
      );
      if (o <= 0.02) continue;
      final d = m.size * (kind == PetMagic.enter ? 1.0 : 1 - 0.4 * local);
      final paint = Paint()..color = colors[i % colors.length].withValues(alpha: o);
      canvas.save();
      canvas.translate(
        centre.dx + math.cos(m.angle) * reach * m.radius * flying,
        centre.dy + math.sin(m.angle) * reach * m.radius * flying,
      );
      canvas.rotate(m.angle + m.spin * local);
      canvas.drawRect(Rect.fromCenter(center: Offset.zero, width: d, height: d), paint);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(PetDustPainter old) =>
      old.kind != kind || old.t != t || old.seed != seed || old.body != body || !listEquals(old.colors, colors);
}

class _Mote {
  const _Mote(this.angle, this.radius, this.size, this.delay, this.spin);

  /// Around the body's centre, in radians.
  final double angle;

  /// Of the spell's reach, 0..1.
  final double radius;

  /// The mote's edge, logical px.
  final double size;

  /// The share of [t] the mote waits out before it takes off.
  final double delay;

  /// Radians the mote turns over its flight, signed.
  final double spin;
}
