/// AppHub 小程序图标库(方案A · 实底彩块):语义 iconKey → 每颗独立配色、
/// 白色字形的实底图标。规范钉死在这里,改任何一颗都别破坏它:
/// - 画布 120×120,圆角 32.4(27%),字形外扩留白 ≥ 45/120;
/// - 字形一律纯白,线宽 6.5~9(120 画布),圆头/圆角连接,60px 下仍可辨;
/// - 每颗一个固定色相,不跟主题;深浅色页同一颗(实底自带对比度)。
///
/// 渲染三处共用:桌面瓷贴([HubAppIcon] glyph 模式 + IconTile chipColor)、
/// 市场列表/详情(tile 模式)、原生菜单头([rasterizeHubAppIconPng] 栅格 PNG)。
/// 新增图标 = 加一个 switch 分支;不认识的 key 返回 null,调用方落
/// `hubAppGlyph` 万能字形(与旧行为一致)。legacy 键(book/chart/puzzle/star)
/// 是旧发布留下的别名,映射到同一批新画法,别删。
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 图标画法:在 120×120 画布上画字形(不含底);[hue] 用于双色字形
/// (如 coin 的白圆底 + 底色 ¥)。
typedef HubIconGlyphPainter = void Function(Canvas canvas, Color hue);

/// 一颗图标的完整定义:底色 + 字形画法。
class HubAppIconSpec {
  const HubAppIconSpec(this.color, this.glyph);

  /// 瓷贴底色(实底,不透明)。
  final Color color;

  /// 字形画法(120 画布坐标,白色为主)。
  final HubIconGlyphPainter glyph;
}

/// 画布边长(所有字形坐标基于它,渲染时整体缩放到目标 size)。
const double hubIconCanvas = 120;

const Map<String, HubAppIconSpec> _specs = <String, HubAppIconSpec>{
  // GLM用量:仪表盘
  'gauge': HubAppIconSpec(Color(0xFF6366F1), _paintGauge),
  // 双拼教练:键盘
  'keyboard': HubAppIconSpec(Color(0xFFF59E0B), _paintKeyboard),
  // 记账本:硬币 ¥
  'coin': HubAppIconSpec(Color(0xFF10B981), _paintCoin),
  // 系统监视器:心电
  'pulse': HubAppIconSpec(Color(0xFF0EA5E9), _paintPulse),
  // Three 3D 基准:立方体线框
  'cube': HubAppIconSpec(Color(0xFF8B5CF6), _paintCube),
  // WeUI:组件四格
  'components': HubAppIconSpec(Color(0xFF07C160), _paintComponents),
  // WebView 3D 基线:经纬地球
  'globe': HubAppIconSpec(Color(0xFF2563EB), _paintGlobe),
  // 深色模式演示:月牙
  'moon': HubAppIconSpec(Color(0xFF64748B), _paintMoon),
};

/// 旧发布用过的语义键:同一批 app 换了新画法,键仍要能渲染出同款新图。
const Map<String, String> _legacyAliases = <String, String>{
  'book': 'coin', // 记账本旧键
  'chart': 'pulse', // 系统监视器旧键
  'star': 'cube', // Three 3D 基准旧键
  'puzzle': 'components', // WeUI 旧键
};

/// 语义键(含 legacy 别名)→ 图标定义;不认识返回 null。
HubAppIconSpec? hubAppIconSpec(String? key) {
  if (key == null || key.isEmpty) return null;
  return _specs[key] ?? _specs[_legacyAliases[key]];
}

/// 该键是否落在图标库里(桌面据此决定实底瓷贴还是万能字形)。
bool hubAppHasIcon(String? key) => hubAppIconSpec(key) != null;

/// AppHub 小程序图标:实底圆角方 + 白字形。
///
/// [tiled] 为 true 画整颗(底+字形,用于无瓷贴容器的场合:市场列表、
/// 详情弹层、原生 PNG 栅格);为 false 只画字形(白色,叠在 IconTile
/// 由调用方传入的实底 chipColor 上,用于桌面瓷贴)。所有出处的字形坐标
/// 同源,大小不同只是整体缩放。
class HubAppIcon extends StatelessWidget {
  const HubAppIcon({super.key, required this.iconKey, this.size = 46, this.tiled = true});

  final String? iconKey;
  final double size;
  final bool tiled;

  @override
  Widget build(BuildContext context) {
    final HubAppIconSpec? spec = hubAppIconSpec(iconKey);
    if (spec == null) return const SizedBox.shrink();
    return CustomPaint(
      size: Size.square(size),
      painter: _HubAppIconPainter(spec, tiled: tiled),
    );
  }
}

class _HubAppIconPainter extends CustomPainter {
  _HubAppIconPainter(this.spec, {required this.tiled});

  final HubAppIconSpec spec;
  final bool tiled;

  @override
  void paint(Canvas canvas, Size size) {
    final double scale = size.width / hubIconCanvas;
    canvas.save();
    canvas.scale(scale);
    if (tiled) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(0, 0, hubIconCanvas, hubIconCanvas),
          const Radius.circular(32.4),
        ),
        Paint()..color = spec.color,
      );
    }
    spec.glyph(canvas, spec.color);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_HubAppIconPainter oldDelegate) =>
      oldDelegate.spec != spec || oldDelegate.tiled != tiled;
}

// ---------- 字形画法(120 画布坐标,白色为主) ----------

Paint _stroke(Color color, double width) => Paint()
  ..color = color
  ..style = PaintingStyle.stroke
  ..strokeWidth = width
  ..strokeCap = StrokeCap.round
  ..strokeJoin = StrokeJoin.round;

Paint _fill(Color color) => Paint()..color = color;

void _paintGauge(Canvas canvas, Color hue) {
  final Paint stroke = _stroke(Colors.white, 9);
  // 半圆表盘:圆心 (60,77) 半径 27,从左到右经顶部。
  canvas.drawArc(
    Rect.fromCircle(center: const Offset(60, 77), radius: 27),
    3.14159265,
    3.14159265,
    false,
    stroke,
  );
  // 指针。
  canvas.drawLine(const Offset(60, 77), const Offset(43, 57), stroke);
}

void _paintKeyboard(Canvas canvas, Color hue) {
  final Path body = Path()
    ..addRRect(RRect.fromRectAndRadius(
      const Rect.fromLTWH(24, 39, 72, 45),
      const Radius.circular(9),
    ));
  canvas.drawPath(body, _stroke(Colors.white, 7));
  final Paint dot = _fill(Colors.white);
  for (final double x in const <double>[35, 50, 65]) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(x, 51, 9, 9), const Radius.circular(2.5)),
      dot,
    );
  }
  canvas.drawRRect(
    RRect.fromRectAndRadius(const Rect.fromLTWH(36, 67, 48, 7.5), const Radius.circular(3.75)),
    dot,
  );
}

void _paintCoin(Canvas canvas, Color hue) {
  // 白色硬币 + 底色 ¥(双色字形)。
  canvas.drawCircle(const Offset(60, 61), 27, _fill(Colors.white));
  final Paint yen = _stroke(hue, 5.5);
  final Path v = Path()
    ..moveTo(51, 49)
    ..lineTo(60, 63)
    ..moveTo(69, 49)
    ..lineTo(60, 63)
    ..moveTo(60, 63)
    ..lineTo(60, 76);
  canvas.drawPath(v, yen);
  final Path bars = Path()
    ..moveTo(51, 63.5)
    ..lineTo(69, 63.5)
    ..moveTo(51, 71)
    ..lineTo(69, 71);
  canvas.drawPath(bars, yen);
}

void _paintPulse(Canvas canvas, Color hue) {
  final Path path = Path()
    ..moveTo(25, 67)
    ..lineTo(41, 67)
    ..lineTo(49, 49)
    ..lineTo(61, 84)
    ..lineTo(72, 57)
    ..lineTo(79, 67)
    ..lineTo(95, 67);
  canvas.drawPath(path, _stroke(Colors.white, 8));
}

void _paintCube(Canvas canvas, Color hue) {
  final Paint stroke = _stroke(Colors.white, 6.5);
  final Path outline = Path()
    ..moveTo(60, 29)
    ..lineTo(88, 45.5)
    ..lineTo(88, 78)
    ..lineTo(60, 94.5)
    ..lineTo(32, 78)
    ..lineTo(32, 45.5)
    ..close();
  canvas.drawPath(outline, stroke);
  final Path inner = Path()
    ..moveTo(32, 45.5)
    ..lineTo(60, 62)
    ..lineTo(88, 45.5)
    ..moveTo(60, 62)
    ..lineTo(60, 94.5);
  canvas.drawPath(inner, stroke);
}

void _paintComponents(Canvas canvas, Color hue) {
  final Paint dot = _fill(Colors.white);
  canvas.drawRRect(
    RRect.fromRectAndRadius(const Rect.fromLTWH(31, 31, 26, 26), const Radius.circular(8)),
    dot,
  );
  canvas.drawCircle(const Offset(76, 44), 13, dot);
  canvas.drawCircle(const Offset(44, 76), 13, dot);
  canvas.drawRRect(
    RRect.fromRectAndRadius(const Rect.fromLTWH(63, 63, 26, 26), const Radius.circular(8)),
    dot,
  );
}

void _paintGlobe(Canvas canvas, Color hue) {
  final Paint stroke = _stroke(Colors.white, 7);
  canvas.drawCircle(const Offset(60, 60), 30, stroke);
  // 经线(竖椭圆)与赤道。
  canvas.drawOval(const Rect.fromLTWH(46, 30, 28, 60), stroke);
  canvas.drawLine(const Offset(32, 60), const Offset(88, 60), stroke);
}

void _paintMoon(Canvas canvas, Color hue) {
  // 月牙:大圆减去右上偏移圆。
  final Path moon = Path()
    ..addOval(Rect.fromCircle(center: const Offset(60, 60), radius: 28));
  final Path cut = Path()
    ..addOval(Rect.fromCircle(center: const Offset(76, 48), radius: 24));
  canvas.drawPath(
    Path.combine(PathOperation.difference, moon, cut),
    _fill(Colors.white),
  );
}

/// 与 [HubAppIcon] 同源的原生栅格:整颗(含实底圆角,四角透明)栅格化成
/// PNG bytes,随 `DiminaHost.open(iconKey:)` 传给原生菜单弹层头部。
/// 不落盘;失败返回 null,原生回落首字母瓦片。
Future<Uint8List?> rasterizeHubAppIconPng(String iconKey, {double size = 96}) async {
  final HubAppIconSpec? spec = hubAppIconSpec(iconKey);
  if (spec == null) return null;
  try {
    final double scale = size / hubIconCanvas;
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    canvas.scale(scale);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(0, 0, hubIconCanvas, hubIconCanvas),
        const Radius.circular(32.4),
      ),
      Paint()..color = spec.color,
    );
    spec.glyph(canvas, spec.color);
    final ui.Picture picture = recorder.endRecording();
    final ui.Image image = await picture.toImage(size.ceil(), size.ceil());
    final ByteData? bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    picture.dispose();
    image.dispose();
    return bytes?.buffer.asUint8List();
  } catch (_) {
    return null;
  }
}
