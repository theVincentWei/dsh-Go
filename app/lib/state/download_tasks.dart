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

  // 速度采样:最后一次样本的 bytes 与时刻,以及 EMA 平滑后的速率。
  DateTime? _sampleAt;
  int _sampleReceived = 0;
  double _emaBps = 0;

  /// 停滞判定:超过这么久没有新样本就报 0(横条不再显示速度)。
  static const _stalledAfter = Duration(milliseconds: 2500);

  void cancel() => cancelToken.cancelled = true;
  bool get cancelled => cancelToken.cancelled;

  /// 直改字段不通知:登记起点(如续传偏移),速度基线一并归零。
  void updateReceived(int value) {
    received = value;
    _sampleReceived = value;
    _sampleAt = null;
    _emaBps = 0;
  }

  /// 采样一次进度并刷新速度(EMA);通知节流由控制器负责。
  void sample(int value, DateTime now) {
    final at = _sampleAt;
    if (at != null) {
      final dtMs = now.difference(at).inMilliseconds;
      if (dtMs > 0) {
        final inst = (value - _sampleReceived) * 1000 / dtMs;
        _emaBps = _emaBps <= 0 ? inst : _emaBps * 0.7 + inst * 0.3;
      }
    }
    _sampleAt = now;
    _sampleReceived = value;
    received = value;
  }

  /// 平滑后的下载速度(bytes/s);还没采到第二个样本时为 null,停滞时为 0。
  double? get speedBps {
    final at = _sampleAt;
    if (at == null) return null;
    if (DateTime.now().difference(at) > _stalledAfter) return 0;
    return _emaBps;
  }

  /// 0–1;总大小未知时为 null(横条退化为不定进度)。
  double? get progress {
    final total = this.total;
    if (total == null || total == 0) return null;
    return (received / total).clamp(0.0, 1.0).toDouble();
  }
}

class DownloadTasksController extends Notifier<List<DownloadTask>> {
  /// 通知节流:分片级调用很密,UI(横条/速度)每这个窗口刷一次足够。
  static const notifyInterval = Duration(milliseconds: 250);

  final Map<String, DateTime> _lastNotify = {};

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

  /// 每个分片都调:样本总在记(速度要连续),通知按 [notifyInterval] 节流。
  void progress({required String key, required int received}) {
    final now = DateTime.now();
    DownloadTask? task;
    for (final t in state) {
      if (t.key == key) {
        t.sample(received, now);
        task = t;
        break;
      }
    }
    if (task == null) return;
    final last = _lastNotify[key];
    if (last != null && now.difference(last) < notifyInterval) return;
    _lastNotify[key] = now;
    state = [...state];
  }

  /// 任务结束(无论成败)即出列。
  void finish({required String key}) {
    _lastNotify.remove(key);
    state = state.where((task) => task.key != key).toList();
  }
}

final downloadTasksProvider = NotifierProvider<DownloadTasksController, List<DownloadTask>>(
  DownloadTasksController.new,
);
