// networkKicks 的平台通道防护回归:无插件环境(测试 zone / 无 NetworkInfo
// 的桌面)里 listen 走 catch,stop 的 cancel 也必须不炸(fix-c 的 wave7
// MissingPluginException 同族)。真机上 cancel 炸会连带拆不掉监听。
import 'package:dsh_app/remote/network_watch.dart';
import 'package:flutter/widgets.dart' show WidgetsFlutterBinding;
import 'package:flutter_test/flutter_test.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // 真实 async(非 FakeAsync):平台流的挂载/拆除错误在真事件循环里收尾,
  // 才能验证 cancel 竞速不会把错误漏进调用方 zone。
  test('networkKicks: subscribe + cancel survives a zone without the plugin', () async {
    final kicks = networkKicks();
    final sub = kicks.listen((_) {});
    await sub.cancel().timeout(const Duration(seconds: 5));
    // 再来一轮:onListen/onCancel 反复挂载拆除都不得抛。
    final again = networkKicks().listen((_) {});
    await again.cancel().timeout(const Duration(seconds: 5));
  }, timeout: const Timeout(Duration(seconds: 15)));
}
