// The drawer's conversation card and section label.

import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../../state/session_attention_state.dart';
import '../../common/status_dot.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import '../session_list_page.dart' show sessionSelectionColor;

/// One conversation as a glass card: the chat chip on the left, the title
/// (plus [indent] inside a folder) and an optional [subtitle] in the middle,
/// and at the right end one thing at most: what it waits for (待确认 /
/// 待回答), a breathing dot while it works, a quiet dot when it moved on
/// since it was last seen — or, when nothing claims the corner, the
/// [timeText]. The open conversation wears the soft selection fill. In
/// multi-select a check slides in before the chip.
class SessionTile extends StatelessWidget {
  const SessionTile({
    super.key,
    required this.title,
    required this.running,
    required this.current,
    required this.onTap,
    required this.onLongPress,
    this.subtitle,
    this.timeText,
    this.pending,
    this.unread = false,
    this.pinned = false,
    this.indent = 0,
    this.selecting = false,
    this.selected = false,
  });

  final String title;

  /// One line under the title (where the conversation works); null hides it.
  final String? subtitle;

  /// The right end's text (today HH:mm, else M-D) — shown only when nothing
  /// else claims the corner: a marker always wins.
  final String? timeText;
  final bool running;

  /// The open conversation (soft fill; ignored while selecting).
  final bool current;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final PendingKind? pending;
  final bool unread;

  /// Shown as a small pin before the title (inside folders; elsewhere 置顶
  /// says it).
  final bool pinned;

  /// Content inset from the card's edge (folder members: [folderIndent]).
  final double indent;
  final bool selecting;
  final bool selected;

  /// The card's height at scale 1 (the 34 chip plus air); large text grows it.
  static const height = 56.0;

  /// Space around a card: 5 above and below, 10 to the sides.
  static const marginV = 4.0;
  static const marginH = 10.0;

  /// The card's inner padding: the chip and title sit 12 in from the sides,
  /// 10 from top and bottom.
  static const innerH = 12.0;
  static const padV = 8.0;

  /// The left icon chip (34, radius 11) and its gap to the title column.
  static const chipSize = 34.0;
  static const chipRadius = 11.0;
  static const chipGap = 10.0;

  /// A folder's glyph (20) plus its gap (10): members' titles line up with
  /// the folder's name.
  static const folderIndent = 30.0;

  /// Width of the check slot while selecting (a 20 circle and a 10 gap).
  static const checkSlot = 30.0;

  /// Size of the quiet markers at the end of the card.
  static const dot = 7.0;

  /// The title Text's key: tests collect the conversation titles (and not
  /// the cwd subtitle or the time) through it.
  static const titleKey = ValueKey<String>('session-title');

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final shape = Squircle.border(AppShape.md);
    // The card's hairline (onSurface 0.07, 1px) rides on top of the fill as
    // a foreground decoration, so it never squeezes the content's padding.
    final outlined = Squircle.border(AppShape.md, side: BorderSide(color: scheme.onSurface.withValues(alpha: 0.07)));
    final highlighted = selecting ? selected : current;
    final Widget? marker = switch ((pending, running, unread)) {
      (final PendingKind kind, _, _) => Text(
        kind.label,
        key: const ValueKey('pending'),
        style: theme.textTheme.labelMedium?.copyWith(color: colors.warning, fontWeight: FontWeight.w500),
      ),
      (_, true, _) => const StatusDot(key: ValueKey('running'), tone: StatusTone.busy, size: dot),
      (_, _, true) => _UnreadDot(key: const ValueKey('unread'), color: scheme.onSurfaceVariant),
      _ => null,
    };
    final label = [
      title,
      ?pending?.label,
      if (pending == null && running) l10n.shellCurrentlyRunning,
      if (pending == null && !running && unread) l10n.shellUnread,
      if (pinned) l10n.shellPinned,
    ].join(l10n.shellSemanticsSeparator);
    return Semantics(
      selected: highlighted,
      checked: selecting ? selected : null,
      label: label,
      button: true,
      onTap: onTap,
      onLongPress: onLongPress,
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: marginV, horizontal: marginH),
        child: Container(
          foregroundDecoration: ShapeDecoration(shape: outlined),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: onTap,
              onLongPress: onLongPress,
              customBorder: outlined,
              // Ink (not a container's decoration), so the splash draws over the
              // fill; the fill fades between the glass base and the selection.
              child: TweenAnimationBuilder<double>(
                tween: Tween(end: highlighted ? 1 : 0),
                duration: AppMotion.of(context, AppMotion.quick),
                curve: AppMotion.std,
                builder: (context, t, child) {
                  final fill = sessionSelectionColor(context);
                  final base = scheme.onSurface.withValues(alpha: 0.05);
                  return Ink(
                    decoration: ShapeDecoration(color: Color.lerp(base, fill, t), shape: shape),
                    padding: EdgeInsets.fromLTRB(innerH + indent, padV, innerH, padV),
                    child: child,
                  );
                },
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: height),
                  child: Row(
                    children: [
                      _CheckSlot(selecting: selecting, selected: selected),
                      Container(
                        width: chipSize,
                        height: chipSize,
                        decoration: ShapeDecoration(
                          color: scheme.primary.withValues(alpha: scheme.brightness == Brightness.dark ? 0.16 : 0.10),
                          shape: Squircle.border(chipRadius),
                        ),
                        child: Icon(AppIcons.chat, size: 20, color: scheme.primary),
                      ),
                      const SizedBox(width: chipGap),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                if (pinned) ...[
                                  Icon(AppIcons.pinActive, size: 14, color: colors.textTertiary),
                                  const SizedBox(width: 4),
                                ],
                                Expanded(
                                  child: Text(
                                    title,
                                    key: SessionTile.titleKey,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodyLarge?.copyWith(
                                      fontSize: 15,
                                      height: 1.4,
                                      color: scheme.onSurface,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            if (subtitle case final sub?)
                              Text(
                                sub,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  fontSize: 11,
                                  height: 1.3,
                                  color: colors.textTertiary,
                                ),
                              ),
                          ],
                        ),
                      ),
                      AnimatedSwitcher(
                        duration: AppMotion.of(context, AppMotion.quick),
                        layoutBuilder: (current, previous) =>
                            Stack(alignment: Alignment.centerRight, children: [...previous, ?current]),
                        child: switch ((marker, timeText)) {
                          (final marker?, _) => Padding(
                            key: marker.key,
                            padding: const EdgeInsets.only(left: 10),
                            child: marker,
                          ),
                          (null, final time?) => Padding(
                            key: const ValueKey('time'),
                            padding: const EdgeInsets.only(left: 10),
                            child: Text(
                              time,
                              style: AppType.tabular(
                                theme.textTheme.labelSmall!.copyWith(fontSize: 11, color: colors.textTertiary),
                              ),
                            ),
                          ),
                          _ => const SizedBox.shrink(key: ValueKey('none')),
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _UnreadDot extends StatelessWidget {
  const _UnreadDot({super.key, required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: SessionTile.dot,
    height: SessionTile.dot,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

/// The check that slides in before the chip while selecting: a 20 ring,
/// filled with ink and a tick once chosen (ink, not the brand colour — the
/// drawer keeps one primary element).
class _CheckSlot extends StatelessWidget {
  const _CheckSlot({required this.selecting, required this.selected});

  final bool selecting;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return TweenAnimationBuilder<double>(
      tween: Tween(end: selecting ? 1 : 0),
      duration: AppMotion.of(context, AppMotion.standard),
      curve: AppMotion.std,
      builder: (context, t, child) {
        if (t == 0) return const SizedBox.shrink();
        // Height 20: the row bounds the slot's width only — the check circle
        // keeps its own 20 against the unbounded height of the card's row.
        return SizedBox(
          width: SessionTile.checkSlot * t,
          height: 20,
          child: ClipRect(
            child: OverflowBox(
              alignment: Alignment.centerLeft,
              minWidth: SessionTile.checkSlot,
              maxWidth: SessionTile.checkSlot,
              maxHeight: 20,
              child: Opacity(opacity: t, child: child),
            ),
          ),
        );
      },
      child: Align(
        alignment: Alignment.centerLeft,
        child: AnimatedSwitcher(
          duration: AppMotion.of(context, AppMotion.quick),
          child: selected
              ? DecoratedBox(
                  key: const ValueKey('on'),
                  decoration: ShapeDecoration(color: scheme.onSurface, shape: const CircleBorder()),
                  child: SizedBox.square(
                    dimension: 20,
                    child: Icon(AppIcons.selected, size: 14, color: scheme.surface),
                  ),
                )
              : DecoratedBox(
                  key: const ValueKey('off'),
                  decoration: ShapeDecoration(
                    shape: CircleBorder(
                      side: BorderSide(color: scheme.onSurfaceVariant.withValues(alpha: 0.55), width: 1.5),
                    ),
                  ),
                  child: const SizedBox.square(dimension: 20),
                ),
        ),
      ),
    );
  }
}

/// A section label in the drawer list: small, faint, on the 20 line (the
/// list's own inset is gone — the cards carry their 10 margins — so the
/// label insets itself).
class DrawerEyebrow extends StatelessWidget {
  const DrawerEyebrow(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
      child: Semantics(
        header: true,
        child: Text(text, style: AppType.eyebrow(color: DshColors.of(context).textTertiary)),
      ),
    );
  }
}
