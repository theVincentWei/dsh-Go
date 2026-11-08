// 聊天文件下载的全局任务表:跨页面可见、可取消。
//
// 任务由 ArtifactFiles 在发起用户触发的下载(打开/保存/分享)时登记;
// 分片的落盘与续传由 ArtifactFiles 自己负责,这里只管「有哪些在跑、
// 进度到哪、谁要取消」。表里只有进行中的下载——结束态(完成/失败/
// 取消)的反馈由发起它的界面自己给,出列即消失。

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'hosts_state.dart';

/// 一个下载的取消开关:下载循环在每个窗口间隙检查。
class DownloadCancelToken {
  bool cancelled = false;
}

class DownloadTask {
  DownloadTask({
    required this.key,
    required this.label,
    required this.host,
    required this.sessionId,
    this.total,
  });

  /// 缓存键(host+session+path),也是任务的唯一标识。
  final String key;
  final String label;
  final HostRef host;
  final String sessionId;
  final DownloadCancelToken cancelToken = DownloadCancelToken();
  final int? total;
  int received = 0;

  void cancel() => cancelToken.cancelled = true;
  bool get cancelled => cancelToken.cancelled;

  void updateReceived(int value) => received = value;

  /// 0–1;总大小未知时为 null(横条退化为不定进度)。
  double? get progress {
    final total = this.total;
    if (total == null || total == 0) return null;
    return (received / total).clamp(0.0, 1.0).toDouble();
  }
}

class DownloadTasksController extends Notifier<List<DownloadTask>> {
  @override
  List<DownloadTask> build() => const [];

  DownloadTask begin({
    required String key,
    required String label,
    required HostRef host,
    required String sessionId,
    int? total,
  }) {
    final task = DownloadTask(key: key, label: label, host: host, sessionId: sessionId, total: total);
    state = [...state.where((t) => t.key != key), task];
    return task;
  }

  void progress({required String key, required int received}) {
    state = [
      for (final task in state)
        if (task.key == key) task..received = received else task,
    ];
  }

  /// 任务结束(无论成败)即出列。
  void finish({required String key}) {
    state = state.where((task) => task.key != key).toList();
  }
}

final downloadTasksProvider = NotifierProvider<DownloadTasksController, List<DownloadTask>>(
  DownloadTasksController.new,
);
