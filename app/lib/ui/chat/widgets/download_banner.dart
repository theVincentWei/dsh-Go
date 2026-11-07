// 下载中的文件横条:名字、进度、取消。挂在聊天页 composer 上方,
// 没有活动下载时完全不占布局。任务跨页面可见——离开当前会话也能
// 看到还在下什么、随时取消。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../state/download_tasks.dart';

class DownloadTasksBanner extends ConsumerWidget {
  const DownloadTasksBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(downloadTasksProvider);
    if (tasks.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final shown = tasks.take(2);
    final hidden = tasks.length - shown.length;
    return Material(
      color: scheme.surfaceContainerHighest,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final task in shown)
            _Row(task: task),
          if (hidden > 0)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('+$hidden', style: Theme.of(context).textTheme.labelSmall),
              ),
            ),
          Divider(height: 1, color: scheme.outlineVariant),
        ],
      ),
    );
  }
}

class _Row extends ConsumerWidget {
  const _Row({required this.task});

  final DownloadTask task;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          Icon(Icons.download, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              task.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 64,
            child: LinearProgressIndicator(value: task.progress, minHeight: 3),
          ),
          const SizedBox(width: 8),
          Text(
            task.progress == null ? '' : '${(task.progress! * 100).round()}%',
            style: Theme.of(context).textTheme.labelSmall,
          ),
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
    );
  }
}
