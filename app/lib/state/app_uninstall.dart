/// 手机端卸载的编排层(手机端卸载接整包语义,task-11;规范 §6):
///
///   ① 主机 remove(经引擎终端通道跑 wanqi CLI,**先主机**——本机先卸就没了
///      抓手;失败可重试,降级只影响主机侧残留);
///   ② 本机 uninstall(DiminaHost.uninstall,clearUserData: true,现状不变)。
///
/// 主机不可达 / 会话缺失 / 命令失败 → **降级为仅本机卸载**(尽力而为),
/// 失败信息留在 [WholeUninstallReport.hostDetail],由调用方透出到提示/日志。
/// 函数不依赖 Ref(WidgetRef/Ref 类型不兼容):backend 与清单刷新回调由
/// 调用方注入,测试可直接喂 fake。
library;

import 'dart:async';

import '../ui/applet/dimina/dimina_host.dart';
import 'host_bundle_remove.dart';
import 'terminal_state.dart' show TerminalBackend;

/// 一次整包卸载的完整报告。
class WholeUninstallReport {
  const WholeUninstallReport({
    required this.hostAttempted,
    required this.hostOk,
    required this.localOk,
    this.hostDetail = '',
  });

  /// false = 没有可用会话/终端通道(降级:主机侧未动)。
  final bool hostAttempted;
  final bool hostOk;
  final bool localOk;

  /// 主机侧细节(输出尾部/错误),提示与日志用。
  final String hostDetail;

  /// 主机侧没成功 = 可能有残留后端,提示条提示「稍后重试」。
  bool get needsHostRetry => hostAttempted && !hostOk;

  @override
  String toString() =>
      'WholeUninstallReport(hostAttempted=$hostAttempted hostOk=$hostOk '
      'localOk=$localOk hostDetail=$hostDetail)';
}

/// 整包卸载编排。 [backend] 为 null = 没有到主机的终端通道(降级仅本机);
/// [onInstalledInvalidated] 在卸载动作发生后回调一次(UI 用它失效已装清单)。
Future<WholeUninstallReport> uninstallWholeApp({
  required String appId,
  required bool purge,
  TerminalBackend? backend,
  void Function()? onInstalledInvalidated,
}) async {
  // ① 主机 remove:先主机(本机先卸就没了抓手)。
  bool hostAttempted = false;
  bool hostOk = false;
  String hostDetail = backend == null ? 'no-active-session' : '';
  if (backend != null) {
    hostAttempted = true;
    try {
      final HostRemoveResult result =
          await HostBundleRemove(backend).remove(appId: appId, purge: purge);
      hostOk = result.ok;
      hostDetail = result.ok ? 'ok' : (result.error ?? result.output);
    } catch (error) {
      hostDetail = '$error';
    }
  }

  // ② 本机卸载:主机结果不影响本机动作(用户按下卸载,本机一定卸;
  //    主机侧失败留给报告/提示,重装或重试收尾)。
  bool localOk = false;
  try {
    localOk = await DiminaHost.uninstall(appId, clearUserData: true);
  } catch (error) {
    hostDetail = '$hostDetail local-uninstall: $error';
  }

  onInstalledInvalidated?.call();

  return WholeUninstallReport(
    hostAttempted: hostAttempted,
    hostOk: hostOk,
    localOk: localOk,
    hostDetail: hostDetail.trim(),
  );
}
