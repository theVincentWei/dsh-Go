/// Temporary download-jank probe for the client decode paths.
///
/// Builds without `--dart-define=DSH_PERF_PROBE=true` constant-fold every
/// call site away: the probe adds nothing to them. With the flag, large
/// payload decodes accumulate their times and print one line every 2 s
/// (goes to logcat under the `flutter` tag even in release).
library;

import 'dart:async';

/// Opt-in switch, baked in at compile time.
const perfProbe = bool.fromEnvironment('DSH_PERF_PROBE');

class ClientPerfProbe {
  static int _base64Us = 0, _base64N = 0, _base64Chars = 0;
  static int _binaryUs = 0, _binaryN = 0, _binaryBytes = 0;
  static Timer? _timer;

  /// One base64Decode of an RPC payload string (the remote tunnel's
  /// `workspaceFiles/readBytes` windows arrive this way).
  static void noteBase64(int us, int chars) {
    _base64Us += us;
    _base64N++;
    _base64Chars += chars;
    _arm();
  }

  /// One multipart binary result decode (HTTP carrier: local engine and SSH
  /// tunnels), including its isolate round trip.
  static void noteBinary(int us, int bytes) {
    _binaryUs += us;
    _binaryN++;
    _binaryBytes += bytes;
    _arm();
  }

  static void _arm() {
    _timer ??= Timer.periodic(const Duration(seconds: 2), (_) {
      print(
        '[perf] client: base64 ${_base64Us / 1000}ms / $_base64N windows '
        '(${_base64Chars ~/ 1024} KiB of base64) | binaryWait ${_binaryUs / 1000}ms '
        '/ $_binaryN bodies (${_binaryBytes ~/ 1024} KiB)',
      );
      _base64Us = 0;
      _base64N = 0;
      _base64Chars = 0;
      _binaryUs = 0;
      _binaryN = 0;
      _binaryBytes = 0;
    });
  }
}
