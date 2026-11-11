/// 小程序通知的宿主件（挂在首页 shell，画根 Overlay 里的一张玻璃 Banner，
/// 本身不画东西）：把轮询服务绑到 ProviderScope、前台弹 Banner、回后台时把
/// 还挂着的 Banner 换成系统通知。2026-11-11 拍板：星河容器 Header 不再放
/// 通知铃铛（原 §6.3 的 setNotifyEntry/pushNotifyUnread/openNotificationCenter
/// 接线已拆），通知中心入口改在宿主自己的页面头（会话列表 + 小程序桌面）。
///
/// 与聊天的 [ChatAlertHost] 共用同一层根 Overlay，但不混流：聊天通知不进
/// 通知中心、小程序通知不进会话流（契约 §6.2）。生命周期/前台判定复用
/// `appForegroundProvider`（由 ChatAlertHost 维护），这里不另写监听。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../notify/apphub_notices.dart' show AppHubNoticeService;
import '../../notify/notify_channel.dart' show NotifyPost;
import '../../state/apphub_notices_state.dart';
import '../../state/hosts_state.dart' show HostRef;
import '../../state/notify_state.dart'
    show appForegroundProvider, notifyChannelProvider, notifySystemStatusProvider;
import '../common/discard_guard.dart';
import '../applet/hub_icon_cache.dart' show HubBundleIcon;
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import '../applet/dimina/dimina_host.dart' show DiminaHost, DiminaUpdateEvent;
import 'notification_center.dart' show openMiniAppNotice;

class AppHubNoticeHost extends ConsumerStatefulWidget {
  const AppHubNoticeHost({super.key});

  @override
  ConsumerState<AppHubNoticeHost> createState() => _AppHubNoticeHostState();
}

class _AppHubNoticeHostState extends ConsumerState<AppHubNoticeHost> {
  OverlayEntry? _entry;
  StreamSubscription<DiminaUpdateEvent>? _updates;

  /// 已告知过的「升级完成」版本：同一个 app 的同一版本只说一次。
  static final Map<String, int> _appliedVersions = <String, int>{};

  @override
  void initState() {
    super.initState();
    // Bundle 静默升级完成 → 一条瞬态告知（契约 §6.4；不进未读收件箱）。
    _updates = DiminaHost.updateEvents.listen((event) => unawaited(_onUpdateEvent(event)));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _entry = OverlayEntry(builder: (_) => const AppHubNoticeBannerLayer());
      Overlay.of(context, rootOverlay: true).insert(_entry!);
    });
  }

  @override
  void dispose() {
    unawaited(_updates?.cancel());
    _entry?.remove();
    _entry?.dispose();
    _entry = null;
    super.dispose();
  }

  /// 容器升级完成事件（契约 §6.4 修订，2026-11-12：升级告知也进收件箱）：
  /// 先 POST 服务端落一条宿主告知，落上了就立刻拉一轮——通知经由既有管线
  /// 投递（前台正式 Banner / 后台系统通知，未读角标、已读流转全部同正式
  /// 通知）。服务端没落上（不可达/拒绝）回落瞬态告知：前台玻璃 Banner 数秒
  /// 即收、后台 kind=`update` 系统通知，不写收件箱。
  Future<void> _onUpdateEvent(DiminaUpdateEvent event) async {
    if (event.event != 'applied') return;
    final int version = event.versionCode ?? 0;
    if (_appliedVersions[event.appId] == version) return;
    _appliedVersions[event.appId] = version;
    final ProviderContainer container = ProviderScope.containerOf(context, listen: false);
    String appName = event.appId;
    final Map<String, String>? cached = container.read(appHubAppNamesProvider).value;
    if (cached != null) {
      appName = cached[event.appId] ?? appName;
    } else {
      try {
        final Map<String, String> names = await container
            .read(appHubAppNamesProvider.future)
            .timeout(const Duration(seconds: 3));
        appName = names[event.appId] ?? appName;
      } catch (_) {
        // 市场目录不可达：用 appId 顶上，告知照发。
      }
    }
    if (!mounted) return;
    final String versionText = event.versionName.trim().isNotEmpty
        ? event.versionName.trim()
        : (version > 0 ? '$version' : '');
    final String message = versionText.isEmpty
        ? appL10n.notifyUpdateAppliedPlain(appName)
        : appL10n.notifyUpdateApplied(appName, versionText);
    final bool reported = await AppHubNoticeService.reportUpgrade(
      appId: event.appId,
      title: appName,
      body: message,
      dedupeKey: 'upgrade-${version > 0 ? version : (versionText.isEmpty ? 'latest' : versionText)}',
    );
    if (reported) {
      unawaited(AppHubNoticeService.pollNow());
      return;
    }
    final MiniAppNotice notice = MiniAppNotice(
      id: -1,
      appId: event.appId,
      title: appName,
      body: message,
    );
    if (container.read(appForegroundProvider)) {
      container.read(appHubTransientNoticeProvider.notifier).show(notice);
      return;
    }
    unawaited(
      container.read(notifyChannelProvider).tryShow(
        NotifyPost(
          group: 'apphub|${event.appId}',
          key: 'update-${event.appId}-${versionText.isEmpty ? 'latest' : versionText}',
          attention: false,
          title: appName,
          text: message,
          publicText: appL10n.notifyUpdatePublicText,
          sessionId: event.appId,
          host: HostRef.local,
          kind: 'update',
          source: 'miniapp',
        ),
      ),
    );
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
    if (native) {
      AppHubNoticeService.bind(ProviderScope.containerOf(context, listen: false));
    }
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

  /// 当前要显示的 Banner：正式收件箱 Banner 优先，其次瞬态告知。
  MiniAppNotice? get _shown =>
      ref.read(appHubNoticesProvider).banner ?? ref.read(appHubTransientNoticeProvider);

  /// 重新计时。当前显示的这条到点后：收件箱 Banner 收起，瞬态告知清掉。
  void _arm() {
    _timer?.cancel();
    final MiniAppNotice? active = _shown;
    if (active == null) return;
    _timer = Timer(
      _accessibleNavigation ? const Duration(seconds: 12) : const Duration(seconds: 4),
      () {
        if (ref.read(appHubNoticesProvider).banner?.id == active.id) {
          ref.read(appHubNoticesProvider.notifier).dismissBanner(active);
        }
        if (ref.read(appHubTransientNoticeProvider)?.id == active.id) {
          ref.read(appHubTransientNoticeProvider.notifier).clear();
        }
      },
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
      _arm();
    }
    ref.listen(appHubNoticesProvider, (_, _) => _arm());
    ref.listen(appHubTransientNoticeProvider, (_, _) => _arm());
    final MiniAppNotice? banner = ref.watch(appHubNoticesProvider.select((s) => s.banner));
    final MiniAppNotice? transient = ref.watch(appHubTransientNoticeProvider);
    final MiniAppNotice? notice = banner ?? transient;
    final bool isTransient = banner == null && transient != null;
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
                    onDismiss: isTransient
                        ? () => ref.read(appHubTransientNoticeProvider.notifier).clear()
                        : () => ref.read(appHubNoticesProvider.notifier).dismissBanner(notice),
                    child: isTransient
                        ? _TransientBanner(
                            notice: notice,
                            onTap: () => ref.read(appHubTransientNoticeProvider.notifier).clear(),
                          )
                        : _NoticeBanner(notice: notice, onTap: () => unawaited(_open(notice))),
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
    final String? iconUrl = ref.watch(appHubAppMetaProvider).value?[notice.appId]?.iconUrl;
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
              // 左侧 = 该小程序的应用图标（§6.4 修订）；没带图回落铃铛圆。
              HubBundleIcon(
                appId: notice.appId,
                url: iconUrl,
                size: 32,
                fallback: DecoratedBox(
                  decoration:
                      ShapeDecoration(color: colors.infoContainer, shape: const CircleBorder()),
                  child: SizedBox.square(
                    dimension: 32,
                    child: Icon(AppIcons.notifications, size: 18, color: colors.onInfoContainer),
                  ),
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
                        // 升级告知的 title 就是应用名，别再缀一遍。
                        if (appName != notice.title) ...<Widget>[
                          const SizedBox(width: 6),
                          Text(
                            appName,
                            maxLines: 1,
                            style: theme.textTheme.labelSmall?.copyWith(color: colors.textTertiary),
                          ),
                        ],
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

/// 瞬态告知（升级完成，服务端没落上时的回落）：一行告知，点一下即收（不跳任何页面）。
class _TransientBanner extends ConsumerWidget {
  const _TransientBanner({required this.notice, required this.onTap});

  final MiniAppNotice notice;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final surfaces = DshSurfaces.of(context);
    final String? iconUrl = ref.watch(appHubAppMetaProvider).value?[notice.appId]?.iconUrl;
    return Semantics(
      container: true,
      liveRegion: true,
      button: true,
      onTap: onTap,
      label: notice.body,
      excludeSemantics: true,
      child: GlassSurface(
        tier: GlassTier.chrome,
        style: surfaces.chrome.copyWith(fill: surfaces.chrome.fallbackFill),
        borderRadius: AppShape.radiusLg,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: <Widget>[
              // 与正式 Banner 同款：应用图标优先，没带图回落绿色刷新圆。
              HubBundleIcon(
                appId: notice.appId,
                url: iconUrl,
                size: 32,
                fallback: DecoratedBox(
                  decoration:
                      ShapeDecoration(color: colors.successContainer, shape: const CircleBorder()),
                  child: SizedBox.square(
                    dimension: 32,
                    child: Icon(AppIcons.refresh, size: 18, color: colors.onSuccessContainer),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  notice.body,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurface),
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
