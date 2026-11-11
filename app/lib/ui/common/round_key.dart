import 'package:flutter/material.dart';

import '../theme/theme.dart';

/// A pill-glass circle key of a page's title row (no blur: the page sits on
/// the shell's own glass backdrop). 会话列表标题行的钥匙件,抽出来共用:
/// 「服务通知」钥匙在小程序桌面页头也用同一颗(2026-11-11 拍板,星河容器
/// Header 不放通知按钮,入口收在宿主自己的页面头)。
class RoundKey extends StatelessWidget {
  const RoundKey({super.key, required this.icon, required this.tooltip, required this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  static const size = 34.0;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: tooltip,
        onTap: onTap,
        excludeSemantics: true,
        child: SizedBox.square(
          dimension: size,
          child: GlassSurface(
            tier: GlassTier.pill,
            circle: true,
            onTap: onTap,
            child: Center(child: Icon(icon, size: 20, color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ),
        ),
      ),
    );
  }
}

/// 钥匙右上角的未读计数小角标:红底 stadium,99+ 封顶。
class UnreadDot extends StatelessWidget {
  const UnreadDot(this.count, {super.key});

  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
      child: DecoratedBox(
        decoration: ShapeDecoration(color: scheme.error, shape: const StadiumBorder()),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Center(
            widthFactor: 1,
            child: Text(
              count > 99 ? '99+' : '$count',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: scheme.onError,
                fontSize: 9,
                height: 1,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
