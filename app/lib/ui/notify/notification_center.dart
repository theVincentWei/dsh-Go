/// 通知中心：小程序通知按 app 分组、时间倒序；未读加粗 + 圆点，点击跳转，
/// 划掉置 dismissed（条目仍在，契约 §4.3），「全部已读」。
///
/// 入口：会话列表顶部「服务通知」+ 小程序桌面 AppHub 组角标（契约 §6.1）。
/// 小程序通知**不进会话流**（契约 §6.2）——这里只收 `source=miniapp`。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../notify/apphub_notices.dart' show AppHubNoticeService;
import '../../notify/apphub_proxy.dart' show appHubProxyBase;
import '../../state/apphub_notices_state.dart';
import '../applet/dimina/dimina_host.dart';
import '../bots/bots_page.dart' show UnreadBadge;
import '../common/app_sheet.dart' show groupTitleStyle;
import '../common/empty_view.dart';
import '../common/list_page_row.dart' show ListPageCard, ListPageRow;
import '../shell/page_frame.dart' show AppPage, GlassIconButton;
import '../theme/app_icons.dart';
import '../theme/theme.dart';

/// 点一条小程序通知：先回写已读，有 [MiniAppNotice.page] 就打开小程序页，
/// 打开失败（或没有 page）落到通知中心（契约 §5.3 点击跳转兜底）。
Future<void> openMiniAppNotice(BuildContext context, WidgetRef ref, MiniAppNotice notice) async {
  final AppHubNoticesController notices = ref.read(appHubNoticesProvider.notifier);
  notices.dismissBanner(notice);
  // 点击后回写已读是客户端职责（契约 §9.3）：不等它，也不让失败挡住跳转。
  unawaited(notices.markRead(<int>[notice.id]));
  if (notice.page case final String page when page.isNotEmpty) {
    if (await _openMiniAppPage(ref, notice)) return;
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(context.l10n.notifyCenterOpenFailed)),
      );
    }
  }
  if (!context.mounted) return;
  await Navigator.of(context, rootNavigator: true).push(NotificationCenterPage.route());
}

/// 原生系统通知被点：`kind == 'miniapp'` 的通知里 `eventId` 放的是通知 id
/// （见 `notify/apphub_notices.dart` 的 [_postFor]），`sessionId` 是 appId。
Future<void> openMiniAppNoticeTap(BuildContext context, WidgetRef ref, {required String appId, String? notifyId}) async {
  final int? id = int.tryParse(notifyId ?? '');
  final MiniAppNotice? known = id == null ? null : await ref.read(appHubNoticesProvider.notifier).resolve(id);
  if (!context.mounted) return;
  if (known != null) return openMiniAppNotice(context, ref, known);
  debugPrint('[apphub-notice] tap for unknown notice app=$appId id=$notifyId: opening the center');
  // 认不出是哪一条（别的进程推的旧通知、或 id 丢了）：落到通知中心。
  await Navigator.of(context, rootNavigator: true).push(NotificationCenterPage.route());
}

Future<bool> _openMiniAppPage(WidgetRef ref, MiniAppNotice notice) async {
  try {
    final Map<String, String> names = await ref.read(appHubAppNamesProvider.future);
    return await DiminaHost.open(
      appId: notice.appId,
      name: names[notice.appId] ?? notice.appId,
      path: notice.page,
      // 固定端口反代（与桌面/市场同款）：未装 = 首装，已装 = 后台拉新包。
      updateManifestUrl: '$appHubProxyBase/apps/${notice.appId}/manifest.json',
    );
  } catch (_) {
    return false;
  }
}

class NotificationCenterPage extends ConsumerStatefulWidget {
  const NotificationCenterPage({super.key});

  static Route<void> route() => MaterialPageRoute<void>(builder: (_) => const NotificationCenterPage());

  @override
  ConsumerState<NotificationCenterPage> createState() => _NotificationCenterPageState();
}

class _NotificationCenterPageState extends ConsumerState<NotificationCenterPage> {
  /// 折叠的 appId（会话内状态，不落盘）。
  final Set<String> _collapsed = <String>{};

  @override
  void initState() {
    super.initState();
    // 拉一次全量历史：进程被杀期间的通知不补发，但服务端保留记录（契约 §9.6）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(ref.read(appHubNoticesProvider.notifier).refresh());
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final AppHubNotices state = ref.watch(appHubNoticesProvider);
    final Map<String, String> names =
        ref.watch(appHubAppNamesProvider).value ?? const <String, String>{};
    // 按 app 分组：组序 = 该组最新一条的时间序（notices 已时间倒序）。
    final List<String> appOrder = <String>[];
    final Map<String, List<MiniAppNotice>> byApp = <String, List<MiniAppNotice>>{};
    for (final MiniAppNotice notice in state.notices) {
      if (!byApp.containsKey(notice.appId)) {
        appOrder.add(notice.appId);
        byApp[notice.appId] = <MiniAppNotice>[];
      }
      byApp[notice.appId]!.add(notice);
    }
    return AppPage(
      title: l10n.notifyCenterTitle,
      subtitle: state.unread > 0 ? Text(l10n.notifyCenterUnread(state.unread)) : null,
      actions: <Widget>[
        GlassIconButton(
          icon: AppIcons.refresh,
          tooltip: l10n.commonRetry,
          onPressed: () => unawaited(ref.read(appHubNoticesProvider.notifier).refresh()),
        ),
        if (state.unread > 0)
          GlassIconButton(
            icon: AppIcons.done,
            tooltip: l10n.notifyCenterMarkAll,
            onPressed: () => unawaited(ref.read(appHubNoticesProvider.notifier).markAllRead()),
          ),
      ],
      slivers: <Widget>[
        SliverList.list(
          children: <Widget>[
            if (state.failed)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 8),
                child: Text(
                  l10n.notifyCenterLoadFailed,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: DshColors.of(context).textTertiary,
                  ),
                ),
              ),
            if (state.notices.isEmpty)
              Padding(
                padding: EdgeInsets.only(top: MediaQuery.sizeOf(context).height * 0.16),
                child: EmptyView(
                  compact: true,
                  icon: AppIcons.notifications,
                  title: l10n.notifyCenterEmpty,
                ),
              )
            else
              for (final String appId in appOrder)
                _group(context, ref, appId, names[appId] ?? appId, byApp[appId]!),
            const SizedBox(height: 24),
          ],
        ),
      ],
    );
  }

  Widget _group(
    BuildContext context,
    WidgetRef ref,
    String appId,
    String name,
    List<MiniAppNotice> notices,
  ) {
    final l10n = context.l10n;
    final bool collapsed = _collapsed.contains(appId);
    final int unread = notices.where((n) => n.unread).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Semantics(
          header: true,
          button: true,
          label: '$name${unread > 0 ? '，${l10n.notifyCenterUnread(unread)}' : ''}',
          onTap: () => _toggle(appId),
          excludeSemantics: true,
          child: InkWell(
            onTap: () => _toggle(appId),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 16, 8),
              child: Row(
                children: <Widget>[
                  Flexible(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: groupTitleStyle(context),
                    ),
                  ),
                  if (unread > 0) ...<Widget>[
                    const SizedBox(width: 8),
                    UnreadBadge(unread),
                  ],
                  const Spacer(),
                  Icon(
                    collapsed ? AppIcons.disclosure : AppIcons.expand,
                    size: 18,
                    color: DshColors.of(context).textTertiary,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (!collapsed)
          ListPageCard(
            children: <Widget>[
              for (final MiniAppNotice notice in notices) _row(context, ref, notice),
            ],
          ),
        if (collapsed)
          ListPageCard(
            children: <Widget>[
              ListPageRow(
                title: l10n.notifyCenterGroupCount(notices.length),
                meta: unread > 0 ? l10n.notifyCenterUnread(unread) : null,
                onTap: () => _toggle(appId),
              ),
            ],
          ),
      ],
    );
  }

  /// 在通知中心里点一条：有 page 才跳小程序页；没有就只是读掉（不再往栈上
  /// 叠一个通知中心）。
  Future<void> _openRow(BuildContext context, WidgetRef ref, MiniAppNotice notice) async {
    final AppHubNoticesController notices = ref.read(appHubNoticesProvider.notifier);
    notices.dismissBanner(notice);
    if (notice.page case final String page when page.isNotEmpty) {
      await openMiniAppNotice(context, ref, notice);
      return;
    }
    await notices.markRead(<int>[notice.id]);
  }

  void _toggle(String appId) {
    setState(() {
      if (!_collapsed.add(appId)) _collapsed.remove(appId);
    });
  }

  Widget _row(BuildContext context, WidgetRef ref, MiniAppNotice notice) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final row = ListPageRow(
      key: ValueKey<String>('notice-${notice.id}'),
      // 未读：圆点 + 加粗标题；已读/已划掉：常规字重、无点。
      leading: notice.unread
          ? Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
            )
          : Icon(AppIcons.notifications, size: 20, color: colors.textTertiary),
      title: notice.title,
      titleStyle: theme.textTheme.bodyLarge?.copyWith(
        fontSize: 15,
        height: 1.4,
        fontWeight: notice.unread ? FontWeight.w600 : FontWeight.w400,
        color: notice.dismissed ? colors.textTertiary : scheme.onSurface,
      ),
      subtitle: notice.body.isEmpty ? null : notice.body,
      subtitleMaxLines: 2,
      meta: _timeText(context, notice.ts),
      chevron: notice.page != null,
      onTap: () => unawaited(_openRow(context, ref, notice)),
    );
    if (notice.dismissed) return Opacity(opacity: 0.7, child: row);
    return Dismissible(
      key: ValueKey<String>('dismiss-${notice.id}'),
      direction: DismissDirection.endToStart,
      background: ColoredBox(
        color: scheme.errorContainer,
        child: Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.only(right: 24),
            child: Icon(AppIcons.clear, size: 20, color: scheme.onErrorContainer),
          ),
        ),
      ),
      // 划掉 = dismissed：不删条目（通知中心仍可见，契约 §4.3），并且要把
      // 系统通知撤掉；所以这里只做标记，让行弹回。
      confirmDismiss: (_) async {
        AppHubNoticeService.cancel(notice);
        await ref.read(appHubNoticesProvider.notifier).dismiss(notice);
        return false;
      },
      child: row,
    );
  }

  /// 今天的只给 HH:mm，更早给 M-D（与列表页同一观感）。
  String _timeText(BuildContext context, DateTime? at) {
    if (at == null) return '';
    final DateTime now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    if (at.year == now.year && at.month == now.month && at.day == now.day) {
      return '${two(at.hour)}:${two(at.minute)}';
    }
    final String md = '${at.month}-${at.day}';
    return at.year == now.year ? md : '${at.year}-$md';
  }
}
