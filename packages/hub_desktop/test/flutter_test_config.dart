// 包内测试的全局准备:真实字体(严格,缺字体直接失败),让几何断言量到
// 真字形。与宿主 test/flutter_test_config.dart 同一配方,但不带宿主状态。

import 'dart:async';

import 'support/test_fonts.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  await loadTestFonts();
  await testMain();
}
