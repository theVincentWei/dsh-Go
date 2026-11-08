// 「小程序」Tab:现在是一张可整理的桌面(`hub/app_desktop.dart`)——统一
// 应用清单、长按摇摆整理、跨组拖拽、最近使用、搜索。本文件只留三样:页面壳
// (把可选的固定目录喂给桌面)、`dshWebOpenerProvider`(测试替换的网页打开
// 口)和 `FeatureTileFor`(别处在用的功能卡片)。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/bots_state.dart';
import '../common/feature_tile.dart' show FeatureTile;
import '../common/tile_grid.dart' show FeatureCard;
import '../hub/app_desktop.dart';
import '../theme/app_icons.dart';
import '../web/dsh_web_launcher.dart';
import '../web/web_target.dart';
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

  /// Desktop reads [featureSectionsProvider] (static catalog + the host's
  /// plugin panels); tests may pass a fixed list instead.
  final List<FeatureSection>? sections;

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      HubDesktopPage(sections: sections);
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
