// The drawer's conversation list once it has loaded:
// DS Bot's row, 置顶, the folders (opening and closing in place), then the
// rest by day; or, under a status filter, just the matches. Loading, error
// and empty-host states stay with the drawer (sessions_drawer.dart).

import 'package:dsh_client/dsh_client.dart' show SessionSummary;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../state/drawer_view_state.dart';
import '../../../state/session_attention_state.dart';
import '../../../state/session_created_state.dart';
import '../../../state/sessions_state.dart';
import '../../../state/workspaces_state.dart';
import '../../common/empty_view.dart';
import '../../theme/app_icons.dart';
import '../../theme/motion.dart';
import '../session_list_page.dart' show sessionTimeText, sessionTitle;
import 'drawer_actions.dart';
import 'folder_header.dart';
import 'session_tile.dart';

class DrawerConversationList extends ConsumerWidget {
  const DrawerConversationList({
    super.key,
    required this.onOpen,
    required this.onLongPress,
    this.onNewChat,
    this.leading,
    this.now,
    this.readOnly = false,
  });

  /// Opens a conversation (and closes the drawer).
  final ValueChanged<String> onOpen;

  /// Closes the drawer after choosing a folder for a new conversation.
  final VoidCallback? onNewChat;

  /// A conversation's actions.
  final void Function(SessionSummary session) onLongPress;

  /// Above everything when nothing is filtered or chosen (DS Bot's row).
  final Widget? leading;

  /// Clock override for the day groups (tests).
  final DateTime? now;
  final bool readOnly;

  /// The list's padding. The cards carry their own 10 margins, so the list
  /// only insets vertically; rows that stay plain (the DS Bot row, the
  /// folders' headers) wrap themselves in the 10.
  static const padding = EdgeInsets.fromLTRB(0, 4, 0, 16);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final now = this.now ?? DateTime.now();
    final blocks = watchDrawerBlocks(ref, now: now);
    if (blocks == null) return const SizedBox.shrink();
    final selection = ref.watch(drawerSelectionProvider);
    final selecting = !readOnly && selection != null;
    final filter = ref.watch(drawerFilterProvider);
    final pending = ref.watch(pendingInteractionsProvider);
    final unread = ref.watch(unreadSessionIdsProvider);
    final pinned = ref.watch(workspacesProvider.select((s) => s.pinnedSessionIds)).toSet();
    final sort = ref.watch(drawerViewProvider.select((v) => v.sort));
    // 副标题待定集合:补读在途的行显示三点占位。readOnly 的机器人抽屉
    // 不触碰 sessionsProvider;重建由 watchDrawerBlocks 对 sessionsProvider
    // 的 watch 带动,所以这里 read 一次即可拿到最新集合。
    final pendingSubtitles = readOnly ? const <String>{} : ref.read(sessionsProvider.notifier).pendingSubtitleIds;
    if (!readOnly && sort == DrawerSort.created) {
      final ids = [
        for (final block in blocks)
          for (final s in block.items) s.sessionId,
      ];
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) ref.read(sessionCreatedProvider.notifier).ensure(ids);
      });
    }
    final selectionNotifier = ref.read(drawerSelectionProvider.notifier);

    // Keep only builders for off-screen rows: preparing a title and a tile for
    // every conversation makes even a selection change scale with the history.
    final rows = <({Key key, WidgetBuilder builder})>[];
    void add(Key key, WidgetBuilder builder) => rows.add((key: key, builder: builder));

    Widget tile(SessionSummary s, {bool inFolder = false, SessionGroupPos pos = SessionGroupPos.single}) {
      final id = s.sessionId;
      final cwd = s.cwd?.trim();
      return SessionTile(
        key: ValueKey('session-$id'),
        sessionId: id,
        title: sessionTitle(s),
        // 第二行:最近一条消息(引擎补 preview 后),还没有就回退 cwd;都空不渲染。
        // 待定(补读在途)时显示三点占位,行高锁定两行。
        subtitle: s.previewText ?? (cwd == null || cwd.isEmpty ? null : s.cwd),
        subtitlePending: !readOnly && pendingSubtitles.contains(id),
        timeText: sessionTimeText(s.updatedAt, now),
        running: s.running,
        groupPosition: pos,
        pending: readOnly ? null : pending[id],
        unread: !readOnly && unread.contains(id),
        pinned: inFolder && pinned.contains(id),
        indent: inFolder ? SessionTile.folderIndent : 0,
        selecting: selecting,
        selected: selection?.contains(id) ?? false,
        onTap: selecting ? () => selectionNotifier.toggle(id) : () => onOpen(id),
        onLongPress: readOnly
            ? null
            : selecting
            ? () => selectionNotifier.toggle(id)
            : () => onLongPress(s),
      );
    }

    /// 同组行拼一张卡:按位次给圆角(唯一/首/中/尾)。
    void addSessions(List<SessionSummary> items) {
      for (var i = 0; i < items.length; i++) {
        final s = items[i];
        final pos = items.length == 1
            ? SessionGroupPos.single
            : i == 0
            ? SessionGroupPos.first
            : i == items.length - 1
            ? SessionGroupPos.last
            : SessionGroupPos.middle;
        add(ValueKey('session-${s.sessionId}'), (_) => tile(s, pos: pos));
      }
    }

    final showLeading = leading != null && filter == DrawerFilter.all && !selecting;
    if (showLeading) {
      const key = ValueKey('leading');
      add(key, (_) => KeyedSubtree(key: key, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: leading!)));
    }
    var foldersLabelled = false;
    for (final block in blocks) {
      switch (block) {
        case FilteredBlock(filter: final matching, :final items) when items.isEmpty:
          const key = ValueKey('filter-empty');
          add(key, (_) => _FilterEmpty(matching, key: key));
        case FilteredBlock(:final items):
          addSessions(items);
        case PinnedBlock(:final items):
          const key = ValueKey('pinned-label');
          add(key, (_) => DrawerEyebrow(l10n.commonPin, key: key));
          addSessions(items);
        case FolderBlock(:final folder, :final items):
          if (!foldersLabelled) {
            foldersLabelled = true;
            const key = ValueKey('folders-label');
            add(key, (_) => DrawerEyebrow(l10n.shellFolders, key: key));
          }
          final headerKey = ValueKey('folder-${folder.id}');
          add(
            headerKey,
            // The header stays a plain row: it keeps the same 16 edges the
            // group cards give themselves.
            (_) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: DrawerFolderHeader(
                key: headerKey,
                folder: folder,
                count: items.length,
                onTap: () => ref.read(drawerViewProvider.notifier).toggleCollapsed(folder.id),
                onLongPress: () {
                  if (!readOnly) folderActionsFlow(context, ref, folder, onNewChat: onNewChat);
                },
              ),
            ),
          );
          final bodyKey = ValueKey('folder-body-${folder.id}');
          add(
            bodyKey,
            (_) => DrawerFolderBody(
              key: bodyKey,
              open: !folder.collapsed,
              childrenBuilder: () => [
                for (var i = 0; i < items.length; i++)
                  tile(
                    items[i],
                    inFolder: true,
                    pos: items.length == 1
                        ? SessionGroupPos.single
                        : i == 0
                        ? SessionGroupPos.first
                        : i == items.length - 1
                        ? SessionGroupPos.last
                        : SessionGroupPos.middle,
                  ),
              ],
            ),
          );
        case DayBlock(:final day, :final items):
          final key = ValueKey('day-${day.name}');
          add(key, (_) => DrawerEyebrow(sessionDayLabels[day]!, key: key));
          addSessions(items);
      }
    }
    // Preserve keyed row/folder state when pinning, sorting or hiding the
    // leading row changes indices. A new filter still starts at the top.
    final indices = {for (var i = 0; i < rows.length; i++) rows[i].key: i};
    return ListView.builder(
      key: ValueKey(filter),
      physics: AppMotion.scrollPhysics(context),
      padding: padding,
      itemCount: rows.length,
      itemBuilder: (context, index) => rows[index].builder(context),
      findChildIndexCallback: (key) => indices[key],
    );
  }
}

/// A status filter with no matches.
class _FilterEmpty extends StatelessWidget {
  const _FilterEmpty(this.filter, {super.key});

  final DrawerFilter filter;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final (icon, title) = switch (filter) {
      DrawerFilter.running => (AppIcons.running, l10n.shellNoRunningChats),
      DrawerFilter.pending => (AppIcons.toConfirm, l10n.shellNoPendingChats),
      DrawerFilter.unread => (AppIcons.allRead, l10n.shellNoUnreadChats),
      DrawerFilter.all => (AppIcons.chat, l10n.shellNoChatsYet),
    };
    return Padding(
      padding: const EdgeInsets.only(top: 56),
      child: EmptyView(compact: true, icon: icon, title: title),
    );
  }
}
