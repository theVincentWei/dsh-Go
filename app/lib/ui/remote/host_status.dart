import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../remote/ssh/ssh_host_config.dart';
import '../../runtime/runtime_state.dart';
import '../../state/connection_state.dart';
import '../../state/hosts_state.dart';
import '../common/status_dot.dart';
import '../engine/engine_status.dart';
import '../theme/app_icons.dart';

/// Dot + words for a host's state. Colour is never the only signal.
class HostStatusView {
  const HostStatusView(this.tone, this.label);

  final StatusTone tone;
  final String label;

  static HostStatusView ofLink(HostLinkStatus status) => switch (status.phase) {
    HostLinkPhase.idle => HostStatusView(StatusTone.idle, appL10n.commonNotConnected),
    HostLinkPhase.connecting => HostStatusView(
      StatusTone.busy,
      status.step == null ? appL10n.remoteConnecting : '${status.step!.label}…',
    ),
    HostLinkPhase.connected => HostStatusView(StatusTone.ok, appL10n.remoteConnected),
    HostLinkPhase.reconnecting => HostStatusView(StatusTone.warn, appL10n.remoteReconnecting),
    HostLinkPhase.failed => HostStatusView(StatusTone.error, appL10n.commonConnectionFailed),
  };

  static HostStatusView ofRelayHost(RelayHost host) => host.online
      ? HostStatusView(StatusTone.ok, appL10n.remoteOnline)
      : HostStatusView(StatusTone.idle, appL10n.remoteOffline);
}

/// Live status of [host]: the engine for 本机, the link for remote hosts.
HostStatusView watchHostStatus(WidgetRef ref, HostRef host) {
  if (host.isLocal) {
    final view = EngineStatusView.of(ref.watch(localRuntimeProvider));
    return HostStatusView(view.tone, view.label);
  }
  final status = ref.watch(hostLinkStatusProvider(host)).value ?? HostLinkStatus.idle;
  return HostStatusView.ofLink(status);
}

IconData hostKindIcon(HostKind kind) => switch (kind) {
  HostKind.local => AppIcons.thisPhone,
  HostKind.ssh => AppIcons.sshHost,
  HostKind.relay => AppIcons.computer,
};

/// The device glyph an SSH host picked for itself (「设备图标」), null when it
/// hasn't (saved before the picker, or reset to the default).
IconData? sshDeviceIcon(SshHostDevice? device) => switch (device) {
  SshHostDevice.macMini => AppIcons.deviceMacMini,
  SshHostDevice.desktop => AppIcons.deviceDesktop,
  SshHostDevice.desktopTower => AppIcons.deviceDesktopTower,
  SshHostDevice.computerTower => AppIcons.deviceTower,
  SshHostDevice.laptop => AppIcons.deviceLaptop,
  SshHostDevice.hardDrives => AppIcons.deviceNas,
  null => null,
};

/// The glyph for the active host, reading the SSH config it points at (the
/// host's own device glyph when it has one, the kind default otherwise).
IconData watchHostIcon(WidgetRef ref, HostRef host) {
  if (host.kind != HostKind.ssh) return hostKindIcon(host.kind);
  final device = ref.watch(hostsProvider.select((s) => s.sshById(host.id)?.icon));
  return sshDeviceIcon(device) ?? hostKindIcon(host.kind);
}

/// Identity tint per kind (one of the 8 fixed pairs), so rows read as a set.
int hostKindTint(HostKind kind) => switch (kind) {
  HostKind.local => 0,
  HostKind.ssh => 6,
  HostKind.relay => 1,
};
