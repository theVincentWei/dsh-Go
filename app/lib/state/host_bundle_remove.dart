/// 手机端卸载的「主机 remove」执行器(手机端卸载接整包语义,task-11):
/// 经既有引擎终端通道(terminal/create + retain + attach,既有权限模型,
/// 不新增 HTTP 鉴权面)在主机 shell 里跑 wanqi CLI 的 bundle remove。
///
/// 结束判定:命令尾缀 `; echo "WANQIRC=$?"`,扫描输出里的 `WANQIRC=<数字>`
/// ——键入回显里同样会出现 `WANQIRC=$?` 字面量,但没有数字,不会误判。
/// 超时/终端异常 → ok=false(调用方降级为仅本机卸载,失败信息留在结果里)。
library;

import 'dart:async';

import 'package:dsh_client/dsh_client.dart'
    show TerminalOutput, TerminalSnapshot;

import 'terminal_state.dart' show TerminalBackend;

/// 一次主机 remove 的结果。
class HostRemoveResult {
  const HostRemoveResult({
    required this.ok,
    required this.exitCode,
    required this.output,
    this.error,
  });

  final bool ok;
  final int exitCode;

  /// 尾部输出(诊断用;已剥到固定长度,防整屏刷进日志)。
  final String output;
  final String? error;

  @override
  String toString() =>
      'HostRemoveResult(ok=$ok rc=$exitCode${error == null ? '' : ' error=$error'})';
}

/// 执行器。[backend] 来自 terminalBackendProvider(sessionId);测试注入 fake。
/// [HostBundleRemove.withExecutor] 供测试直接注入命令执行器(绕过终端协议
/// 细节,协议路径由真机/模拟器 E2E 覆盖)。
typedef HostRemoveExecutor = Future<HostRemoveResult> Function(String command);

class HostBundleRemove {
  HostBundleRemove(this.backend, {this.timeout = const Duration(seconds: 30)})
      : executor = null;

  /// 测试构造:直接注入执行器,收到的就是组装好的完整命令行。
  HostBundleRemove.withExecutor(HostRemoveExecutor this.executor,
      {this.timeout = const Duration(seconds: 30)})
      : backend = null;

  final TerminalBackend? backend;
  final HostRemoveExecutor? executor;
  final Duration timeout;

  /// 主机侧 wanqi wrapper 的固定路径(仓内交付,见 wanqi server/bin/wanqi)。
  /// home 缺省 = shell 字面量 \$HOME(命令在主机 shell 里展开)。
  static String wrapperPath({String? home}) {
    final String base = home ?? r'$HOME';
    return '$base/Code/wanqi/server/bin/wanqi';
  }

  /// 组装发送到主机 shell 的一行命令(纯函数,可单测)。appId 只可能是
  /// [a-z0-9-](市场校验),仍按单引号防御。
  static String buildCommand({
    required String appId,
    required bool purge,
    String? home,
  }) {
    final String purgeFlag = purge ? ' --purge' : '';
    return "${wrapperPath(home: home)} bundle remove --app '$appId'$purgeFlag; "
        'echo "WANQIRC=\$?"';
  }

  static final RegExp _rcPattern = RegExp(r'WANQIRC=(\d+)');

  /// 拉目录 → plan → 逐条执行。返回本轮流到的 outcomes(空 = 无事可做)。
  Future<HostRemoveResult> remove({
    required String appId,
    bool purge = false,
    String? home,
  }) async {
    final String command =
        '${buildCommand(appId: appId, purge: purge, home: home)}\n';
    final HostRemoveExecutor? run = executor;
    if (run != null) {
      try {
        return await run(command);
      } catch (error) {
        return HostRemoveResult(
            ok: false, exitCode: -1, output: '', error: '$error');
      }
    }
    final TerminalBackend target = backend!;
    final String id = 'wanqi-remove-${DateTime.now().millisecondsSinceEpoch}';
    final StringBuffer out = StringBuffer();
    final Completer<int> done = Completer<int>();
    try {
      await target.create(id, cols: 120, rows: 40);
      // 先 retain 占位(引擎要求 hold 之后 attach 才拿得到输入权)。
      await target.retain(id).first;
      final attachment =
          target.attach(id, await target.environment());
      late final StreamSubscription<void> sub;
      void handle(String text) {
        if (done.isCompleted) return;
        out.write(text);
        final RegExpMatch? match = _rcPattern.firstMatch(text);
        // 键入回显是 `WANQIRC=$?`(无数字),只有结果行带数字。
        if (match != null) done.complete(int.parse(match.group(1)!));
      }

      sub = attachment.frames.listen(
        (frame) {
          if (frame is TerminalSnapshot) handle(frame.screen);
          if (frame is TerminalOutput) handle(frame.data);
        },
        onError: (Object error) {
          if (!done.isCompleted) done.complete(-1);
        },
        onDone: () {
          if (!done.isCompleted) done.complete(-1);
        },
      );
      // 等输入权(真实链路:attach 后第一帧是快照, writable=true 才能写;
      // 立刻 write 会在快照落定前被拒)。deadline 与总超时共用。
      final DateTime deadline = DateTime.now().add(timeout);
      while (!attachment.writable && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      if (!attachment.writable || !attachment.write(command)) {
        sub.cancel();
        attachment.close();
        await target.close(id);
        return HostRemoveResult(
            ok: false,
            exitCode: -1,
            output: '',
            error: 'terminal not writable');
      }
      final int rc = await done.future.timeout(
        deadline.difference(DateTime.now()),
        onTimeout: () => -1,
      );
      await sub.cancel();
      attachment.close();
      await target.close(id);
      final String text = out.toString();
      return HostRemoveResult(
        ok: rc == 0,
        exitCode: rc,
        output: text.length > 2000 ? text.substring(text.length - 2000) : text,
      );
    } catch (error) {
      try {
        await target.close(id);
      } catch (_) {}
      return HostRemoveResult(ok: false, exitCode: -1, output: '', error: '$error');
    }
  }
}
