// 磁贴网格与桌面图标瓷贴,拷贝自宿主 tile_grid.dart(theme 依赖换成包内
// 的 HubMotion / hubGroupTitleStyle,视觉不改)。TileGrid 与 FeatureCard 的
// 其余部分宿主自用,这里只搬桌面用得到的三件。

import 'package:flutter/material.dart';

import '../theme.dart';
import 'pressable.dart';

/// 磁贴网格:默认两列,列宽相等,同一行的磁贴等高(按较高的那块),
/// 行距与列距相同([spacing])。最后一行不满时空位留白,列宽不变。
class TileGrid extends StatelessWidget {
  const TileGrid({
    super.key,
    required this.children,
    this.columns = 2,
    this.spacing = 12,
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
  }) : assert(columns > 0);

  final List<Widget> children;
  final int columns;
  final double spacing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var start = 0; start < children.length; start += columns) {
      final cells = <Widget>[];
      for (var c = 0; c < columns; c++) {
        if (c > 0) cells.add(SizedBox(width: spacing));
        final i = start + c;
        cells.add(Expanded(child: i < children.length ? children[i] : const SizedBox()));
      }
      if (rows.isNotEmpty) rows.add(SizedBox(height: spacing));
      rows.add(
        IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: cells),
        ),
      );
    }
    return Padding(
      padding: padding,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: rows),
    );
  }
}

/// 手机桌面式图标瓷贴:46 圆角方形图标在上、名称在下,无卡片底。桌面引擎
/// 的每颗图标格用这一个组件,保证名称是同一种字、同一套间距与按压反馈。
/// 图标内容([icon])由调用方决定,统一显示时裁切成瓷贴形状(方图 PNG 不
/// 压圆角);[badge] 叠在图标右上角(如未读数);[labelDot] 在名字行尾挂
/// 4px 主色圆点(iOS 式新装/更新指示),false 不占位。[enabled] 为 false
/// 时整块淡到 45%,点击转交 [onDisabledTap](宿主据此弹「本机不可用」类
/// 提示;null = 不响应)。要先选中会话的项用。
class IconTile extends StatelessWidget {
  const IconTile({
    super.key,
    required this.icon,
    required this.label,
    this.badge,
    this.chipColor,
    this.labelDot = false,
    required this.onTap,
    this.onDisabledTap,
    this.enabled = true,
  });

  /// 居中在图标方块里的内容。
  final Widget icon;
  final String label;
  final Widget? badge;

  /// 瓷贴底色覆盖:传实底色(如桌面小程序图标的色相),不传保持主题淡染。
  final Color? chipColor;

  /// 名字行尾小点(iOS 式);false 不占位。
  final bool labelDot;
  final VoidCallback onTap;

  /// [enabled] 为 false 时的点击去向(提示语义归宿主);null = 不响应。
  final VoidCallback? onDisabledTap;
  final bool enabled;

  /// 图标方块的边长与圆角;名称的字形与上下间距也定在这里,调用方不再自设。
  static const dimension = 46.0;
  static const radius = 14.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final chip = SizedBox.square(
      dimension: dimension,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: ShapeDecoration(
                color: chipColor ??
                    scheme.primary.withValues(alpha: scheme.brightness == Brightness.dark ? 0.16 : 0.10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
              ),
              // 图标内容统一显示时裁切成瓷贴形状:png/widget 档的满铺方图
              // 不得压过圆角(交付约定=交付方图不预裁,见桌面契约注记)。
              child: ClipRRect(
                borderRadius: BorderRadius.circular(radius),
                child: Center(child: icon),
              ),
            ),
          ),
          if (badge case final badge?) Positioned(right: -2, top: -2, child: badge),
        ],
      ),
    );
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: Pressable(
        enabled: enabled,
        child: AnimatedOpacity(
          opacity: enabled ? 1 : 0.45,
          duration: HubMotion.of(context, HubMotion.quick),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: enabled ? onTap : onDisabledTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    chip,
                    const SizedBox(height: 6),
                    // 名字行:labelDot 时 [8px 前导平衡位, 名字, 4px,
                    // 4px 主色圆点]——前导 8px 恰好平衡尾部 8px,名字中心
                    // 与格中心对齐(P5.2:否则名字被尾部 8px 挤得左移
                    // 4px,一行里带点的左移、不带点的不动);无点保持纯
                    // 文本,不占位。
                    if (!labelDot)
                      Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                          height: 1.2,
                        ),
                      )
                    else
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                                fontWeight: FontWeight.w600,
                                height: 1.2,
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          Container(
                            key: const ValueKey('hub-label-dot'),
                            width: 4,
                            height: 4,
                            decoration: BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 桌面分组的小标题:小而淡,24 左右缩进,24 上、8 下。
class FeatureGroupLabel extends StatelessWidget {
  const FeatureGroupLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
      child: Semantics(header: true, child: Text(text, style: hubGroupTitleStyle(context))),
    );
  }
}
