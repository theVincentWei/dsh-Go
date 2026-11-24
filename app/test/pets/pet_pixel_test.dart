// Sizes are exact: every pack — pixel art and hi-res art alike — renders its
// contentBox at exactly the tier's body height on every device, sampled
// linearly so fractional scales stay smooth (docs/design/pets.md §2.10).

import 'dart:typed_data';

import 'package:dsh_app/pets/pet_pack.dart';
import 'package:dsh_app/pets/pet_sheets.dart';
import 'package:dsh_app/pets/pet_state.dart';
import 'package:dsh_app/ui/pets/pet_sprite.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

const ratios = [2.0, 2.625, 2.75, 3.0, 3.5];

/// Renders [anim]'s first frame at [size] on a [dpr] view, at the origin of a
/// repaint boundary (a device-pixel corner), and returns its RGBA bytes plus
/// the drawn logical size.
Future<(Uint8List, int, int, double)> render(
  WidgetTester tester,
  PetPack pack,
  PetAnimation anim,
  PetSize size,
  double dpr,
) async {
  tester.view.devicePixelRatio = dpr;
  tester.view.physicalSize = Size(400 * dpr, 400 * dpr);
  addTearDown(tester.view.reset);
  await warmSheets(tester, pack, [anim]);
  final scale = petScale(pack, size, dpr);
  final key = GlobalKey();
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: RepaintBoundary(
          key: key,
          child: PetSprite(pack: pack, anim: anim, scale: scale, still: true),
        ),
      ),
    ),
  );
  await tester.pump();
  final bytes = await tester.runAsync(() async {
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: dpr);
    final data = await image.toByteData();
    final w = image.width;
    final h = image.height;
    image.dispose();
    return (data!.buffer.asUint8List(), w, h);
  });
  return (bytes!.$1, bytes.$2, bytes.$3, scale);
}

int px(Uint8List rgba, int w, int x, int y) {
  final i = (y * w + x) * 4;
  return rgba[i] << 24 | rgba[i + 1] << 16 | rgba[i + 2] << 8 | rgba[i + 3];
}

void main() {
  tearDown(PetSheets.instance.clear);

  test('sizes are exact on every device: the contentBox lands on the tier dp', () {
    for (final pack in [deepy, girl]) {
      for (final dpr in ratios) {
        for (final size in PetSize.values) {
          expect(
            petScale(pack, size, dpr),
            size.bodyHeight / pack.contentBox.height,
            reason: '${pack.id} ${size.name} at $dpr×',
          );
        }
      }
    }
  });

  test('the out-of-app overlay sizes the same: pinned here and in PetPackTest.kt', () {
    // Kotlin PetPack.screenScale = size.dp × density ÷ contentBox.h — the
    // same formula as petScale × dpr. Change one, change both.
    const expected = [
      ('whale-girl', 2.0),
      ('whale-girl', 2.625),
      ('whale-girl', 3.5),
      ('deepy-whale', 2.0),
      ('deepy-whale', 3.5),
    ];
    for (final (id, dpr) in expected) {
      final pack = id == 'whale-girl' ? girl : deepy;
      // physical px per art px = tier dp × dpr ÷ contentBox.h.
      final physicalPerArt = petScale(pack, PetSize.medium, dpr) * dpr;
      expect(physicalPerArt, PetSize.medium.bodyHeight * dpr / pack.contentBox.height,
          reason: '$id at $dpr×');
    }
  });

  testWidgets('鲸娘 at 2.75x, medium: renders whole at the exact body height', (tester) async {
    final anim = girl.animFor(PetStateName.idle);
    final (rgba, w, h, scale) = await render(tester, girl, anim, PetSize.medium, 2.75);
    // The canvas lands on ceil(canvas × scale × dpr) physical pixels.
    expect(w, (girl.canvas.width * scale * 2.75).ceil());
    expect(h, (girl.canvas.height * scale * 2.75).ceil());
    var painted = 0;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        if (px(rgba, w, x, y) & 0xff != 0) painted++;
      }
    }
    expect(painted, greaterThan(500));
  });

  testWidgets('Deepy at 3.5x, medium: renders whole at the exact body height', (tester) async {
    final anim = deepy.animFor(PetStateName.idle);
    final (rgba, w, h, scale) = await render(tester, deepy, anim, PetSize.medium, 3.5);
    expect(w, (deepy.canvas.width * scale * 3.5).ceil());
    expect(h, (deepy.canvas.height * scale * 3.5).ceil());
    var painted = 0;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        if (px(rgba, w, x, y) & 0xff != 0) painted++;
      }
    }
    expect(painted, greaterThan(500));
  });
}
