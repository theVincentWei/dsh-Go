import 'dart:async';

import 'package:dsh_app/performance/performance_state.dart';
import 'package:dsh_app/ui_config/ui_config.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

PerformanceSnapshot snapshot(DeviceTier tier, {bool hot = false, int sequence = 1}) => PerformanceSnapshot(
  sequence: sequence,
  device: {'tier': tier.name, 'totalMemoryBytes': 8 * 1024 * 1024 * 1024},
  thermal: {'lightweight': hot, 'status': hot ? 2 : 0},
  loaded: true,
  available: true,
);

class FakePerformanceChannel extends PerformanceChannel {
  FakePerformanceChannel(this.initial);
  final Future<PerformanceSnapshot> initial;
  final events = StreamController<PerformanceSnapshot>.broadcast(sync: true);

  @override
  Future<PerformanceSnapshot> snapshot() => initial;
  @override
  Stream<PerformanceSnapshot> get changes => events.stream;
}

/// These tests mount the whole DshApp, whose theme follows the active host's
/// ui.json since #226; the local host's file follows the runtime's platform
/// events, which a widget test has no plugin for. Nothing here reads ui.json:
/// no source, as for a host that can't be read now.
final Override noUiJson = uiConfigSourceBuilderProvider.overrideWithValue((ref, host) => null);

/// The merged tree's root assembly (DshApp keeps hubDesktopSync alive) reaches
/// featureSections → seatPlan → seatInventory → activeConnection, which
/// activates the connectivity and runtime EventChannels. Widget tests have no
/// plugin for them: activation throws MissingPluginException and every
/// `takeException() == null` assertion (and the goldens) fail. Mock `listen`
/// like test/hub/hub_desktop_sync_test.dart does (适配合并树).
void quietSeamChannels() {
  for (final String channel in <String>[
    'dev.fluttercommunity.plus/connectivity_status',
    'dsh/runtime/events',
  ]) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      MethodChannel(channel),
      (MethodCall call) async => null,
    );
  }
}
