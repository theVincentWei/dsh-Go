// 弹层标题行,拷贝自宿主 sheet_title_bar.dart 的单行形态:标题居左、圆
// 关闭键居右,两边 20 内缩;关闭键 32 圆 + 44 点击区。引擎的弹层都是
// button 收起式,没有二级页返回,不搬 SheetNavigator 与换行排版。

import 'package:flutter/material.dart';

import 'icons.dart';

/// Shared title row: title on the left, a round close key on the right, both
/// centred on one line, 20 in from the sheet's sides.
class SheetTitleBar extends StatelessWidget {
  const SheetTitleBar(this.title, {super.key, required this.closeTooltip, this.onClose});

  final String title;

  /// 关闭键的 tooltip/语义标签(宿主注入)。
  final String closeTooltip;

  /// Defaults to popping the sheet's route.
  final VoidCallback? onClose;

  /// 弹层内容的左右内缩。
  static const inset = 20.0;

  /// 圆键看得见的直径与可点范围。
  static const keySize = 32.0;
  static const _hit = 44.0;
  static const _slack = (_hit - keySize) / 2;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(inset - _slack, 0, inset - _slack, 8),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: _hit),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Semantics(
                header: true,
                child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleLarge),
              ),
            ),
            const SizedBox(width: 8),
            SheetIconButton(icon: HubIcons.close, tooltip: closeTooltip, onPressed: onClose ?? () => Navigator.of(context).maybePop()),
          ],
        ),
      ),
    );
  }
}

/// 弹层标题行里的圆钮:32 的淡色圆 + 18 的图标,点击区 44。
class SheetIconButton extends StatelessWidget {
  const SheetIconButton({super.key, required this.icon, required this.tooltip, required this.onPressed});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        enabled: onPressed != null,
        label: tooltip,
        onTap: onPressed,
        excludeSemantics: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onPressed,
          child: SizedBox.square(
            dimension: 44,
            child: Center(
              child: DecoratedBox(
                decoration: ShapeDecoration(
                  color: scheme.onSurface.withValues(alpha: dark ? 0.10 : 0.06),
                  shape: const CircleBorder(),
                ),
                child: SizedBox.square(
                  dimension: SheetTitleBar.keySize,
                  child: Icon(icon, size: 18, color: scheme.onSurfaceVariant),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
