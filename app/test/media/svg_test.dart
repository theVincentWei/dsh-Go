// SVG 栅格化:视盒比例出 PNG(缩略图、「保存到相册」共用),画不了的文档
// 明说。

import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_app/media/svg.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _svg(String body) => Uint8List.fromList(utf8.encode(body));

/// PNG 签名 + IHDR 里的宽高(大端,偏移 16/20)。
(int, int) _pngSize(Uint8List png) {
  expect(png.sublist(0, 8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  final header = ByteData.sublistView(png, 16, 24);
  return (header.getUint32(0), header.getUint32(4));
}

void main() {
  test('a drawing rasterizes at the target width, keeping the viewbox ratio', () async {
    final png = await rasterizeSvg(
      _svg('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 5">'
          '<rect width="10" height="5" fill="#f00"/></svg>'),
    );
    expect(_pngSize(png), (512, 256));
  });

  test('a tall drawing is capped by height, not stretched', () async {
    final png = await rasterizeSvg(
      _svg('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 200">'
          '<rect width="10" height="200" fill="#f00"/></svg>'),
    );
    final (width, height) = _pngSize(png);
    expect(height, svgRasterHeight.round());
    expect(width, lessThan(svgRasterWidth.round()));
  });

  test('a document that cannot be parsed says so', () async {
    await expectLater(rasterizeSvg(_svg('<svg><unclosed>')), throwsA(isA<SvgRasterException>()));
    await expectLater(rasterizeSvg(Uint8List(4)), throwsA(isA<SvgRasterException>()));
  });
}
