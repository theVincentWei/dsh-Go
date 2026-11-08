import 'package:fake_async/fake_async.dart';
import 'package:dsh_app/ui/applet/applet_insets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // One keyboard show/hide cycle, frames every 10ms like the IME animation.
  group('KeyboardInsetRelay', () {
    test('animating keyboard: rate-limited samples + settled final push', () {
      fakeAsync((async) {
        final List<double> pushes = <double>[];
        final KeyboardInsetRelay relay = KeyboardInsetRelay(push: pushes.add);

        // Show: insets ramp 0 → 300 over 300ms of per-frame updates. Sample
        // ticks at 90/180/270ms see the latest frame seen by then; settle
        // lands 120ms after the last frame.
        for (int i = 0; i <= 30; i++) {
          relay.update(i * 10.0);
          async.elapse(const Duration(milliseconds: 10));
        }
        async.elapse(const Duration(milliseconds: 150));

        expect(pushes, <double>[80, 170, 260, 300]);
        expect(relay.pushed, 300);
        expect(relay.current, 300);
        relay.dispose();
      });
    });

    test('one-shot inset (no animation): exactly one push, no stray samples', () {
      fakeAsync((async) {
        final List<double> pushes = <double>[];
        final KeyboardInsetRelay relay = KeyboardInsetRelay(push: pushes.add);

        relay.update(300);
        async.elapse(const Duration(milliseconds: 400));

        expect(pushes, <double>[300], reason: 'sampler must stop once the page is caught up');
        relay.dispose();
      });
    });

    test('hide back to 0 emits its own sampled sequence', () {
      fakeAsync((async) {
        final List<double> pushes = <double>[];
        final KeyboardInsetRelay relay = KeyboardInsetRelay(push: pushes.add);

        for (int i = 0; i <= 30; i++) {
          relay.update(i * 10.0);
          async.elapse(const Duration(milliseconds: 10));
        }
        async.elapse(const Duration(milliseconds: 150));
        for (int i = 29; i >= 0; i--) {
          relay.update(i * 10.0);
          async.elapse(const Duration(milliseconds: 10));
        }
        async.elapse(const Duration(milliseconds: 150));

        expect(pushes, <double>[80, 170, 260, 300, 210, 120, 30, 0]);
        relay.dispose();
      });
    });

    test('repeated identical values cause no redundant pushes', () {
      fakeAsync((async) {
        final List<double> pushes = <double>[];
        final KeyboardInsetRelay relay = KeyboardInsetRelay(push: pushes.add);

        relay.update(300);
        async.elapse(const Duration(milliseconds: 400));
        expect(pushes, <double>[300]);

        // Rotation-style MediaQuery rebuilds re-feed the same settled value.
        relay.update(300);
        relay.update(300);
        async.elapse(const Duration(milliseconds: 400));
        expect(pushes, <double>[300], reason: 'no change, no push');
        relay.dispose();
      });
    });

    test('dispose cancels pending pushes; initial closed state pushes 0 once', () {
      fakeAsync((async) {
        final List<double> pushes = <double>[];
        final KeyboardInsetRelay relay = KeyboardInsetRelay(push: pushes.add);

        expect(relay.pushed, 0);
        relay.update(0);
        async.elapse(const Duration(milliseconds: 200));
        expect(pushes, <double>[0], reason: 'page is initialized to the closed state');

        relay.update(250);
        relay.dispose();
        async.elapse(const Duration(milliseconds: 400));
        expect(pushes, <double>[0], reason: 'timers cancelled, nothing pushes after dispose');
        expect(relay.current, 250);
      });
    });
  });
}
