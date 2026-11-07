/// The container's capsule: the always-reachable control for a mini app.
///
/// Expanded it is the WeChat-style pill (menu + close); when the page is being
/// touched (events arrive via DshAppUi) it collapses to a handle sticking to
/// the right edge, out of the content's way. Tap the handle to expand again.
/// Native Flutter, so it follows the app theme without any page cooperation.
library;

import 'package:flutter/material.dart';

class AppletCapsule extends StatelessWidget {
  const AppletCapsule({
    super.key,
    required this.expanded,
    required this.topInset,
    required this.onExpand,
    required this.onMenu,
    required this.onClose,
  });

  final bool expanded;

  /// Status-bar padding, so the capsule never sits under system UI.
  final double topInset;

  /// Tapping the collapsed edge handle.
  final VoidCallback onExpand;

  /// The ⋯ button; the parent shows the menu (refresh / about).
  final VoidCallback onMenu;

  /// The ✕ button; the parent closes the container.
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Color background = colors.surface.withValues(alpha: 0.92);
    final Color border = colors.outlineVariant.withValues(alpha: 0.6);
    final ShapeBorder expandedShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
      side: BorderSide(color: border),
    );

    return Positioned(
      top: topInset + 8,
      right: expanded ? 12 : 4,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (Widget child, Animation<double> animation) =>
            FadeTransition(opacity: animation, child: child),
        child: expanded
            ? Material(
                key: const ValueKey<bool>(true),
                color: background,
                shape: expandedShape,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    _CapsuleButton(icon: Icons.more_horiz, onTap: onMenu),
                    _divider(colors),
                    _CapsuleButton(icon: Icons.close, onTap: onClose),
                  ],
                ),
              )
            : Material(
                key: const ValueKey<bool>(false),
                color: background,
                shape: RoundedRectangleBorder(
                  borderRadius: const BorderRadius.all(Radius.circular(14)),
                  side: BorderSide(color: border),
                ),
                child: InkWell(
                  onTap: onExpand,
                  customBorder: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(14))),
                  child: SizedBox(
                    width: 18,
                    height: 32,
                    child: Icon(Icons.chevron_left, size: 16, color: colors.onSurfaceVariant),
                  ),
                ),
              ),
      ),
    );
  }

  Widget _divider(ColorScheme colors) => Container(
        width: 1,
        height: 18,
        margin: const EdgeInsets.symmetric(vertical: 7),
        color: colors.outlineVariant,
      );
}

class _CapsuleButton extends StatelessWidget {
  const _CapsuleButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        width: 44,
        height: 32,
        child: Icon(icon, size: 18, color: colors.onSurfaceVariant),
      ),
    );
  }
}
