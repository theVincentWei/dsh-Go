import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 斜杠压图标(隐藏态语义,未来静音等场景可复用):45° 前景色圆角斜杠
/// 直接压在图标上(实机定稿 3px,不垫底色条——圆键是半透明玻璃,垫条
/// 用任何实色都对不上底、深色下必穿帮出一块方片,真机实锤后弃用)。
///
/// 布局足迹 = [iconSize] 见方;斜杠略宽(iconSize×1.25)向两侧出血,
/// 不参与布局。
class SlashedIcon extends StatelessWidget {
  const SlashedIcon({
    super.key,
    required this.icon,
    this.color,
    this.iconSize = 20,
    this.slashHeight = 3,
  });

  /// 被斜杠压住的图标(如最近使用的 history 钟面)。
  final IconData icon;

  /// 图标与斜杠的前景色;缺省跟 IconTheme,再退 onSurfaceVariant。
  final Color? color;
  final double iconSize;

  /// 斜杠厚度:无垫条时要够粗才压得住钟面笔画(实机定稿 3px)。
  final double slashHeight;

  @override
  Widget build(BuildContext context) {
    final Color ink = color ??
        IconTheme.of(context).color ??
        Theme.of(context).colorScheme.onSurfaceVariant;
    final double slashWidth = iconSize * 1.25;
    return SizedBox.square(
      dimension: iconSize,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: <Widget>[
          Icon(icon, size: iconSize, color: ink),
          // 45° 前景色斜杠,直接压钟面。
          Transform.rotate(
            angle: math.pi / 4,
            child: Container(
              width: slashWidth,
              height: slashHeight,
              decoration: BoxDecoration(
                color: ink,
                borderRadius: BorderRadius.circular(slashHeight / 2),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
