import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/auto_sync_state.dart';
import '../theme/app_icons.dart';
import 'settings_widgets.dart';

/// 设置 → 通用 → 静默同步:autoSync 应用后台自动安装/升级的总开关
/// (默认开,自用场景;关掉后 autoSync 应用退回「市场页手动装/升」)。
class AutoSyncSettingsTile extends ConsumerWidget {
  const AutoSyncSettingsTile({super.key, this.tint = 3});

  /// the hub group's hue.
  final int tint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final AutoSyncSettings settings = ref.watch(autoSyncProvider);
    if (!settings.loaded) return const SizedBox.shrink();
    return SettingsSwitchTile(
      icon: AppIcons.swap,
      title: l10n.autoSyncTitle,
      subtitle: l10n.autoSyncSummary,
      value: settings.enabled,
      tint: tint,
      onChanged: (bool on) =>
          unawaited(ref.read(autoSyncProvider.notifier).setEnabled(on)),
    );
  }
}
