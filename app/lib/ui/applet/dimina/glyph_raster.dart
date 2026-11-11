import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../../theme/app_icons.dart';
import '../hub_app_icon.dart' show rasterizeHubAppIconPng;

/// 桌面/市场格子同款字形表——与 `hub_apps_group.hubAppGlyph` 保持一致(改表两处同步);
/// 不认识的 key 落 allFeatures,与桌面行为一致。图标库(hub_app_icon)命中
/// 的键不走这张表,而是整颗实底彩块栅格(见 [rasterizeGlyphPng])。
IconData _glyphFor(String key) => switch (key) {
      'book' => AppIcons.skill,
      'chart' => AppIcons.sessionDetails,
      'puzzle' => AppIcons.plugin,
      'star' => AppIcons.favorite,
      _ => AppIcons.allFeatures,
    };

/// 把应用图标离屏栅格化成 PNG bytes,随 `DiminaHost.open(iconKey:)` 传给原生
/// 菜单弹层头部,与桌面格子同款。图标库内的键 → 整颗实底彩块(含圆角,
/// 四角透明);库外键 → 单色字形([color] 染色),与旧行为一致。
/// 不落盘;失败/无 key 返回 null,原生回落首字母瓦片。
Future<Uint8List?> rasterizeGlyphPng(
  String? iconKey, {
  Color color = const Color(0xFF4F6BFF),
  double size = 96,
}) async {
  if (iconKey == null || iconKey.isEmpty) return null;
  // 图标库内:整颗实底彩块,与桌面/市场三处同源同款。
  final Uint8List? libraryPng = await rasterizeHubAppIconPng(iconKey, size: size);
  if (libraryPng != null) return libraryPng;
  // 兜底:未知键仍按旧逻辑栅格化单色字形。
  try {
    final icon = _glyphFor(iconKey);
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final painter = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontFamily: icon.fontFamily,
          fontSize: size,
          color: color,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      Offset((size - painter.width) / 2, (size - painter.height) / 2),
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(size.ceil(), size.ceil());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    painter.dispose();
    image.dispose();
    return bytes?.buffer.asUint8List();
  } catch (_) {
    return null;
  }
}
