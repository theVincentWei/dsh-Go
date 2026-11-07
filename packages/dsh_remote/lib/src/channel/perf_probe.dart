/// Temporary download-jank probe for the DSH Remote receive path.
///
/// Builds without `--dart-define=DSH_PERF_PROBE=true` constant-fold every
/// call site away: the probe adds nothing to them. With the flag, the relay
/// receive path accumulates its stage times and prints one line every 2 s
/// (goes to logcat under the `flutter` tag even in release).
library;

import 'dart:async';

/// Opt-in switch, baked in at compile time.
const perfProbe = bool.fromEnvironment('DSH_PERF_PROBE');

class RelayPerfProbe {
  static int _decryptUs = 0, _decryptN = 0, _decryptBytes = 0;
  static int _waitUs = 0, _waitN = 0;
  static Timer? _timer;

  /// Noise decrypt plus DSHF reassembly for one transport frame.
  static void noteDecrypt(int us, int bytes) {
    _decryptUs += us;
    _decryptN++;
    _decryptBytes += bytes;
    _arm();
  }

  /// Wall time the inbound chain spent producing one message (inline decode
  /// for small messages, worker round trip for large ones).
  static void noteDecode(int us) {
    _waitUs += us;
    _waitN++;
    _arm();
  }

  static void _arm() {
    _timer ??= Timer.periodic(const Duration(seconds: 2), (_) {
      print(
        '[perf] relay: noise ${_decryptUs / 1000}ms / $_decryptN frag '
        '(${_decryptBytes ~/ 1024} KiB) | msgWait ${_waitUs / 1000}ms / $_waitN msg',
      );
      _decryptUs = 0;
      _decryptN = 0;
      _decryptBytes = 0;
      _waitUs = 0;
      _waitN = 0;
    });
  }
}
