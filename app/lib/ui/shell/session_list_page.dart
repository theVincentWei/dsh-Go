// The 聊天 tab: the former sessions drawer's content as a full page.
//
// Title row (范围 / 搜索 / 更多 round keys beside the big title — the host
// key lives on the shell's bottom bar now), the status filter pills, the
// conversations (pinned, folders, then by day) and a floating 新对话
// button. In multi-select the title row gives way to the selection header
// and an action bar pins to the bottom.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../runtime/local_footprint.dart';
import '../../runtime/runtime_bridge.dart';
import '../../runtime/runtime_state.dart';
import '../../state/bots_state.dart';
import '../../state/connection_state.dart';
import '../../state/drawer_view_state.dart';
import '../../state/engine_control.dart';
import '../../state/hosts_state.dart';
import '../../state/onboarding_state.dart' show localEngineAvailableProvider;
import '../../state/read_list_identity.dart';
import '../../state/session_attention_state.dart';
import '../../state/session_deletion_state.dart';
import '../../state/sessions_state.dart';
import '../../state/workspaces_state.dart';
import '../bots/bots_page.dart' show BotsPage, UnreadBadge;
import '../chat/media/media_format.dart' show chatTitleShown;
import '../common/app_dialog.dart';
import '../common/app_sheet.dart';
import '../common/empty_view.dart';
import '../common/read_list_status.dart';
import '../common/smooth_size.dart';
import '../common/status_dot.dart';
import '../onboarding/local_install.dart';
import '../safe_mode/engine_failure_card.dart';
import '../safe_mode/safe_mode_banner.dart';
import '../share/share_entry.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import '../workspace/workspace_switcher.dart';
import '../workspace/workspaces_page.dart';
import '../pets/pet_perch.dart';
import '../pets/pet_stage.dart';
import 'adaptive/adaptive_layout.dart' show WindowClass;
import 'drawer/drawer_actions.dart';
import 'drawer/drawer_destination.dart';
import 'drawer/archive_notice.dart';
import 'drawer/drawer_filter_bar.dart';
import 'drawer/drawer_list.dart';
import 'drawer/selection_bars.dart';
import 'drawer/session_deletion.dart';
import 'page_frame.dart' show GlassIconButton;
import 'session_search_page.dart';

export '../../state/drawer_view_state.dart' show SessionDay, sessionDayOf;
export 'drawer/drawer_destination.dart';
export 'drawer/session_tile.dart' show SessionAvatarGallery, SessionTile;

import 'drawer/session_tile.dart';

/// Display title for a session: DSH's generated title (a generation
/// request's header left out), else a neutral fallback.
String sessionTitle(SessionSummary s) {
  final t = s.title?.trim();
  return t == null || t.isEmpty ? appL10n.commonUntitledChat : chatTitleShown(t);
}

/// The soft fill behind the current conversation (list and search).
Color sessionSelectionColor(BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  return scheme.primary.withValues(alpha: scheme.brightness == Brightness.dark ? 0.18 : 0.09);
}

/// A card's right-end time: today HH:mm, else M-D — with the year once the
/// conversation goes back past this one.
String sessionTimeText(DateTime at, DateTime now) {
  String two(int v) => v.toString().padLeft(2, '0');
  if (at.year == now.year && at.month == now.month && at.day == now.day) {
    return '${two(at.hour)}:${two(at.minute)}';
  }
  final md = '${at.month}-${at.day}';
  return at.year == now.year ? md : '${at.year}-$md';
}

/// The 聊天 tab's page: title row, status filters, the active host's
/// conversations and a floating 新对话. [onOpenChat] runs after the session
/// selection state is already set: the shell shows the chat over the tabs.
/// [onDestination] hosts pages that are not tabs (网页版, 远程, 引擎…).
class SessionListPage extends ConsumerStatefulWidget {
  const SessionListPage({
    super.key,
    required this.onOpenChat,
    required this.onDestination,
    this.now,
  });

  final VoidCallback onOpenChat;

  /// Non-tab destinations still open as pushed pages (网页版 / 远程 / 引擎 / 设置搜索).
  final ValueChanged<DrawerDestination> onDestination;

  /// Clock override for grouping (tests).
  final DateTime? now;

  @override
  ConsumerState<SessionListPage> createState() => _SessionListPageState();
}

class _SessionListPageState extends ConsumerState<SessionListPage> {
  /// The list's scroll, 0 at rest → 1 once a card has slid 24px under the
  /// title row; drives the header's wash-out fade — the chat list's own
  /// formula (chat_list.dart).
  final _scrolledUnder = ValueNotifier<double>(0);

  /// The floating header (title row + filters): the list clears exactly it
  /// (chat's topInset) and the wash-out fade runs this tall.
  final _headerKey = GlobalKey();
  double _headerExtent = 0;

  @override
  void dispose() {
    _scrolledUnder.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    // 浮动 header 的高度逐帧盯着量:冷启动首帧时工作区/文案还没就位,量出来
    // 会偏小(「今天」就滑进 header 底下),而内容就位后页面自己不一定再
    // build。空闲时没有帧,这个回调也就不跑,零常驻开销。
    WidgetsBinding.instance.addPostFrameCallback(_measureHeader);
  }

  void _measureHeader(Duration _) {
    if (!mounted) return;
    final box = _headerKey.currentContext?.findRenderObject() as RenderBox?;
    final h = box?.size.height ?? 0;
    if (h != 0 && h != _headerExtent) setState(() => _headerExtent = h);
    WidgetsBinding.instance.addPostFrameCallback(_measureHeader);
  }

  @override
  Widget build(BuildContext context) {
    final onOpenChat = widget.onOpenChat;
    final onDestination = widget.onDestination;
    final now = widget.now;
    void newChat() {
      ref.read(currentSessionProvider.notifier).select(null);
      onOpenChat();
    }

    final selecting =
        ref.watch(drawerSelectionProvider.select((s) => s != null)) && ref.watch(drawerScopeProvider)?.readOnly != true;
    // The list stays mounted with the shell: it keeps the unread record
    // following what the person opens and leaves.
    ref.listen(drawerSeenProvider, (_, _) {});
    // On another tab (an IndexedStack disables its tickers), multi-select
    // ends with the page.
    if (selecting && !TickerMode.valuesOf(context).enabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) ref.read(drawerSelectionProvider.notifier).end();
      });
    }
    // Folders forget conversations the host no longer has.
    ref.listen(sessionsProvider, (_, next) {
      if (!next.hasValue || next.isLoading) return;
      final known = {for (final s in ref.read(sessionsProvider.notifier).allSessions) s.sessionId};
      if (known.isNotEmpty) unawaited(ref.read(drawerViewProvider.notifier).forgetMissing(known));
    });
    final quick = AppMotion.of(context, AppMotion.quick);
    // A phone on its side: the top of the page (title, filters) would leave
    // room for two conversations, so it scrolls away with them.
    final short = MediaQuery.sizeOf(context).height < WindowClass.compactHeight;
    final top = <Widget>[
      AnimatedSwitcher(
        duration: quick,
        child: selecting
            ? DrawerSelectionHeader(key: const ValueKey('selecting'), now: now)
            : Padding(
                key: const ValueKey('title'),
                // 与 AppPage 枢纽页的大标题同一档字级和左缘（24）。
                padding: const EdgeInsets.fromLTRB(24, 6, 10, 10),
                child: _TitleRow(onOpenChat: onOpenChat, onDestination: onDestination),
              ),
      ),
      // Local-engine only: with the 「远程主机」 decline nothing mounts.
      if (ref.watch(localEngineAvailableProvider))
        SafeModeBanner(
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
          onDetails: () => onDestination(DrawerDestination.engine),
        ),
      SmoothSize(
        duration: AppMotion.of(context, AppMotion.standard),
        curve: AppMotion.std,
        alignment: Alignment.topCenter,
        child: const DrawerFilterBar(),
      ),
    ];
    // 状态栏内边距手动管(不用 SafeArea):页面底要铺到屏幕最顶,渐变也从
    // 屏幕顶开始 —— 与设置/全部功能(AppPage)同一观感。
    final padTop = MediaQuery.paddingOf(context).top;
    // Where the floating header ends: measured every frame (see
    // _measureHeader — the selection header, the banner and the workspace
    // pill all change it after the first build); the list clears exactly it
    // and the wash-out fade runs this tall.
    final list = _EdgeFade(
      child: _SessionList(onOpenChat: onOpenChat, onDestination: onDestination, now: now, topInset: padTop + _headerExtent),
    );

    // 与设置/全部功能同一块页面底:状态栏区不再透出壳层/壁纸。
    final content = AppBackdrop(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (short)
            Expanded(
              child: SafeArea(
                bottom: false,
                child: NestedScrollView(
                  headerSliverBuilder: (context, _) => [
                    SliverToBoxAdapter(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: top),
                    ),
                  ],
                  body: list,
                ),
              ),
            )
          else
            // Chat-style: the list runs behind the floating header, and once
            // a card has slid 24px under it the header's wash-out fade comes
            // on (the same extentBefore/24 the chat list reports). At rest
            // the header floats on the page backdrop with nothing under it.
            Expanded(
              child: NotificationListener<ScrollNotification>(
                onNotification: (n) {
                  if (n.depth == 0) _scrolledUnder.value = (n.metrics.extentBefore / 24).clamp(0.0, 1.0);
                  return false;
                },
                child: Stack(
                  children: [
                    Positioned.fill(child: list),
                    Positioned(
                      left: 0,
                      right: 0,
                      top: 0,
                      child: ValueListenableBuilder<double>(
                        valueListenable: _scrolledUnder,
                        builder: (context, t, child) => Opacity(opacity: t, child: child),
                        child: TopFade(height: padTop + _headerExtent + 12),
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      top: padTop,
                      child: KeyedSubtree(
                        key: _headerKey,
                        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: top),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          // In multi-select the action bar pins to the bottom, over where
          // the FAB floats.
          Padding(
            padding: const EdgeInsets.only(bottom: 78),
            child: AnimatedSwitcher(
              duration: quick,
              child: selecting
                ? SelectionActionBar(
                    key: const ValueKey('selecting'),
                    onMove: () {
                      if (ref.read(drawerScopeProvider)?.readOnly == false) {
                        moveToFolderFlow(
                          context,
                          ref,
                          ref.read(drawerSelectionProvider)?.toList() ?? const [],
                        );
                      }
                    },
                    onPin: () {
                      if (ref.read(drawerScopeProvider)?.readOnly == false) pinSelectionFlow(context, ref);
                    },
                    onArchive: () {
                      if (ref.read(drawerScopeProvider)?.readOnly == false) {
                        archiveSelectionFlow(context, ref);
                      }
                    },
                    onDelete: () {
                      if (ref.read(drawerScopeProvider)?.readOnly == false) {
                        unawaited(deleteSelectionFlow(context, ref));
                      }
                    },
                  )
                : const SizedBox.shrink(),
            ),
          ),
        ],
      ),
    );

    // 宠物回到首页:会话 tab 上有舞台,其他会话的通知才走它的气泡
    // (改版把聊天页推入全屏后,舞台一度只剩聊天页里,首页的气泡就断了)。
    // 气泡的「去看一眼」交给 onOpenChat:列表上点气泡要推入聊天页,光改
    // 选中在屏上看不见。
    return PetStage(
      onOpenChat: onOpenChat,
      child: Stack(
      children: [
        Positioned.fill(child: content),
        // 新对话: a floating round key above the bottom bar's glass pieces,
        // out of the action bar's way in multi-select.
        Positioned(
          right: 16,
          bottom: selecting ? 0 : 100,
          child: AnimatedOpacity(
            opacity: selecting ? 0 : 1,
            duration: quick,
            child: IgnorePointer(
              ignoring: selecting,
              child: PetPerch(
                // 站杆:宠物落在新对话键的上沿。
                kind: PerchKind.composer,
                child: GlassIconButton(
                  icon: AppIcons.newChat,
                  tooltip: context.l10n.commonNewChat,
                  onPressed: newChat,
                  // 独立浮件,不在 BackdropGroup 里。
                  grouped: false,
                ),
              ),
            ),
          ),
        ),
      ],
      ),
    );
  }
}

/// 「聊天」 and the three round keys: the conversation scope, search, and the
/// list's view options (the host key sits on the shell's bottom bar).
class _TitleRow extends ConsumerWidget {
  const _TitleRow({required this.onOpenChat, required this.onDestination});

  final VoidCallback onOpenChat;
  final ValueChanged<DrawerDestination> onDestination;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    return Row(
      children: [
        Expanded(child: Text(context.l10n.chatListTitle, style: Theme.of(context).textTheme.headlineLarge)),
        _RoundKey(
          icon: AppIcons.folderOpen,
          tooltip: l10n.remoteWorkspace,
          onTap: () => showWorkspaceSheet(
            context,
            onManage: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const WorkspacesPage())),
          ),
        ),
        const SizedBox(width: 8),
        _RoundKey(
          icon: AppIcons.search,
          tooltip: l10n.shellSearchChats,
          onTap: () async {
            final sessionId = await showSessionSearch(context);
            if (sessionId == null || !context.mounted) return;
            ref.read(currentSessionProvider.notifier).select(sessionId);
            onOpenChat();
          },
        ),
        const SizedBox(width: 8),
        const _ViewOptionsKey(),
      ],
    );
  }
}

/// A pill-glass circle key of the title row (no blur: the page sits on the
/// shell's own glass backdrop).
class _RoundKey extends StatelessWidget {
  const _RoundKey({required this.icon, required this.tooltip, required this.onTap});

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

/// 「对话列表」 options as one of the title row's keys; only while there are
/// conversations to organise.
class _ViewOptionsKey extends ConsumerWidget {
  const _ViewOptionsKey();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = ref.watch(drawerScopeProvider);
    final filtered = ref.watch(drawerFilterProvider) != DrawerFilter.all;
    ref.watch(sessionsProvider);
    final hasArchived = ref.read(sessionsProvider.notifier).archivedSessions.isNotEmpty;
    if (scope == null || (scope.sessions.isEmpty && !filtered && !hasArchived)) return const SizedBox.shrink();
    return _RoundKey(
      icon: AppIcons.more,
      tooltip: context.l10n.shellChatList,
      onTap: () => openDrawerViewOptions(context, ref),
    );
  }
}

/// Soft top and bottom edges on the list, so rows fade into the header and
/// the tab bar instead of being cut. At rest nothing is under either fade
/// (the list's own padding is deeper).
class _EdgeFade extends StatelessWidget {
  const _EdgeFade({required this.child});

  final Widget child;

  static const _top = 10.0;
  static const _bottom = 16.0;

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (rect) {
        final h = rect.height <= 0 ? 1.0 : rect.height;
        return LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: const [Color(0x00000000), Color(0xFF000000), Color(0xFF000000), Color(0x00000000)],
          stops: [0, (_top / h).clamp(0.0, 0.5), (1 - _bottom / h).clamp(0.5, 1.0), 1],
        ).createShader(rect);
      },
      child: child,
    );
  }
}

class _SessionList extends ConsumerWidget {
  const _SessionList({
    required this.onOpenChat,
    required this.onDestination,
    this.now,
    this.topInset = 0,
  });

  final VoidCallback onOpenChat;

  /// Clears the floating header: the first card starts below it.
  final double topInset;
  final ValueChanged<DrawerDestination> onDestination;
  final DateTime? now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 头像图库一次性预解码进全局图片缓存: 否则从聊天页返回列表时,可见行
    // 的头像各自异步解码,首帧只有圆盘没有图(precacheAll 自身幂等)。
    unawaited(SessionAvatarGallery.precacheAll(context));
    final l10n = context.l10n;
    final sessions = ref.watch(sessionsProvider);
    final identity = ref.watch(readListIdentityProvider);
    final workspace = ref.watch(selectedWorkspaceProvider);
    // Null while loading, or while a selected workspace's members haven't
    // arrived (rather than flash every conversation).
    final scope = ref.watch(drawerScopeProvider);
    if (scope == null) {
      if (ref.watch(readListLiveConnectionProvider) == null && !sessions.isLoading) return const _EmptyState();
      if (sessions.hasError) {
        return _Centered(
          child: EmptyView(
            compact: true,
            icon: AppIcons.offline,
            title: l10n.shellChatsLoadFailed,
            actionLabel: l10n.commonRetry,
            onAction: () => ref.read(sessionsProvider.notifier).refresh(),
          ),
        );
      }
      return const _SkeletonList();
    }
    // DS Bot's conversations (its Bots' chats, groups, members' sessions)
    // fold into one row that opens the Bot pages.
    final botReady = ref.watch(dsBotProvider.select((s) => s.ready));
    final showBots = scope.bots.isNotEmpty || (workspace == null && botReady);
    if (scope.sessions.isEmpty && !showBots && ref.watch(drawerViewProvider).folders.isEmpty) {
      if (scope.readOnly) return _Centered(child: Text(readListStatusText(scope.status)));
      return workspace == null ? const _EmptyState() : const _WorkspaceEmptyState();
    }
    return DrawerConversationList(
      now: now,
      onNewChat: onOpenChat,
      readOnly: scope.readOnly,
      topInset: topInset,
      leading: showBots
          ? DsBotDrawerRow(
              running: scope.bots.any((s) => s.running),
              onTap: () => Navigator.of(context).push(BotsPage.route()),
            )
          : null,
      onOpen: (id) {
        if (ref.read(readListIdentityProvider) != identity ||
            ref.read(drawerScopeProvider)?.sessions.any((s) => s.sessionId == id) != true) {
          return;
        }
        ref.read(currentSessionProvider.notifier).select(id);
        onOpenChat();
      },
      onLongPress: (s) {
        final current = ref.read(drawerScopeProvider);
        if (ref.read(readListIdentityProvider) == identity &&
            current?.readOnly == false &&
            current!.sessions.any((row) => identical(row, s))) {
          _showActions(context, ref, s);
        }
      },
    );
  }

  Future<void> _showActions(BuildContext context, WidgetRef ref, SessionSummary s) async {
    // Consent belongs to the host/generation present before the action sheet.
    final owner = captureSessionDeletionOwner(ref);
    try {
      await _showOwnedActions(context, ref, s, owner);
    } finally {
      owner?.close();
    }
  }

  Future<void> _showOwnedActions(
    BuildContext context,
    WidgetRef ref,
    SessionSummary s,
    SessionDeletionOwner? deletionOwner,
  ) async {
    final title = sessionTitle(s);
    final workspaces = ref.read(workspacesProvider);
    final pinned = workspaces.pinnedSessionIds.contains(s.sessionId);
    final inFolder = ref.read(drawerViewProvider).folderOf.containsKey(s.sessionId);
    final action = await showAppSheet<String>(
      context,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheet).height * 0.8),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SheetHeader(title),
                SheetGroup(
                  children: [
                    // Pinning lives in the host's workspace registry.
                    if (workspaces.ready)
                      ListTile(
                        leading: Icon(pinned ? AppIcons.pinActive : AppIcons.pin),
                        title: Text(pinned ? context.l10n.shellUnpin : context.l10n.commonPin),
                        onTap: () => Navigator.pop(sheet, pinned ? 'unpin' : 'pin'),
                      ),
                    ListTile(
                      leading: const Icon(AppIcons.rename),
                      title: Text(context.l10n.commonRename),
                      onTap: () => Navigator.pop(sheet, 'rename'),
                    ),
                    ListTile(
                      leading: const Icon(AppIcons.moveToFolder),
                      title: Text(inFolder ? context.l10n.shellMoveToOtherFolder : context.l10n.shellMoveToFolder),
                      onTap: () => Navigator.pop(sheet, 'folder'),
                    ),
                    ListTile(
                      leading: const Icon(AppIcons.share),
                      title: Text(context.l10n.commonShare),
                      onTap: () => Navigator.pop(sheet, 'share'),
                    ),
                    ListTile(
                      leading: const Icon(AppIcons.multiSelect),
                      title: Text(context.l10n.shellMultiSelect),
                      onTap: () => Navigator.pop(sheet, 'select'),
                    ),
                    ListTile(
                      leading: const Icon(AppIcons.archive),
                      title: Text(context.l10n.shellArchive),
                      subtitle: Text(context.l10n.shellArchiveStopsTurn),
                      onTap: () => Navigator.pop(sheet, 'archive'),
                    ),
                    SessionDeleteTile(
                      ids: [s.sessionId],
                      owner: deletionOwner,
                      onTap: () {
                        if (deletionOwner?.isCurrent(ref) == true) Navigator.pop(sheet, 'delete');
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      ),
    );
    if (!context.mounted || action == null) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    switch (action) {
      case 'pin' || 'unpin':
        try {
          final notifier = ref.read(workspacesProvider.notifier);
          await (action == 'pin' ? notifier.pinSession(s.sessionId) : notifier.unpinSession(s.sessionId));
        } catch (_) {
          messenger?.showSnackBar(
            SnackBar(content: Text(action == 'pin' ? appL10n.shellPinFailed : appL10n.shellUnpinFailed)),
          );
        }
      case 'share':
        await shareConversation(context, s.sessionId);
      case 'folder':
        await moveToFolderFlow(context, ref, [s.sessionId]);
      case 'select':
        ref.read(drawerSelectionProvider.notifier).start(s.sessionId);
      case 'rename':
        final next = await _askTitle(context, s.title?.trim() ?? '');
        if (next == null || next.isEmpty || next == s.title) return;
        try {
          await ref.read(sessionsProvider.notifier).rename(s.sessionId, next);
        } catch (_) {
          messenger?.showSnackBar(SnackBar(content: Text(appL10n.shellRenameFailed)));
        }
      case 'delete':
        if (deletionOwner != null && deletionOwner.isCurrent(ref)) {
          await deleteSessionsFlow(context, ref, [s.sessionId], owner: deletionOwner);
        }
      case 'archive':
        unawaited(
          scheduleArchiveNotice(context, ref, [
            s.sessionId,
          ], s.running ? appL10n.shellChatStoppedArchived(title) : appL10n.shellChatArchived(title)),
        );
    }
  }

  Future<String?> _askTitle(BuildContext context, String initial) {
    final controller = TextEditingController(text: initial);
    return showAppDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(context.l10n.shellRenameChat),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 80,
          decoration: InputDecoration(hintText: context.l10n.shellChatTitle, counterText: ''),
          onSubmitted: (v) => Navigator.pop(dialog, v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog), child: Text(context.l10n.commonCancel)),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, controller.text.trim()),
            child: Text(context.l10n.commonSave),
          ),
        ],
      ),
    ).whenComplete(controller.dispose);
  }
}

/// DS Bot's conversations as one row above the list: the glyph on the 20
/// text line, 「DS Bot」, then a breathing dot while a Bot works and the
/// unread count. Opens the Bot pages.
class DsBotDrawerRow extends ConsumerWidget {
  const DsBotDrawerRow({super.key, required this.running, required this.onTap});

  final bool running;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final unread = ref.watch(dsBotInboxProvider.select((i) => i.total));
    final shape = Squircle.border(AppShape.md);
    return Semantics(
      button: true,
      label: [
        'DS Bot',
        if (running) l10n.shellCurrentlyRunning,
        if (unread > 0) l10n.shellUnreadCount(unread),
      ].join(l10n.shellSemanticsSeparator),
      onTap: onTap,
      excludeSemantics: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          customBorder: shape,
          child: SizedBox(
            height: 44,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                children: [
                  Icon(AppIcons.bot, size: 20, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'DS Bot',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontSize: 15,
                        height: 1.4,
                        color: scheme.onSurface,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  if (running) ...[const SizedBox(width: 10), const StatusDot(tone: StatusTone.busy, size: 7)],
                  if (unread > 0) ...[const SizedBox(width: 10), UnreadBadge(unread)],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Loading: a few quiet placeholder rows on the same grid as the real ones,
/// breathing slowly (still under reduced motion).
class _SkeletonList extends StatefulWidget {
  const _SkeletonList();

  @override
  State<_SkeletonList> createState() => _SkeletonListState();
}

class _SkeletonListState extends State<_SkeletonList> with SingleTickerProviderStateMixin {
  late final AnimationController _breath = AnimationController(vsync: this, duration: AppMotion.breath);
  late final Animation<double> _opacity = _breath.drive(
    Tween(begin: 0.55, end: 1.0).chain(CurveTween(curve: AppMotion.std)),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotion.reduced(context)) {
      _breath
        ..stop()
        ..value = 1;
    } else if (!_breath.isAnimating) {
      _breath.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final fill = scheme.onSurface.withValues(alpha: scheme.brightness == Brightness.dark ? 0.09 : 0.07);
    Widget bar(double width, double height) => Container(
      width: width,
      height: height,
      decoration: ShapeDecoration(color: fill, shape: const StadiumBorder()),
    );
    const widths = [0.72, 0.5, 0.64, 0.42, 0.58];
    return Semantics(
      label: l10n.shellLoadingChats,
      child: FadeTransition(
        opacity: _opacity,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final row = constraints.maxWidth - 40;
            return ListView(
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
              children: [
                Padding(padding: const EdgeInsets.only(top: 19, bottom: 9), child: bar(28, 8)),
                for (final w in widths)
                  SizedBox(
                    height: 44,
                    child: Align(alignment: Alignment.centerLeft, child: bar(row * w, 10)),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Keeps an empty view in the upper third of the list area.
class _Centered extends StatelessWidget {
  const _Centered({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Align(
            alignment: const Alignment(0, -0.4),
            child: Padding(padding: const EdgeInsets.symmetric(vertical: 24), child: child),
          ),
        ),
      ),
    );
  }
}

/// The selected workspace has no conversations yet.
class _WorkspaceEmptyState extends ConsumerWidget {
  const _WorkspaceEmptyState();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    return _Centered(
      child: EmptyView(
        compact: true,
        icon: AppIcons.folderOpen,
        title: l10n.shellWorkspaceNoChats,
        message: l10n.shellWorkspaceNewChatsHint,
        actionLabel: l10n.remoteWorkspaceAllChats,
        onAction: () => ref.read(workspacePrefsProvider.notifier).select(null),
      ),
    );
  }
}

/// No sessions: either the engine (or remote host) isn't up yet, or there
/// simply are none.
class _EmptyState extends ConsumerWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final host = ref.watch(activeHostProvider);
    if (!host.isLocal) return _RemoteEmptyState(host: host);
    final status = ref.watch(localRuntimeProvider.select((s) => s.status));
    if (EngineFailureCard.visibleFor(status)) {
      return const SingleChildScrollView(padding: EdgeInsets.fromLTRB(10, 8, 10, 16), child: EngineFailureCard());
    }
    final view = switch (status.phase) {
      RuntimePhase.running => EmptyView(
        compact: true,
        icon: AppIcons.chat,
        title: l10n.shellNoChatsYet,
        message: l10n.shellNewChatsHint,
      ),
      RuntimePhase.starting => EmptyView(
        compact: true,
        icon: AppIcons.loading,
        title: l10n.shellEngineStarting,
        message: l10n.shellChatsAfterStarting,
      ),
      RuntimePhase.installed || RuntimePhase.error => EmptyView(
        compact: true,
        icon: AppIcons.power,
        title: l10n.shellEngineNotRunning,
        message: l10n.shellChatsAfterStarting,
        actionLabel: l10n.shellStartEngine,
        onAction: () => unawaited(EngineControl.ensureStarted(ProviderScope.containerOf(context))),
      ),
      RuntimePhase.notInstalled when status.runtimeMissing => EmptyView(
        compact: true,
        icon: AppIcons.thisPhone,
        title: l10n.localEnvNotInstalled,
        actionLabel: l10n.phoneEngineInstallRuntime,
        onAction: () => unawaited(openLocalInstall(context)),
      ),
      _ => EmptyView(
        compact: true,
        icon: AppIcons.power,
        title: l10n.shellEngineNotRunning,
        message: l10n.shellEngineStatusHint,
      ),
    };
    return _Centered(child: view);
  }
}

/// Empty list on a remote host: connecting, failed (with the reason and a
/// retry), or connected with no conversations yet.
class _RemoteEmptyState extends ConsumerWidget {
  const _RemoteEmptyState({required this.host});

  final HostRef host;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final name = ref.watch(hostNameProvider(host)) ?? l10n.commonRemoteHost;
    final status = ref.watch(hostLinkStatusProvider(host)).value ?? HostLinkStatus.idle;
    void retry() => ref.read(remoteConnectionProvider(host).notifier).retry();
    final view = switch (status.phase) {
      HostLinkPhase.connected => EmptyView(
        compact: true,
        icon: AppIcons.chat,
        title: l10n.shellNoChatsYet,
        message: l10n.shellNewChatsHint,
      ),
      HostLinkPhase.failed => EmptyView(
        compact: true,
        icon: AppIcons.disconnected,
        title: l10n.shellHostUnreachable(name),
        message: status.error?.message ?? l10n.commonConnectionFailed,
        actionLabel: status.error?.retryable ?? true ? l10n.commonRetry : null,
        onAction: retry,
      ),
      HostLinkPhase.reconnecting => EmptyView(
        compact: true,
        icon: AppIcons.reconnecting,
        title: l10n.shellHostReconnecting(name),
        message: status.error?.message,
        actionLabel: l10n.shellRetryNow,
        onAction: retry,
      ),
      _ => EmptyView(
        compact: true,
        icon: AppIcons.reconnecting,
        title: l10n.shellHostConnecting(name),
        message: status.step == null ? l10n.shellHostChatsAfterConnecting : '${status.step!.label}…',
      ),
    };
    return _Centered(child: view);
  }
}
