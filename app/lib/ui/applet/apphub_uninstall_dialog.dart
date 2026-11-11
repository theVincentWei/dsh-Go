/// 手机端卸载弹窗 + 编排入口(手机端卸载接整包语义,task-11;规范 §6):
///
///   将卸载此小程序并停止主机上的服务;主机数据将保留,重装即恢复。
///   [ ] 同时清除主机数据(不可恢复)
///
/// 确认后执行 [uninstallWholeApp](先主机后本机);主机命令失败 → 降级为仅
/// 本机卸载,SnackBar 提示(任务要点③)。两个卸载入口(市场详情页/桌面
/// 长按)都走这里,不再各自写弹窗。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/app_uninstall.dart';
import '../../state/sessions_state.dart' show currentSessionProvider;
import '../../state/terminal_state.dart' show terminalBackendProvider;
import '../applet/hub_apps_group.dart' show hubInstalledProvider;

/// 弹出卸载弹窗并执行整包卸载编排。返回本机卸载是否成功(调用方据此刷新
/// 自己的局部状态;backend/session 解析在这里做——widget 层才有 Ref)。
Future<bool> showAndRunAppUninstall(
  BuildContext context,
  WidgetRef ref, {
  required String appId,
  required String name,
}) async {
  final l10n = context.l10n;
  final (bool confirmed, bool purge)? decision = await showDialog<(bool, bool)>(
    context: context,
    builder: (BuildContext dialog) => _UninstallDialog(appName: name, l10n: l10n),
  );
  if (decision == null || !decision.$1) return false;

  final String? sessionId = ref.read(currentSessionProvider);
  final backend =
      sessionId == null ? null : ref.read(terminalBackendProvider(sessionId));

  final WholeUninstallReport report = await uninstallWholeApp(
    appId: appId,
    purge: decision.$2,
    backend: backend,
    onInstalledInvalidated: () => ref.invalidate(hubInstalledProvider),
  );

  if (report.needsHostRetry && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(l10n.apphubUninstallHostFailed),
      duration: const Duration(seconds: 5),
    ));
  }
  return report.localOk;
}

class _UninstallDialog extends StatefulWidget {
  const _UninstallDialog({required this.appName, required this.l10n});

  final String appName;
  final L10n l10n;

  @override
  State<_UninstallDialog> createState() => _UninstallDialogState();
}

class _UninstallDialogState extends State<_UninstallDialog> {
  bool _purge = false;

  @override
  Widget build(BuildContext context) {
    final L10n l10n = widget.l10n;
    return AlertDialog(
      title: Text('${l10n.apphubUninstall} ${widget.appName}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(l10n.apphubUninstallWholeBody),
          const SizedBox(height: 8),
          CheckboxListTile(
            value: _purge,
            onChanged: (bool? value) => setState(() => _purge = value ?? false),
            controlAffinity: ListTileControlAffinity.leading,
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.apphubUninstallPurge),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop((true, _purge)),
          child: Text(l10n.apphubUninstall),
        ),
      ],
    );
  }
}
