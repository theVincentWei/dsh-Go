// SVG 交付物的位图化:预览页直接矢量绘制(artifact_preview 的 svg 分支),
// 缩略图与「保存到相册」则需要位图——系统相册不收 svg 文件,列表小图也吃
// 不下矢量。这里用 flutter_svg 解析(编译到 vector_graphics 的 Picture),
// 再用 Picture.toImage 栅格化成 PNG。

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_svg/flutter_svg.dart';

/// 栅格化的目标宽度:40px 的列表小图放大若干倍仍清楚,整屏看也不糊。
const svgRasterWidth = 512.0;

/// 栅格化的最大高度:超高(长条信息图)按高度约束缩宽。
const svgRasterHeight = 4096.0;

/// 栅格化失败:文档解析不了,或画布/编码拿不到。
class SvgRasterException implements Exception {
  const SvgRasterException();

  @override
  String toString() => 'SvgRasterException';
}

/// [path] 是不是按矢量图渲染的交付物(.svg,大小写不敏感)。
bool isSvgPath(String path) => path.toLowerCase().endsWith('.svg');

/// 一份 SVG 文档 [bytes] 画成 PNG:按视盒比例缩放到宽 ~[svgRasterWidth]
/// (矢量放大无损,小视盒也放大到可用大小),高度最多 [svgRasterHeight]。
Future<Uint8List> rasterizeSvg(
  Uint8List bytes, {
  double width = svgRasterWidth,
  double height = svgRasterHeight,
}) async {
  final PictureInfo info;
  try {
    info = await vg.loadPicture(SvgBytesLoader(bytes), null);
  } catch (_) {
    throw const SvgRasterException();
  }
  try {
    final size = info.size;
    if (!size.width.isFinite ||
        !size.height.isFinite ||
        size.width <= 0 ||
        size.height <= 0) {
      throw const SvgRasterException();
    }
    final scale = (width / size.width).clamp(0.0, height / size.height);
    final raster = await info.picture.toImage(
      (size.width * scale).round().clamp(1, width.round()),
      (size.height * scale).round().clamp(1, height.round()),
    );
    final data = await raster.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) throw const SvgRasterException();
    return data.buffer.asUint8List();
  } finally {
    info.picture.dispose();
  }
}
