/// Temporary download-jank probe for the UI isolate itself.
///
/// Builds without `--dart-define=DSH_PERF_PROBE=true` never register the
/// callback (call `startDownloadPerfProbe` anywhere; it returns at once).
/// With the flag, frame timings accumulate and print one line every 2 s to
/// logcat (`flutter` tag) — works in release, unlike dev/frame_probe.dart.
library;

import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/scheduler.dart';

const downloadPerfProbe = bool.fromEnvironment('DSH_PERF_PROBE');

int _frames = 0, _slow = 0, _worstUs = 0, _buildUs = 0, _rasterUs = 0;
Timer? _timer;

/// Call once after the binding is initialized.
void startDownloadPerfProbe() {
  if (!downloadPerfProbe) return;
  // The engine masks the VM service line in logcat for non-debuggable
  // builds; print the endpoint from Dart so a profiler can attach.
  developer.Service.getInfo().then(
    // ignore: avoid_print — probe output for logcat.
    (info) => print('[perf] vm: ${info.serverUri}'),
  );
  SchedulerBinding.instance.addTimingsCallback((timings) {
    for (final timing in timings) {
      final totalUs = timing.totalSpan.inMicroseconds;
      _frames++;
      if (totalUs > 17000) {
        _slow++;
        if (totalUs > _worstUs) _worstUs = totalUs;
      }
      _buildUs += timing.buildDuration.inMicroseconds;
      _rasterUs += timing.rasterDuration.inMicroseconds;
    }
    _arm();
  });
}

void _arm() {
  _timer ??= Timer.periodic(const Duration(seconds: 2), (_) {
    // ignore: avoid_print — probe output for logcat.
    print(
      '[perf] ui: frames=$_frames slow(>17ms)=$_slow worst=${_worstUs ~/ 1000}ms '
      'build=${_buildUs ~/ 1000}ms raster=${_rasterUs ~/ 1000}ms',
    );
    _frames = 0;
    _slow = 0;
    _worstUs = 0;
    _buildUs = 0;
    _rasterUs = 0;
  });
}
