// 主机 remove 执行器测试:命令组装 + executor 路径(rc 映射/异常/purge 透传)。
// 终端协议路径(create/retain/attach/帧序列)由真机/模拟器 E2E 覆盖——fake 级
// 复刻 terminal 协议的快照/序列门性价比过低。
library;

import 'dart:async';

import 'package:dsh_app/state/host_bundle_remove.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('buildCommand(纯函数)', () {
    test('默认指向仓内 wrapper,appId 单引号防御', () {
      final String command = HostBundleRemove.buildCommand(
          appId: 'wxabc', purge: false, home: '/Users/me');
      expect(
          command,
          "/Users/me/Code/wanqi/server/bin/wanqi bundle remove "
          "--app 'wxabc'; echo \"WANQIRC=\$?\"");
    });

    test('--purge 追加清除勾选', () {
      final String command = HostBundleRemove.buildCommand(
          appId: 'wanqi-test-x', purge: true, home: '/Users/me');
      expect(command, contains('--purge'));
      expect(command, contains("--app 'wanqi-test-x'"));
    });

    test('home 缺省为 shell 字面量 \$HOME', () {
      expect(HostBundleRemove.wrapperPath(), startsWith(r'$HOME/'));
      expect(HostBundleRemove.wrapperPath(home: '/Users/me'),
          '/Users/me/Code/wanqi/server/bin/wanqi');
    });
  });

  group('withExecutor(测试注入路径)', () {
    test('把组装好的命令交给执行器,rc=0 → ok', () async {
      String? received;
      final HostRemoveResult result = await HostBundleRemove.withExecutor(
        (String command) async {
          received = command;
          return const HostRemoveResult(
              ok: true, exitCode: 0, output: 'WANQIRC=0');
        },
        timeout: const Duration(seconds: 3),
      ).remove(appId: 'wxabc');
      expect(result.ok, isTrue);
      expect(result.exitCode, 0);
      expect(received, contains('bundle remove'));
      expect(received, contains("--app 'wxabc'"));
    });

    test('rc=1 → ok=false,输出透传', () async {
      final HostRemoveResult result = await HostBundleRemove.withExecutor(
        (String command) async => const HostRemoveResult(
            ok: false, exitCode: 1, output: 'WANQIRC=1 boom'),
        timeout: const Duration(seconds: 3),
      ).remove(appId: 'wxabc');
      expect(result.ok, isFalse);
      expect(result.exitCode, 1);
      expect(result.output, contains('boom'));
    });

    test('执行器抛异常 → ok=false,错误留在结果里(不向调用方抛)', () async {
      final HostRemoveResult result = await HostBundleRemove.withExecutor(
        (String command) async => throw StateError('link down'),
        timeout: const Duration(seconds: 3),
      ).remove(appId: 'wxabc');
      expect(result.ok, isFalse);
      expect(result.error, contains('link down'));
    });

    test('purge 透传进命令', () async {
      String? received;
      await HostBundleRemove.withExecutor(
        (String command) async {
          received = command;
          return const HostRemoveResult(ok: true, exitCode: 0, output: '');
        },
        timeout: const Duration(seconds: 3),
      ).remove(appId: 'wxabc', purge: true);
      expect(received, contains('--purge'));
    });
  });
}
