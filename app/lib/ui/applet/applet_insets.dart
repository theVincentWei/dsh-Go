/// Keyboard-inset relay for the applet container.
///
/// Contract: the container never resizes the WebView (`resizeToAvoidBottomInset:
/// false`). A resize relayouts the whole page, and the IME animation reports
/// insets on every frame — resizing per frame would reflow the page per frame,
/// which is exactly the keyboard jank this exists to avoid. Instead the relay
/// pushes at most once per [sampleEvery] while the animation runs (so bottom
/// sheets roughly ride the keyboard), then pushes the settled final value once
/// frame silence of [settle] says the animation is over. Total page reflows for
/// a ~300ms keyboard: ~4, spread ≥90ms apart — versus per-frame (~20-35).
/// assets/applet/host.js maps the pushed pixels to the `--dsh-kb` CSS variable.
library;

import 'dart:async';

/// Rate-limited relay for per-frame IME inset updates: mid-animation samples at
/// most one per [sampleEvery], then a single final push on [settle] silence.
class KeyboardInsetRelay {
  KeyboardInsetRelay({
    required this.push,
    this.settle = const Duration(milliseconds: 120),
    this.sampleEvery = const Duration(milliseconds: 90),
  });

  /// Called with an inset in logical pixels (mid-animation sample or final).
  final void Function(double bottomPx) push;

  /// Frame silence that means the keyboard animation is over. Inset frames
  /// arrive per vsync while animating, so a gap of this length cannot happen
  /// mid-animation.
  final Duration settle;

  /// Minimum spacing between mid-animation pushes (~11 reflows/s worst case,
  /// versus 60-120/s for per-frame resizing).
  final Duration sampleEvery;

  Timer? _settleTimer;
  Timer? _sampleTimer;
  double _latest = 0;
  double _pushed = -1;

  /// Last value pushed to the page (what the page currently knows).
  double get pushed => _pushed < 0 ? 0 : _pushed;

  /// Latest raw value seen, settled or not (used to re-sync after reload).
  double get current => _latest;

  /// Feed one raw per-frame value. Frames during the animation reset the
  /// settle timer and keep the sampler armed; ticks push only what changed.
  void update(double bottomPx) {
    _latest = bottomPx;
    if (_latest != _pushed && _sampleTimer == null) {
      _sampleTimer = Timer.periodic(sampleEvery, (_) => _sample());
    }
    _settleTimer?.cancel();
    _settleTimer = Timer(settle, _settle);
  }

  /// Mid-animation sample: push what has arrived so far, unless the page is
  /// already caught up (e.g. a one-shot inset on old Android).
  void _sample() {
    if (_latest == _pushed) {
      _stopSampling();
      return;
    }
    _pushed = _latest;
    push(_pushed);
  }

  void _stopSampling() {
    _sampleTimer?.cancel();
    _sampleTimer = null;
  }

  void _settle() {
    _stopSampling();
    if (_latest == _pushed) return;
    _pushed = _latest;
    push(_pushed);
  }

  void dispose() {
    _stopSampling();
    _settleTimer?.cancel();
    _settleTimer = null;
  }
}
