// 会话头像的图库映射与落地:同一会话永远同一槽/同一资产;槽位撒得开;
// SessionTile 渲染的确实是图库资产;资产真的随包分发。
//
//   flutter test test/drawer/session_avatar_test.dart

import 'package:dsh_app/ui/shell/drawer/session_tile.dart';
import 'package:dsh_app/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SessionAvatarGallery mapping', () {
    test('same session, same slot and asset', () {
      for (final id in ['a', 'ssh-studio:abc123', '一个中文会话', 'x' * 64]) {
        final slot = SessionAvatarGallery.slotFor(id);
        expect(slot, SessionAvatarGallery.slotFor(id));
        expect(SessionAvatarGallery.assetFor(slot), SessionAvatarGallery.assetFor(SessionAvatarGallery.slotFor(id)));
      }
    });

    test('slots stay in [0, count) and spread wide', () {
      final slots = <int>{
        for (var i = 0; i < 500; i++) SessionAvatarGallery.slotFor('session-$i'),
      };
      expect(slots.every((s) => s >= 0 && s < SessionAvatarGallery.count), isTrue);
      // 500 个 id 全挤在少数槽里才叫坏;别钉具体分布形状。
      expect(slots.length, greaterThan(40));
    });

    test('asset names are two-digit and bounded', () {
      expect(SessionAvatarGallery.assetFor(0), 'assets/session_avatars/avatar_00.png');
      expect(SessionAvatarGallery.assetFor(7), 'assets/session_avatars/avatar_07.png');
      expect(SessionAvatarGallery.assetFor(99), 'assets/session_avatars/avatar_99.png');
    });
  });

  testWidgets('the tile renders the gallery avatar for its session', (tester) async {
    const id = 'ssh-studio:abc123';
    await tester.pumpWidget(
      // DshColors 是主题扩展:得用 app 的主题构建器,裸 MaterialApp 没有。
      MaterialApp(
        theme: buildLightTheme(),
        home: Scaffold(
          body: SessionTile(
            sessionId: id,
            title: '解释 proot 的 link2symlink',
            running: false,
            groupPosition: SessionGroupPos.single,
            onTap: () {},
            onLongPress: null,
          ),
        ),
      ),
    );
    // 渲染的就是该会话槽位的图库资产。
    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, isA<AssetImage>());
    expect((image.image as AssetImage).assetName, SessionAvatarGallery.assetFor(SessionAvatarGallery.slotFor(id)));
    // 头像槽的大小固定,不随加载状态变。
    expect(tester.getRect(find.byKey(const ValueKey('session-avatar'))).size, const Size(32, 32));
  });

  testWidgets('precacheAll is idempotent and completes', (tester) async {
    const id = 'ssh-studio:abc123';
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: Scaffold(
          body: SessionTile(
            sessionId: id,
            title: '解释 proot 的 link2symlink',
            running: false,
            groupPosition: SessionGroupPos.single,
            onTap: () {},
            onLongPress: null,
          ),
        ),
      ),
    );
    final context = tester.element(find.byType(SessionTile));
    // 真实资产解码是真 IO,整个断言放在 runAsync 里走;identical 要比较
    // precacheAll 自己存的同一趟 future,不能经过 runAsync 的二次包装。
    await tester.runAsync(() async {
      final first = SessionAvatarGallery.precacheAll(context);
      final second = SessionAvatarGallery.precacheAll(context);
      expect(identical(first, second), isTrue);
      await first;
    });
    await tester.pump();
  });

  test('the gallery ships with the app', () async {
    for (final name in ['avatar_00.png', 'avatar_42.png', 'avatar_99.png']) {
      final data = await rootBundle.load('assets/session_avatars/$name');
      expect(data.lengthInBytes, greaterThan(0));
    }
  });
}
