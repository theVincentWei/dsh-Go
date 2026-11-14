// 列表行与卡片,拷贝自宿主 list_page_row.dart/row_anatomy.dart,只搬桌面
// 分组管理弹层用得到的部分(图标位 + 标题/副标题 + 可选 ›),测量数字不改。
// 组头未读角标(UnreadBadge)也在这里:primary 胶丸、99+ 封顶、数字滚动。

import 'package:flutter/material.dart';

import '../model.dart' show HubBadge;
import '../theme.dart';
import 'fluid_bits.dart' show RollingCount;
import 'glass.dart' show HubGlassSurface, HubGlassTier;
import 'icons.dart';

/// Shared measurements of every list row(与宿主 RowAnatomy 同一数表)。
abstract final class RowAnatomy {
  /// Minimum height of a one-line row; a row with a subtitle is
  /// [rowHeightTwoLines].
  static const rowHeight = 52.0;
  static const rowHeightTwoLines = 64.0;

  /// Left slot for the row's glyph and the gap between the slot and the title.
  static const glyphSlot = 32.0;
  static const glyphGap = 12.0;

  /// Visible content inset from the card's edge, left and right.
  static const insetH = 16.0;

  /// Right padding of a row ending in a chevron.
  static const trailingPad = 12.0;

  /// The row title: body large at 15 / 1.4.
  static TextStyle? titleStyle(BuildContext context, {Color? color}) =>
      Theme.of(context).textTheme.bodyLarge?.copyWith(fontSize: 15, height: 1.4, color: color);
}

/// 列表页的行:
///
/// ```
/// │ ◌  主标题(一行)                    › │
/// │    副标题(一行)                        │
/// ```
///
/// 左边 [leadingWidth] 宽的图形位(默认 20 号线性图标、次要色,不带底色);
/// 单行最低 52、两行最低 64;右侧可选 ›(默认「有 onTap 就有」)。
class ListPageRow extends StatelessWidget {
  const ListPageRow({
    super.key,
    this.icon,
    this.leading,
    this.leadingWidth = RowAnatomy.glyphSlot,
    required this.title,
    this.subtitle,
    this.subtitleColor,
    this.onTap,
    this.chevron,
    this.iconColor,
  });

  final IconData? icon;

  /// Custom glyph (status dot, avatar); wins over [icon].
  final Widget? leading;
  final double leadingWidth;
  final String title;
  final String? subtitle;
  final Color? subtitleColor;
  final VoidCallback? onTap;

  /// Defaults to "has [onTap]".
  final bool? chevron;
  final Color? iconColor;

  static const glyphSlot = RowAnatomy.glyphSlot;
  static const gap = RowAnatomy.glyphGap;
  static const horizontal = RowAnatomy.insetH;
  static const trailingPad = RowAnatomy.trailingPad;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tertiary = HubColors.of(context).textTertiary;
    final showChevron = chevron ?? onTap != null;
    final two = subtitle != null && subtitle!.isNotEmpty;
    final glyph = leading ??
        (icon == null ? null : Icon(icon, size: 20, color: iconColor ?? scheme.onSurfaceVariant));
    final titleText = Text(
      title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: RowAnatomy.titleStyle(context),
    );
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: two ? RowAnatomy.rowHeightTwoLines : RowAnatomy.rowHeight),
        child: Padding(
          padding: EdgeInsets.fromLTRB(horizontal, 10, showChevron ? trailingPad : horizontal, 10),
          child: Row(
            children: [
              if (glyph != null) ...[
                SizedBox(
                  width: leadingWidth,
                  child: Center(child: glyph),
                ),
                const SizedBox(width: gap),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    titleText,
                    if (two) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(color: subtitleColor ?? tertiary),
                      ),
                    ],
                  ],
                ),
              ),
              if (showChevron) ...[const SizedBox(width: 4), const HubChevron()],
            ],
          ),
        ),
      ),
    );
  }
}

/// 行尾的 ›:20 号自建箭头,三级文字色,右移 3dp 让墨线收在行内边距处
/// (与宿主 OverviewChevron 同款)。
class HubChevron extends StatelessWidget {
  const HubChevron({super.key});

  /// How far the drawn chevron is moved right.
  static const nudge = 3.0;

  @override
  Widget build(BuildContext context) {
    return Transform.translate(
      offset: const Offset(nudge, 0),
      child: ExcludeSemantics(
        child: Icon(HubIcons.disclosure, size: 20, color: HubColors.of(context).textTertiary),
      ),
    );
  }
}

/// 一块 [ListPageRow] 卡片:card 级玻璃、20 圆角、行与行贴着(无分隔线),
/// 上下各 4(与宿主 ListPageCard 同款)。
class ListPageCard extends StatelessWidget {
  const ListPageCard({
    super.key,
    required this.children,
    this.margin = const EdgeInsets.fromLTRB(16, 0, 16, 0),
  });

  final List<Widget> children;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: margin,
      child: HubGlassSurface(
        tier: HubGlassTier.card,
        child: Material(
          type: MaterialType.transparency,
          clipBehavior: Clip.antiAlias,
          shape: const RoundedSuperellipseBorder(borderRadius: BorderRadius.all(Radius.circular(20))),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: children,
            ),
          ),
        ),
      ),
    );
  }
}

/// 组头未读角标(与宿主 UnreadBadge 同款):primary 胶丸,99+ 封顶,数字
/// 滚动只认 [HubBadge.count] / [HubBadge.text]。
class HubUnreadBadge extends StatelessWidget {
  const HubUnreadBadge(this.badge, {super.key});

  final HubBadge badge;

  static const height = 20.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = badge.color ?? scheme.primary;
    final String label = switch (badge) {
      HubBadge(count: final int c?) when c > 0 => c > 99 ? '99+' : '$c',
      HubBadge(text: final String t?) when t.isNotEmpty => t,
      _ => '',
    };
    if (label.isEmpty) return const SizedBox.shrink();
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: height, minHeight: height, maxHeight: height),
      child: DecoratedBox(
        decoration: ShapeDecoration(color: color, shape: const StadiumBorder()),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Center(
            widthFactor: 1,
            child: RollingCount(
              label,
              textScaler: TextScaler.noScaling,
              style: hubTabular(
                Theme.of(context).textTheme.labelSmall!
                    .copyWith(color: scheme.onPrimary, fontWeight: FontWeight.w600, height: 1),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
