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
import '../../state/auto_sync_state.dart' show AutoSyncRunner;
import '../../state/sessions_state.dart' show currentSessionProvider;
import '../../state/terminal_state.dart'
    show TerminalBackend, terminalBackendProvider;
import '../applet/hub_apps_group.dart' show hubInstalledProvider;

/// 弹出共用卸载弹窗,返回 (确认, purge 勾选);取消/关闭返回 null。
/// 纯 widget 入口,不碰 Ref——桌面引擎的卸载钩子(无 BuildContext)经根
/// navigator 调它,市场详情页经 [showAndRunAppUninstall] 调它,两入口
/// 同一个弹窗。
Future<(bool, bool)?> showAppUninstallDialog(
  BuildContext context, {
  required String name,
}) async {
  return showDialog<(bool, bool)>(
    context: context,
    builder: (BuildContext dialog) => _UninstallDialog(appName: name, l10n: context.l10n),
  );
}

/// 弹窗 + 整包卸载编排(市场详情页入口;widget 层才有 WidgetRef)。
/// 返回本机卸载是否成功(调用方据此刷新自己的局部状态;backend/session
/// 解析在这里做)。
Future<bool> showAndRunAppUninstall(
  BuildContext context,
  WidgetRef ref, {
  required String appId,
  required String name,
}) async {
  final (bool confirmed, bool purge)? decision =
      await showAppUninstallDialog(context, name: name);
  if (decision == null || !decision.$1 || !context.mounted) return false;

  final String? sessionId = ref.read(currentSessionProvider);
  return runWholeUninstall(
    context: context,
    appId: appId,
    purge: decision.$2,
    backend:
        sessionId == null ? null : ref.read(terminalBackendProvider(sessionId)),
    invalidate: () => ref.invalidate(hubInstalledProvider),
  );
}

/// 整包卸载执行段(两入口共用):跑 [uninstallWholeApp](先主机后本机),
/// 主机命令失败 → 降级为仅本机卸载并 SnackBar 提示可重试;返回本机卸载
/// 是否成功。backend/invalidate 由调用方注入,桌面钩子与详情页同一条路。
Future<bool> runWholeUninstall({
  required BuildContext context,
  required String appId,
  required bool purge,
  required TerminalBackend? backend,
  required void Function() invalidate,
}) async {
  final L10n l10n = context.l10n;
  final WholeUninstallReport report = await uninstallWholeApp(
    appId: appId,
    purge: purge,
    backend: backend,
    onInstalledInvalidated: invalidate,
  );

  // 卸载豁免(「未装恒装」的配套,2026-11-12):不 purge = 用户只是不想在
  // 本机看到它,记入静默同步豁免表,否则下一轮自动同步会把它装回来;purge
  // = 服务端 bundle 已删,清掉豁免,以后重新上架同一 appId 恢复自动跟随。
  unawaited(purge
      ? AutoSyncRunner.notePurged(appId)
      : AutoSyncRunner.noteUninstalled(appId));

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
