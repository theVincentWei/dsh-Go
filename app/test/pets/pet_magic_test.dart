// The pet's vanishing act, measured (docs/design/pets.md §12 #21): its first
// appearance on a stage pops out of the perch in dust; a panel over it drains
// it back into the perch; reduced motion does neither. Once a spell is done
// the body draws untransformed again, so the geometry tests' pixels stay
// exact.

import 'dart:math' as math;

import 'package:dsh_app/pets/pet_signals.dart';
import 'package:dsh_app/pets/pet_sheets.dart';
import 'package:dsh_app/pets/pet_state.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/pets/pet_magic.dart';
import 'package:dsh_app/ui/pets/pet_stage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

late TestClock clock;
late ProviderContainer container;

final _dust = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is PetDustPainter);
final _bodyTransform = find.ancestor(of: find.byKey(const ValueKey('pet-body')), matching: find.byType(Transform));

Future<void> pumpPet(WidgetTester tester) async {
  usePhoneView(tester);
  await warmSheets(tester, deepy, [deepy.animFor(PetStateName.idle)]);
  await tester.pumpWidget(testApp(const ChatBottomHarness(), overrides: petOverrides(pack: deepy, clock: clock)));
  container = ProviderScope.containerOf(tester.element(find.byType(ChatBottomHarness)));
  for (var i = 0; i < 4; i++) {
    await tester.pump();
  }
}

/// The stage through the entry spell's first frames: pumps in small steps
/// until the sprite's first sheet has shown and the spell armed. One extra
/// frame afterwards: the spell's ticker starts inside the arming build, so its
/// first tick lands on the next pump.
Future<void> pumpUntilArmed(WidgetTester tester) async {
  await pumpPet(tester);
  for (var i = 0; i < 30 && petLayer(tester).magicKind == null; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  await tester.pump(const Duration(milliseconds: 16));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    clock = TestClock();
    PetLayer.random = math.Random(7);
  });
  tearDown(PetSheets.instance.clear);

  group('magic in / out', () {
    testWidgets('first appearance: pops out of the perch in dust', (tester) async {
      await pumpUntilArmed(tester);
      final layer = petLayer(tester);
      expect(layer.magicKind, PetMagic.enter);
      expect(layer.magicPlaying, isTrue);
      expect(_dust, findsOneWidget);
      expect(_bodyTransform, findsOneWidget, reason: 'the pop is under way');
      await tester.pump(PetMetrics.magicIn);
      await tester.pump();
      expect(layer.magicKind, isNull);
      expect(layer.magicPlaying, isFalse);
      expect(_dust, findsNothing);
      expect(_bodyTransform, findsNothing, reason: 'the spell leaves no transform behind');
      // Settled: untransformed, the foot line exact on the composer's edge.
      final composer = tester.getRect(find.byType(Composer));
      final s = petScaleOn(tester, deepy);
      expect((petCanvas(tester).top + deepy.baseline * s - composer.top).abs(), lessThanOrEqualTo(0.5));
    });

    testWidgets('a panel over it: drains back into the perch', (tester) async {
      await pumpUntilArmed(tester);
      await tester.pump(PetMetrics.magicIn);
      await tester.pump();
      expect(petLayer(tester).magicKind, isNull, reason: 'the entry spell is done');
      container.read(harnessConfigProvider.notifier).set(const HarnessConfig(cover: true));
      // The cover reaches the build through the poll's post-frame callback:
      // one pump to see it, one to arm the exit spell, one for the spell's
      // ticker to initialize, then the spell itself.
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      final layer = petLayer(tester);
      expect(layer.magicKind, PetMagic.exit);
      expect(layer.magicPlaying, isTrue);
      expect(_dust, findsOneWidget);
      await tester.pump(PetMetrics.magicOut);
      await tester.pump();
      expect(layer.magicKind, isNull);
      expect(_dust, findsNothing);
      final opacity = tester.widget<AnimatedOpacity>(
        find.ancestor(of: find.byKey(const ValueKey('pet-body')), matching: find.byType(AnimatedOpacity)),
      );
      expect(opacity.opacity, 0);
    });

    testWidgets('reduced motion: no spell, straight in', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(
        disableAnimations: true,
      );
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      await pumpPet(tester);
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      final layer = petLayer(tester);
      expect(layer.magicKind, isNull);
      expect(layer.magicPlaying, isFalse);
      expect(_dust, findsNothing);
      expect(_bodyTransform, findsNothing);
      expect(container.read(petLayerShownProvider), isTrue);
    });
  });
}
