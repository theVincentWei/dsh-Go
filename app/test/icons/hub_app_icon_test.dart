// AppHub 图标库回归:所有语义键(含 legacy 别名)都能栅格化出 PNG,
// 未知键返回 null(调用方落万能字形)。画法本身由 hub_app_icon.dart 注释
// 里的规范约束,这里只锁「键→非空产物」的契约。
//
// 注意:toImage 在 testWidgets 的 FakeAsync 区不会完成,栅格化必须包在
// tester.runAsync 里(否则测试挂死)。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_app/ui/applet/hub_app_icon.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('every hub icon key rasterizes to PNG', (tester) async {
    const List<String> keys = <String>[
      'gauge', 'keyboard', 'coin', 'pulse',
      'cube', 'components', 'globe', 'moon',
      // legacy 别名(旧发布留下的键)必须继续出图,映射到新画法。
      'book', 'chart', 'star', 'puzzle',
    ];
    await tester.runAsync(() async {
      for (final String key in keys) {
        final Uint8List? png = await rasterizeHubAppIconPng(key, size: 96);
        expect(png, isNotNull, reason: 'icon key "$key" should rasterize');
        expect(png, isNotEmpty, reason: 'icon key "$key" should not be empty');
      }
    });
  });

  testWidgets('unknown key returns null (caller falls back to glyph)', (tester) async {
    await tester.runAsync(() async {
      expect(await rasterizeHubAppIconPng('nonexistent'), isNull);
      expect(await rasterizeHubAppIconPng(''), isNull);
    });
  });
}
