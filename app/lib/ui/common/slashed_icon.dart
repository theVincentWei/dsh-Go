import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 斜杠压图标(隐藏态语义,未来静音等场景可复用):先把一条**底色粗条**
/// 压在钟面笔画上(把图标截出「断开感」),再压一条 45° 前景色细斜杠
/// —— Material visibility 的 cutout 观感,不是简单的叠加置灰。
///
/// 布局足迹 = [iconSize] 见方;斜杠略宽(iconSize×1.25)向两侧出血,
/// 不参与布局。
class SlashedIcon extends StatelessWidget {
  const SlashedIcon({
    super.key,
    required this.icon,
    required this.cutoutColor,
    this.color,
    this.iconSize = 20,
    this.slashHeight = 2,
  });

  /// 被斜杠压住的图标(如最近使用的 history 钟面)。
  final IconData icon;

  /// 底色垫条的颜色:取所在圆键的底色,把图标笔画截断。
  final Color cutoutColor;

  /// 图标与斜杠的前景色;缺省跟 IconTheme,再退 onSurfaceVariant。
  final Color? color;
  final double iconSize;

  /// 细斜杠的厚度;底色垫条 = [slashHeight] × 2.4。
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
          // 底色垫条:粗一点,把钟面笔画截断(断开感)。
          Container(
            width: slashWidth,
            height: slashHeight * 2.4,
            decoration: BoxDecoration(
              color: cutoutColor,
              borderRadius: BorderRadius.circular(slashHeight * 1.2),
            ),
          ),
          // 45° 前景色细斜杠。
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
