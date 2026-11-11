// 桌面用到的自建字形子集:与宿主 AppIcons 同源同码点(Phosphor 子集字体
// DshIcons.ttf 由宿主打包,包内只引用 family 名,不携带字体文件)。

import 'package:flutter/material.dart';

/// 自建字形(码点与宿主 `dsh_glyphs.dart` 钉死一致,改任何一边都要同步)。
abstract final class HubIcons {
  static const family = 'DshIcons';

  /// 放大镜(宿主 AppIcons.search = magnifyingGlass)。
  static const search = IconData(0xe03a, fontFamily: family);

  /// 圆底叉(宿主 AppIcons.clear = xCircleFill)。
  static const clear = IconData(0xe036, fontFamily: family);

  /// 叉(宿主 AppIcons.close = x)。
  static const close = IconData(0xe002, fontFamily: family);

  /// 右向小箭头(宿主 AppIcons.disclosure = caretRight)。
  static const disclosure = IconData(0xe006, fontFamily: family, matchTextDirection: true);
}
