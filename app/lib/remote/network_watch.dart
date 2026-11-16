import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';

/// Moments worth re-checking remote links: the network changed (Wi-Fi ↔
/// cellular, VPN up/down) or the app came back to the foreground, where
/// Android may have frozen sockets for a while.
///
/// Emits nothing for the initial connectivity state.
DateTime? _hiddenSince;
Duration? _lastBackgroundGap;

/// How long the app had been hidden right before the most recent resume.
/// A quick app switch stays short (the sockets usually survive); a long
/// background almost certainly killed them. Null until a hide→resume cycle
/// has been observed — tests override the kick stream, so links see null
/// there and fall back to probing.
Duration? backgroundGap() => _lastBackgroundGap;

Stream<void> networkKicks() {
  late final StreamController<void> controller;
  StreamSubscription<List<ConnectivityResult>>? connectivity;
  AppLifecycleListener? lifecycle;
  List<ConnectivityResult>? last;

  controller = StreamController<void>.broadcast(
    onListen: () {
      try {
        connectivity = Connectivity().onConnectivityChanged.listen((results) {
          final previous = last;
          last = results;
          if (previous == null) return;
          // Coming back online, or switching networks: either way sockets that
          // were bound to the old interface are dead.
          if (!results.contains(ConnectivityResult.none)) controller.add(null);
        }, onError: (_) {});
      } catch (_) {
        // No plugin (tests, desktop without NetworkManager): resume-only.
      }
      lifecycle = AppLifecycleListener(
        onHide: () => _hiddenSince = DateTime.now(),
        onResume: () {
          final hidden = _hiddenSince;
          _lastBackgroundGap = hidden == null ? null : DateTime.now().difference(hidden);
          controller.add(null);
        },
      );
    },
    onCancel: () {
      try {
        // 与 listen 同防护:平台流在测试 zone / 特定生命周期下 cancel 会炸
        // (MissingPluginException 一族),拆订失败等价于本来就没人监听。
        unawaited(connectivity?.cancel().catchError((Object _) {}));
      } catch (_) {}
      lifecycle?.dispose();
      connectivity = null;
      lifecycle = null;
      last = null;
    },
  );
  return controller.stream;
}
