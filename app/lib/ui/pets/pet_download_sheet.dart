// 下载通知中心:宠物处于「搬东西」(carrying)状态时点它打开。
// 列出全部进行中的下载,每行可取消,点行跳到下载发起的会话
// (select + reveal,见 chat_alert_host 的同款跳转)。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/download_tasks.dart';
import '../../state/hosts_state.dart';
import '../common/app_sheet.dart';

/// 打开下载列表;[onOpen] 把一个条目带到它发起的会话。
Future<void> showDownloadTasksSheet(
  BuildContext context, {
  required void Function(HostRef host, String sessionId) onOpen,
}) {
  return showAppSheet<void>(
    context,
    isScrollControlled: true,
    builder: (sheet) => DownloadTasksPanel(onOpen: onOpen),
  );
}

/// 下载列表本体(独立成 Widget 便于测试)。
class DownloadTasksPanel extends ConsumerWidget {
  const DownloadTasksPanel({super.key, required this.onOpen});

  final void Function(HostRef host, String sessionId) onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(downloadTasksProvider);
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      minimum: const EdgeInsets.only(bottom: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.only(top: 8, bottom: 6),
            decoration: BoxDecoration(color: scheme.outlineVariant, borderRadius: BorderRadius.circular(2)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Icon(Icons.download, size: 16, color: scheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Text(appL10n.chatDownloadCenter, style: Theme.of(context).textTheme.titleSmall),
                const Spacer(),
                Text(
                  appL10n.chatDownloadCount(tasks.length),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          for (final task in tasks)
            _TaskRow(task: task, onOpen: onOpen),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                appL10n.chatDownloadSheetHint,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TaskRow extends ConsumerWidget {
  const _TaskRow({required this.task, required this.onOpen});

  final DownloadTask task;
  final void Function(HostRef host, String sessionId) onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () {
        Navigator.of(context, rootNavigator: true).pop();
        onOpen(task.host, task.sessionId);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        child: Row(
          children: [
            Icon(Icons.description_outlined, size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    task.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 5),
                  LinearProgressIndicator(value: task.progress, minHeight: 3),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Text(
              task.progress == null ? '' : '${(task.progress! * 100).round()}%',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(width: 6),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close, size: 16),
              tooltip: appL10n.updateCancelDownload,
              onPressed: () {
                task.cancel();
                ref.read(downloadTasksProvider.notifier).finish(key: task.key);
              },
            ),
          ],
        ),
      ),
    );
  }
}
