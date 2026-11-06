// 全部功能: every official DSH Web feature with a way in — the app's own page
// or the official page inside the app — as a hub of two-column cards in the
// accent; the nine headline features carry their tile in the user's style.
// It holds what you go to do now; settings live in 设置, and the last group
// is a few shortcuts there plus 全部设置 (settings search over the hub).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/bots_state.dart';
import '../../state/sessions_state.dart';
import '../common/app_sheet.dart' show groupTitleStyle;
import '../common/feature_tile.dart';
import '../common/pressable.dart';
import '../common/tile_grid.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import '../web/dsh_web_launcher.dart';
import '../web/web_target.dart';
import '../plugins/seats/seat_probe.dart';
import 'feature_catalog.dart';

/// Opens DSH Web on a target; tests swap it for a recorder.
typedef DshWebOpener = void Function(BuildContext context, WidgetRef ref, DshWebTarget target);

final dshWebOpenerProvider = Provider<DshWebOpener>(
  (ref) =>
      (context, ref, target) => openDshWeb(context, ref, target: target),
);

/// 全部设置入口已随设置 tab 移除;原 [openAllSettings] 一并删除。
class AllFeaturesPage extends ConsumerWidget {
  const AllFeaturesPage({super.key, this.sections});

  /// Defaults to [featureSectionsProvider]: [featureSections] and the
  /// host's plugin panels.
  final List<FeatureSection>? sections;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final sessionId = ref.watch(currentSessionProvider);

    void openWeb(FeatureItem item) => ref.read(dshWebOpenerProvider)(context, ref, item.webFor(sessionId)!);
    void open(FeatureItem item) {
      if (item.native case final page?) {
        Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page(sessionId)));
      } else if (item.action case final action?) {
        unawaited(Future.sync(() => action(context, ref, sessionId)));
      } else {
        openWeb(item);
      }
    }

    final List<FeatureSection> all = sections ?? ref.watch(featureSectionsProvider);
    final page = AppPage.list(
      title: l10n.tabMiniApps,
      children: [
        for (final section in all) ...[
          FeatureGroupLabel(section.title),
          // 手机桌面式:4 列图标网格,图标在上、标签在下,无卡片底。
          TileGrid(
            columns: 4,
            spacing: 16,
            children: [
              for (final item in section.items)
                _AppIconTile(
                  item: item,
                  enabled: !item.needsSession || sessionId != null,
                  onOpen: () => open(item),
                ),
            ],
          ),
          if (section.note case final note?)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 10, 24, 0),
              child: Text(
                note,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary),
              ),
            ),
        ],
      ],
    );
    // Reads which plugins sit where when the engine hasn't said yet; outside
    // the list, so it is built at once and never part of its layout.
    return Stack(
      fit: StackFit.expand,
      children: [
        page,
        const Positioned(left: 0, top: 0, child: SeatProbe()),
      ],
    );
  }
}

/// A group title over a [TileGrid]: small and faint, on the page's 24 column
/// (with the large title and every group title), 24 above, 8 below.
class FeatureGroupLabel extends StatelessWidget {
  const FeatureGroupLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
      child: Semantics(header: true, child: Text(text, style: groupTitleStyle(context))),
    );
  }
}

/// One feature as a card: its [FeatureTile] when it has one, else its icon on
/// an accent circle; 「网页版」 in the corner for items that only live there, a
/// small globe for items that have both.
class FeatureTileFor extends ConsumerWidget {
  const FeatureTileFor({
    super.key,
    required this.item,
    this.tint,
    required this.onOpen,
    this.onOpenWeb,
    this.enabled = true,
  });

  final FeatureItem item;

  /// An identity hue for the circle instead of the accent.
  final int? tint;
  final VoidCallback onOpen;

  /// Secondary way in for items that have both.
  final VoidCallback? onOpenWeb;
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final unread = item.id == 'ds-bot' ? ref.watch(dsBotInboxProvider.select((inbox) => inbox.total)) : 0;
    return FeatureCard(
      icon: item.icon,
      art: switch (item.tile) {
        final kind? => FeatureTile(kind, size: FeatureCard.glyph),
        null => null,
      },
      tint: tint,
      title: item.title,
      subtitle: enabled ? item.summary : l10n.catalogOpenChatFirst,
      enabled: enabled,
      // 「网页版」 itself needs no badge saying so.
      badge: unread > 0
          ? (unread > 99 ? '99+' : '$unread')
          : item.webOnly && item.web != const DshWebTarget()
          ? l10n.commonWeb
          : null,
      corner: onOpenWeb == null
          ? null
          : IconButton(
              tooltip: l10n.commonOpenInWeb,
              padding: EdgeInsets.zero,
              iconSize: FeatureCard.cornerIcon,
              onPressed: enabled ? onOpenWeb : null,
              icon: Icon(AppIcons.webApp, color: scheme.onSurfaceVariant),
            ),
      onTap: onOpen,
    );
  }
}

/// 手机桌面式的一项:图标(功能磁贴,或圆底图标)在上、标签在下,无卡片底。
/// 选中会话才可用的项在未选中时淡到 45%;DS Bot 的未读数是图标右上角的小圆点。
class _AppIconTile extends ConsumerWidget {
  const _AppIconTile({required this.item, required this.onOpen, this.enabled = true});

  final FeatureItem item;
  final VoidCallback onOpen;
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final unread = item.id == 'ds-bot' ? ref.watch(dsBotInboxProvider.select((inbox) => inbox.total)) : 0;
    final chip = SizedBox.square(
      dimension: 46,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: ShapeDecoration(
                color: scheme.primary.withValues(alpha: scheme.brightness == Brightness.dark ? 0.16 : 0.10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              child: Center(
                child: switch (item.tile) {
                  final kind? => FeatureTile(kind, size: 30),
                  null => Icon(item.icon, size: 20, color: scheme.primary),
                },
              ),
            ),
          ),
          if (unread > 0)
            Positioned(
              right: -2,
              top: -2,
              child: Container(
                width: 16,
                height: 16,
                alignment: Alignment.center,
                decoration: ShapeDecoration(color: scheme.error, shape: const CircleBorder()),
                child: Text(
                  unread > 99 ? '99+' : '$unread',
                  style: theme.textTheme.labelSmall?.copyWith(color: scheme.onError, fontSize: 9, height: 1),
                ),
              ),
            ),
        ],
      ),
    );
    return Semantics(
      button: true,
      enabled: enabled,
      label: item.title,
      child: Pressable(
        enabled: enabled,
        child: AnimatedOpacity(
          opacity: enabled ? 1 : 0.45,
          duration: AppMotion.of(context, AppMotion.quick),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: enabled ? onOpen : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    chip,
                    const SizedBox(height: 6),
                    Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                        height: 1.2,
                      ),
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
