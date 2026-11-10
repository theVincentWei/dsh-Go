/// 小程序通知的宿主件（挂在首页 shell，画根 Overlay 里的一张玻璃 Banner，
/// 本身不画东西）：把轮询服务绑到 ProviderScope、前台弹 Banner、回后台时把
/// 还挂着的 Banner 换成系统通知。
///
/// 与聊天的 [ChatAlertHost] 共用同一层根 Overlay，但不混流：聊天通知不进
/// 通知中心、小程序通知不进会话流（契约 §6.2）。生命周期/前台判定复用
/// `appForegroundProvider`（由 ChatAlertHost 维护），这里不另写监听。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/apphub_notices_state.dart';
import '../../notify/apphub_notices.dart' show AppHubNoticeService;
import '../../state/notify_state.dart'
    show appForegroundProvider, notifyChannelProvider, notifySystemStatusProvider;
import '../common/discard_guard.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'notification_center.dart' show openMiniAppNotice;

class AppHubNoticeHost extends ConsumerStatefulWidget {
  const AppHubNoticeHost({super.key});

  @override
  ConsumerState<AppHubNoticeHost> createState() => _AppHubNoticeHostState();
}

class _AppHubNoticeHostState extends ConsumerState<AppHubNoticeHost> {
  OverlayEntry? _entry;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _entry = OverlayEntry(builder: (_) => const AppHubNoticeBannerLayer());
      Overlay.of(context, rootOverlay: true).insert(_entry!);
    });
  }

  @override
  void dispose() {
    _entry?.remove();
    _entry?.dispose();
    _entry = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 离开 app 时 Banner 还没消掉：换成系统通知（与聊天 Banner 同一规则）。
    ref.listen(appForegroundProvider, (bool? was, bool foreground) {
      if (foreground || was != true) return;
      final MiniAppNotice? banner = ref.read(appHubNoticesProvider).banner;
      if (banner == null) return;
      ref.read(appHubNoticesProvider.notifier).dismissBanner(banner);
      unawaited(ref.read(notifyChannelProvider).tryShow(AppHubNoticeService.postFor(banner)));
    });
    // 没有原生通知模块（widget test / desktop）就不轮询：与 ChatAlertHost
    // 的「native 才启动」同一规则，测试里也不该产生网络尝试。
    final bool native =
        ref.watch(notifySystemStatusProvider.select((status) => status.value?.native ?? false));
    if (native) AppHubNoticeService.bind(ProviderScope.containerOf(context, listen: false));
    return const SizedBox.shrink();
  }
}

/// Banner 槽位：从屏幕顶滑入，点开通知中心/小程序页，上滑或几秒后收起。
class AppHubNoticeBannerLayer extends ConsumerStatefulWidget {
  const AppHubNoticeBannerLayer({super.key});

  @override
  ConsumerState<AppHubNoticeBannerLayer> createState() => _AppHubNoticeBannerLayerState();
}

class _AppHubNoticeBannerLayerState extends ConsumerState<AppHubNoticeBannerLayer> {
  Timer? _timer;
  bool _accessibleNavigation = false;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _arm(MiniAppNotice? notice) {
    _timer?.cancel();
    if (notice == null) return;
    _timer = Timer(
      _accessibleNavigation ? const Duration(seconds: 12) : const Duration(seconds: 4),
      () => ref.read(appHubNoticesProvider.notifier).dismissBanner(notice),
    );
  }

  Future<void> _open(MiniAppNotice notice) async {
    if (!await DiscardGuard.confirmLeave(context) || !mounted) return;
    HapticFeedback.selectionClick();
    ref.read(appHubNoticesProvider.notifier).dismissBanner(notice);
    Navigator.of(context, rootNavigator: true).popUntil((route) => route.isFirst);
    await openMiniAppNotice(context, ref, notice);
  }

  @override
  Widget build(BuildContext context) {
    final accessible = MediaQuery.accessibleNavigationOf(context);
    if (accessible != _accessibleNavigation) {
      _accessibleNavigation = accessible;
      _arm(ref.read(appHubNoticesProvider).banner);
    }
    ref.listen(appHubNoticesProvider, (_, next) => _arm(next.banner));
    final MiniAppNotice? notice = ref.watch(appHubNoticesProvider.select((s) => s.banner));
    final top = MediaQuery.viewPaddingOf(context).top + AppSpace.sm;
    final duration = AppMotion.of(context, AppMotion.emphasized);
    return Positioned(
      top: top,
      left: AppSpace.md,
      right: AppSpace.md,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: AnimatedSwitcher(
            duration: duration,
            reverseDuration: AppMotion.of(context, AppMotion.standard),
            switchInCurve: AppMotion.enter,
            switchOutCurve: AppMotion.exit,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween(begin: const Offset(0, -0.6), end: Offset.zero).animate(animation),
                child: child,
              ),
            ),
            child: notice == null
                ? const SizedBox(key: ValueKey('none'), width: double.infinity)
                : _Swipeable(
                    key: ObjectKey(notice),
                    onDismiss: () => ref.read(appHubNoticesProvider.notifier).dismissBanner(notice),
                    child: _NoticeBanner(notice: notice, onTap: () => unawaited(_open(notice))),
                  ),
          ),
        ),
      ),
    );
  }
}

class _NoticeBanner extends ConsumerWidget {
  const _NoticeBanner({required this.notice, required this.onTap});

  final MiniAppNotice notice;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final surfaces = DshSurfaces.of(context);
    final appName = ref.watch(appHubAppNamesProvider).value?[notice.appId] ?? notice.appId;
    return Semantics(
      container: true,
      liveRegion: true,
      button: true,
      onTap: onTap,
      label: '$appName，${notice.title}，${notice.body}',
      excludeSemantics: true,
      child: GlassSurface(
        tier: GlassTier.chrome,
        style: surfaces.chrome.copyWith(fill: surfaces.chrome.fallbackFill),
        borderRadius: AppShape.radiusLg,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              DecoratedBox(
                decoration: ShapeDecoration(color: colors.infoContainer, shape: const CircleBorder()),
                child: SizedBox.square(
                  dimension: 32,
                  child: Icon(AppIcons.notifications, size: 18, color: colors.onInfoContainer),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            notice.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(fontSize: 15, height: 1.35),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          appName,
                          maxLines: 1,
                          style: theme.textTheme.labelSmall?.copyWith(color: colors.textTertiary),
                        ),
                      ],
                    ),
                    if (notice.body.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 2),
                      Text(
                        notice.body,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          height: 1.45,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 上滑收起：跟手位移，过阈值或快速上滑即 dismissed。
class _Swipeable extends StatefulWidget {
  const _Swipeable({super.key, required this.child, required this.onDismiss});

  final Widget child;
  final VoidCallback onDismiss;

  @override
  State<_Swipeable> createState() => _SwipeableState();
}

class _SwipeableState extends State<_Swipeable> {
  double _dy = 0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onVerticalDragUpdate: (d) => setState(() => _dy = (_dy + d.delta.dy).clamp(-200.0, 12.0)),
      onVerticalDragEnd: (d) {
        if (_dy < -28 || (d.primaryVelocity ?? 0) < -400) {
          widget.onDismiss();
        } else {
          setState(() => _dy = 0);
        }
      },
      child: Transform.translate(offset: Offset(0, _dy), child: widget.child),
    );
  }
}
