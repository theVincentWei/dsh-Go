// Portions derived from PiPilot (https://github.com/CikeSeven/pi_pilot), MIT, Copyright (c) 2026 CikeSeven. See THIRD_PARTY_NOTICES.md.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/l10n.dart';
import '../../links/app_links.dart';
import '../../pets/overlay_channel.dart' show petOverlayChannelProvider;
import '../../pets/pet_overlay_bridge.dart';
import '../../state/connection_state.dart';
import '../../state/hosts_state.dart';
import '../../state/drawer_view_state.dart' show drawerSelectionProvider;
import '../../state/quick_panel_state.dart';
import '../../state/sessions_state.dart' show currentSessionProvider;
import '../bots/bot_alerts.dart';
import '../chat/chat_screen.dart';
import '../common/status_dot.dart' show StatusTone;
import '../engine/engine_screen.dart';
import '../features/all_features_page.dart';
import '../forum/forum_link_host.dart';
import '../notify/background_net_host.dart';
import '../notify/chat_alert_host.dart';
import '../notify/voice_model_host.dart';
import '../pets/pet_settings_page.dart';
import '../phone/phone_stop_watcher.dart';
import '../plugins/plugins_screen.dart';
import '../remote/host_status.dart' show watchHostStatus, hostKindTint;
import '../remote/host_switcher.dart' show showHostSheet;
import '../remote/network_details_sheet.dart' show showRemoteNetworkDetails;
import '../remote/remote_screen.dart';
import '../safe_mode/safe_mode_notice_listener.dart';
import '../settings/search/settings_search_page.dart';
import '../settings/settings_screen.dart';
import '../share_code/share_code_host.dart';
import '../star/star_prompt_host.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import '../update/update_launch_check.dart';
import '../wallpaper/wallpaper_backdrop.dart';
import '../web/local_web_screen.dart';
import 'drawer_drag.dart' show QuickPanelDragRecognizer;
import 'quick_panel.dart';
import 'session_list_page.dart';
import 'system_entry_host.dart';

/// Home: three tabs — 聊天 (the conversation list), 小程序 (全部功能) and
/// 设置 — over the wallpaper. A conversation opens as a full-screen page
/// over the tabs; back returns to the list.
///
/// A left swipe pulls [QuickPanel] over from the right, on every tab, the
/// same way it used to ride over the chat.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key, this.chatBuilder, this.sessionListBuilder});

  /// Replaces the chat page opened for a conversation (widget tests use a
  /// stand-in).
  @visibleForTesting
  final Widget? chatBuilder;

  /// Replaces the 聊天 tab's list (widget tests use a stand-in).
  @visibleForTesting
  final Widget? sessionListBuilder;

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> with TickerProviderStateMixin {
  /// The selected tab: 0 聊天, 1 小程序, 2 设置. Kept across restarts.
  static const _tabKey = 'home.tab';

  int _tab = 0;

  /// 高亮胶囊流出来的那个 tab(切换动画的起点,见 [_TabGlow])。
  int _tabFrom = 0;

  /// 液态玻璃底栏:高亮胶囊从旧 tab 流到新 tab 的一段动画(0 → 1)。
  late final AnimationController _tabFlow = AnimationController(vsync: this, duration: AppMotion.emphasized);

  /// 三个 tab 的页面翻页控制器:切换时页面横向滑动(与「计划与目标」的
  /// TabBarView 同一套位移动画);翻页只由底栏驱动,手势不抢快捷面板。
  late final PageController _tabPages = PageController();

  /// 顶层双击返回退出的窗口与上一次按下的时刻。
  static const _backExitWindow = Duration(seconds: 2);
  DateTime? _lastBackAt;

  /// Whether the conversation page currently covers the tabs.
  bool _chatOpen = false;

  late final AnimationController _quickPanel = AnimationController(vsync: this, duration: AppMotion.emphasized);

  /// The same for [_quickPanel].
  bool _quickPanelOpen = false;

  /// 「宠物设置」 from the floating pet's menu (every tap, not deduplicated).
  StreamSubscription<void>? _petSettings;

  @override
  void initState() {
    super.initState();
    _quickPanel.addListener(() {
      final open = _quickPanel.value > 0;
      if (open != _quickPanelOpen) setState(() => _quickPanelOpen = open);
    });
    _restoreTab();
    _petSettings = ref.read(petOverlayChannelProvider).settingsRequests.listen((_) {
      if (mounted) unawaited(PetSettingsPage.open(context));
    });
  }

  /// Restores the last tab once, at startup, from the warmed prefs. Fails
  /// quietly (tests without the platform channel, channel hiccups): the tab
  /// stays 聊天.
  Future<void> _restoreTab() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final tab = prefs.getInt(_tabKey) ?? 0;
      if (mounted && tab >= 0 && tab <= 2 && tab != _tab) {
        setState(() => _tab = tab);
        // 启动恢复直接落位,不播切换动画;控制器随首帧挂上,等一帧再跳。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _tabPages.hasClients) _tabPages.jumpToPage(tab);
        });
      }
    } catch (_) {
      // Startup continues on the first tab.
    }
  }

  Future<void> _selectTab(int tab) async {
    if (tab != _tab) {
      setState(() {
        _tabFrom = _tab;
        _tab = tab;
      });
      // 高亮从旧 tab 流到新 tab;页面跟着滑过去。「移除动画」时两个时长都
      // 归零,胶囊与页面直接落位。
      _tabPages.animateToPage(tab, duration: AppMotion.of(context, AppMotion.emphasized), curve: AppMotion.glide);
      _tabFlow
        ..duration = AppMotion.of(context, AppMotion.emphasized)
        ..forward(from: 0);
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_tabKey, tab);
    } catch (_) {
      // The tab still switches; persistence is best-effort.
    }
  }

  @override
  void dispose() {
    unawaited(_petSettings?.cancel());
    _quickPanel.dispose();
    _tabFlow.dispose();
    _tabPages.dispose();
    super.dispose();
  }

  /// [QuickPanel.width] (or the conversation's), plus what it covers on a
  /// phone on its side.
  double _quickPanelWidth(BuildContext context) => math.min(
    (ref.read(currentSessionProvider) == null ? QuickPanel.width : QuickPanel.conversationWidth) +
        MediaQuery.paddingOf(context).right,
    MediaQuery.sizeOf(context).width - 56,
  );

  void _slideOpen() {
    FocusManager.instance.primaryFocus?.unfocus();
    _quickPanel.animateTo(1, curve: AppMotion.glide, duration: AppMotion.of(context, AppMotion.emphasized));
  }

  void _slideClosed() {
    FocusManager.instance.primaryFocus?.unfocus();
    _quickPanel.animateBack(0, curve: AppMotion.glide, duration: AppMotion.of(context, AppMotion.standard));
  }

  void _onQuickPanelDragStart() {
    _quickPanel.stop();
    FocusManager.instance.primaryFocus?.unfocus();
  }

  /// Shows the conversation over the tabs. The list page sets the session
  /// selection first; [ChatScreen] reads it.
  Future<void> _openChat() async {
    if (_chatOpen || !mounted) return;
    _chatOpen = true;
    final navigator = Navigator.of(context);
    try {
      await navigator.push(
        MaterialPageRoute<void>(builder: (_) => widget.chatBuilder ?? const ChatScreen()),
      );
    } finally {
      _chatOpen = false;
    }
  }

  /// A notification or a share/shortcut entry wants the conversation shown:
  /// one is already open, or there is nothing to open.
  void _revealChat(bool animate) {
    if (_chatOpen) return;
    if (ref.read(currentSessionProvider) == null) return;
    unawaited(_openChat());
  }

  /// Destinations that are not tabs still open as pushed pages (网页版 /
  /// 远程 / 插件 / 引擎 / 设置搜索); the rest switch tabs. A pushed page
  /// covers the shell, so the quick panel goes in behind it — back lands on
  /// a clean tab.
  void _openDestination(DrawerDestination destination) {
    switch (destination) {
      case DrawerDestination.settings:
        unawaited(_selectTab(2));
      case DrawerDestination.features:
        unawaited(_selectTab(1));
      case DrawerDestination.web:
        _push(const LocalWebScreen());
      case DrawerDestination.remote:
        _push(const RemoteScreen());
      case DrawerDestination.plugins:
        _push(const PluginsScreen());
      case DrawerDestination.engine:
        _push(const EngineScreen());
      case DrawerDestination.settingsSearch:
        _push(const SettingsSearchPage());
    }
  }

  void _push(Widget page) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
    // Close once the new page covers us, so "back" lands on a clean tab.
    Future<void>.delayed(AppMotion.slow, () {
      if (mounted) _quickPanel.value = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final sessionId = ref.watch(currentSessionProvider);
    // Multi-select in the list: back ends it before anything else.
    final selecting = ref.watch(drawerSelectionProvider.select((s) => s != null));
    // With a conversation open the panel has that to show, whatever shortcuts
    // it lists. Off once it's turned off: one left open goes, at once.
    final quickPanelOn = ref.watch(quickPanelProvider.select((p) => p.available || (p.swipe && sessionId != null)));
    if (!quickPanelOn && _quickPanel.value > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _quickPanel.value = 0;
      });
    }
    final gestures = quickPanelOn
        ? {
            QuickPanelDragRecognizer: GestureRecognizerFactoryWithHandlers<QuickPanelDragRecognizer>(
              () => QuickPanelDragRecognizer(
                isOpen: () => _quickPanel.value > 0,
                onStart: _onQuickPanelDragStart,
                onDelta: (dx) {
                  final width = _quickPanelWidth(context);
                  if (width <= 0) return;
                  _quickPanel.value = (_quickPanel.value - dx / width).clamp(0.0, 1.0);
                },
                onEnd: (velocity) {
                  if (velocity.abs() >= kMinFlingVelocity && _quickPanelWidth(context) > 0) {
                    final target = velocity < 0 ? 1.0 : 0.0;
                    if (AppMotion.reduced(context)) {
                      _quickPanel.value = target;
                      return;
                    }
                    final spring = AppMotion.settle(
                      AppMotion.flingSpring,
                      _quickPanel.value,
                      target,
                      -velocity / _quickPanelWidth(context),
                      landing: false,
                    );
                    if (velocity < 0) {
                      _quickPanel.animateWith(spring);
                    } else {
                      _quickPanel.animateBackWith(spring);
                    }
                    return;
                  }
                  if (_quickPanel.value >= 0.5) {
                    _slideOpen();
                  } else {
                    _slideClosed();
                  }
                },
                debugOwner: this,
              ),
              (recognizer) => recognizer.gestureSettings = MediaQuery.maybeGestureSettingsOf(context),
            ),
          }
        : const <Type, GestureRecognizerFactory>{};
    // The floating pet outside the app hears every pet state.
    ref.listen<void>(petOverlayBridgeProvider, (_, _) {});
    return SafeModeNoticeListener(
      child: PhoneStopWatcher(
        child: PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            if (_quickPanelOpen) {
              _slideClosed();
            } else if (selecting) {
              ref.read(drawerSelectionProvider.notifier).end();
            } else if (_tab != 0) {
              unawaited(_selectTab(0));
            } else {
              // 顶层:两秒内再按一次返回才退出(第一次提示);系统默认的
              // 返回退出被 canPop:false 拦下,这里自己收尾。
              final now = DateTime.now();
              if (_lastBackAt != null && now.difference(_lastBackAt!) < _backExitWindow) {
                unawaited(SystemNavigator.pop());
              } else {
                _lastBackAt = now;
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(
                    SnackBar(
                      content: Text(context.l10n.commonBackAgainToExit),
                      behavior: SnackBarBehavior.floating,
                      duration: _backExitWindow,
                    ),
                  );
              }
            }
          },
          child: AnnotatedRegion<SystemUiOverlayStyle>(
            value: dshSystemOverlay(Theme.of(context).brightness),
            // 首页三个 tab: the custom wallpaper when one is in use.
            child: WallpaperBackdrop(
              child: Scaffold(
                backgroundColor: Colors.transparent,
                // The chat screen handles the keyboard itself.
                resizeToAvoidBottomInset: false,
                // 液态玻璃底栏:三个 tab 的内容全出血,从玻璃条底下穿过。
                extendBody: true,
                body: Stack(
                  fit: StackFit.expand,
                  children: [
                    // Notifications: routes taps, raises the in-app banner (draws nothing here).
                    ChatAlertHost(onReveal: _revealChat),
                    // Background running cut off by the phone: one line under the header (draws nothing here).
                    const BackgroundNetHost(),
                    // Daily update check + install resume (draws nothing).
                    const UpdateLaunchCheck(),
                    // The voice model chosen during setup: download, resume, ready / failed notices (draws nothing).
                    const VoiceModelHost(),
                    // 公测版: once in a while, an invitation to star the project.
                    StarPromptHost(quickPanel: _quickPanel),
                    // App links / shared files: routes them to their feature (draws nothing).
                    const LinkHost(),
                    // Share codes (分享码): registers its links and files with the router.
                    const ShareCodeHost(),
                    // Share sheet, launcher shortcuts, the tile: into the chat (draws nothing).
                    SystemEntryHost(onReveal: _revealChat),
                    // Forum links (sign-in return, topics): registers them with the router.
                    const ForumLinkHost(),
                    // DS Bot: keeps its feed and notifications alive with the shell.
                    const BotAlertsHost(),
                    ExcludeSemantics(
                      excluding: _quickPanelOpen,
                      child: RawGestureDetector(
                        // translucent: join the hit chain without swallowing taps
                        // meant for the pages; empty areas still drag the panel.
                        behavior: HitTestBehavior.translucent,
                        gestures: gestures,
                        // 底栏高度计入底部内边距:各页的滚动余量据此让最后一行
                        // 能完整滚出玻璃条。
                        child: MediaQuery(
                          data: MediaQuery.of(context).copyWith(
                            padding: MediaQuery.of(context).padding.copyWith(
                              bottom: MediaQuery.of(context).padding.bottom + 76,
                            ),
                          ),
                          child: PageView(
                            // 三页都保活(等同旧 IndexedStack 的常驻);翻页
                            // 只由 [_selectTab] 驱动,不响应横滑手势 —— 左右
                            // 滑动留给快捷面板。
                            controller: _tabPages,
                            physics: const NeverScrollableScrollPhysics(),
                            children: [
                              _TabPage(
                                child: RepaintBoundary(
                                  child: widget.sessionListBuilder ??
                                      SessionListPage(onOpenChat: _openChat, onDestination: _openDestination),
                                ),
                              ),
                              const _TabPage(child: RepaintBoundary(child: AllFeaturesPage())),
                              const _TabPage(child: RepaintBoundary(child: SettingsScreen())),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Positioned.fill(
                      child: RawGestureDetector(
                        behavior: HitTestBehavior.deferToChild,
                        gestures: gestures,
                        child: _PanelOverlay(
                          animation: _quickPanel,
                          width: _quickPanelWidth(context),
                          fromRight: true,
                          panel: QuickPanel(
                            motion: _quickPanel,
                            onOpen: _openDestination,
                            sessionId: _quickPanelOpen ? sessionId : null,
                          ),
                          onClose: _slideClosed,
                        ),
                      ),
                    ),
                  ],
                ),
                bottomNavigationBar: SafeArea(
                  top: false,
                  child: Padding(
                    // 悬浮玻璃件:左右留边、底部留手势条空间,内容从玻璃下穿过。
                    padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 左件:独立的主机圆钮(标签挂在圆外下方)。
                        _DeviceKey(
                          onHost: () => showHostSheet(
                            context,
                            onManage: () => _openDestination(DrawerDestination.remote),
                          ),
                          onDetails: () => _openDestination(DrawerDestination.engine),
                        ),
                        const SizedBox(width: 12),
                        // 右件:三连胶囊。液态玻璃:选中的高亮是一颗胶囊
                        // (不是圆点),切换时从旧 tab 流到新 tab(见
                        // [_TabGlow])。纯图标(无文字),图标 22,选中
                        // primary 着色。
                        Expanded(
                          child: GlassSurface(
                            tier: GlassTier.chrome,
                            stadium: true,
                            // 格宽在这里量好传下去:Positioned 必须直接做
                            // Stack 的孩子,中间不能隔 LayoutBuilder。
                            child: LayoutBuilder(
                              builder: (context, constraints) => SizedBox(
                                height: 56,
                                child: Stack(
                                  children: [
                                    _TabGlow(
                                      flow: _tabFlow,
                                      from: _tabFrom,
                                      to: _tab,
                                      slot: constraints.maxWidth / 3,
                                    ),
                                    Positioned.fill(
                                      child: Row(
                                        children: [
                                          _homeTab(0, tooltip: context.l10n.tabChats, icon: AppIcons.chat),
                                          _homeTab(1, tooltip: context.l10n.tabMiniApps, icon: AppIcons.allFeatures),
                                          _homeTab(2, tooltip: context.l10n.commonSettings, icon: AppIcons.settings),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 底栏右件的一颗 tab:等分格里垂直居中的 22 图标。选中的高亮整条玻璃
  /// 只有一份,在 [_TabGlow] 里流到这一格;这里只管图标的着色(选中
  /// primary,未选中 onSurfaceVariant,随选中渐变)和点按。无文字,语义
  /// 和 tooltip 都用 [tooltip];点按先收起键盘再切 tab。
  Widget _homeTab(int index, {required String tooltip, required IconData icon}) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _tab == index;
    void select() {
      FocusManager.instance.primaryFocus?.unfocus();
      unawaited(_selectTab(index));
    }

    return Expanded(
      child: Semantics(
        button: true,
        label: tooltip,
        onTap: select,
        excludeSemantics: true,
        child: Tooltip(
          message: tooltip,
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              customBorder: const StadiumBorder(),
              onTap: select,
              child: Center(
                child: TweenAnimationBuilder<double>(
                  tween: Tween(end: selected ? 1.0 : 0.0),
                  duration: AppMotion.of(context, AppMotion.quick),
                  curve: AppMotion.std,
                  builder: (context, t, _) => Icon(
                    icon,
                    size: 22,
                    color: Color.lerp(scheme.onSurfaceVariant, scheme.primary, t),
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

/// 底栏三连胶囊里的选中高亮:一颗胶囊(上下 6 内缩,左右离格边 6,44 高,
/// 与玻璃条同心),不是圆点。切换 tab 时从旧格「流」到新格:前缘(朝着
/// 目标的那条边)走得快、后缘晚 12% 才动,胶囊中途被拉长、到站后缘追上
/// 收拢落位 —— 液态玻璃从一个位置流到另一个位置的感觉。reduce motion
/// 时 [_selectTab] 把时长归零,直接落位。动画被 [GlassSurface] 的玻璃
/// 裁剪,不会越出胶囊条。
class _TabGlow extends StatelessWidget {
  const _TabGlow({required this.flow, required this.from, required this.to, required this.slot});

  /// 0 → 1 的切换动画([_HomeShellState._tabFlow])。
  final Animation<double> flow;
  final int from;
  final int to;

  /// 一颗 tab 的等分格宽(玻璃条的 1/3,外层 [LayoutBuilder] 量好传来)。
  final double slot;

  @override
  Widget build(BuildContext context) {
    final width = slot * 3;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    // 视觉序:RTL 时 Row 的格序镜像,第 i 颗 tab 的格从左数是 2-i。
    int visual(int index) => rtl ? 2 - index : index;
    final fromL = visual(from) * slot + 6;
    final fromR = (visual(from) + 1) * slot - 6;
    final toL = visual(to) * slot + 6;
    final toR = (visual(to) + 1) * slot - 6;
    return AnimatedBuilder(
      animation: flow,
      builder: (context, _) {
        final t = flow.value;
        final lead = AppMotion.glide.transform(t);
        final trail = AppMotion.glide.transform(((t - 0.12) / 0.88).clamp(0.0, 1.0));
        final going = toL >= fromL;
        final left = (going ? _lerp(fromL, toL, trail) : _lerp(fromL, toL, lead)).clamp(0.0, width);
        final right = math.max(left + 12, math.min(going ? _lerp(fromR, toR, lead) : _lerp(fromR, toR, trail), width));
        return Positioned(
          left: left,
          top: 6,
          bottom: 6,
          width: right - left,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.18),
            ),
          ),
        );
      },
    );
  }

  static double _lerp(double a, double b, double t) => a + (b - a) * t;
}

/// PageView 的一页保活包装:翻过去之后状态照旧活着(滚动位置、草稿、
/// 各 tab 自己的控制器),等同旧 IndexedStack 的常驻语义。
class _TabPage extends StatefulWidget {
  const _TabPage({required this.child});

  final Widget child;

  @override
  State<_TabPage> createState() => _TabPageState();
}

class _TabPageState extends State<_TabPage> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

/// 底栏左端的主机圆钮:独立玻璃圆(56,与右件三连胶囊同高),背景色随连接
/// 状态(绿=已连接,黄=连接中,红=失败,灰=未连接),主机图标居中。
/// 点按弹出主机切换,长按看本机引擎详情(或远程网络详情)。这是全局状态件,
/// 不属于三个 tab。
class _DeviceKey extends ConsumerWidget {
  const _DeviceKey({required this.onHost, required this.onDetails});

  final VoidCallback onHost;
  final VoidCallback onDetails;

  static const _size = 56.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final colors = DshColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    final host = ref.watch(activeHostProvider);
    final name = ref.watch(hostNameProvider(host)) ?? l10n.shellDeviceLabel;
    final view = watchHostStatus(ref, host);
    final tint = hostKindTint(host.kind);
    final tone = switch (view.tone) {
      StatusTone.ok || StatusTone.busy => colors.identity[tint % colors.identity.length],
      StatusTone.warn => colors.warning.withValues(alpha: 0.18),
      StatusTone.error => colors.danger.withValues(alpha: 0.18),
      StatusTone.idle => scheme.onSurface.withValues(alpha: 0.10),
    };
    final VoidCallback longPress = host.isLocal ? onDetails : () => showRemoteNetworkDetails(context, host);
    return Tooltip(
      message: l10n.shellCurrentHostLabel(name, view.label),
      child: Semantics(
        button: true,
        label: l10n.shellCurrentHostLabel(name, view.label),
        onTap: onHost,
        onLongPress: longPress,
        excludeSemantics: true,
        child: GlassSurface(
          tier: GlassTier.chrome,
          circle: true,
          child: Material(
            color: tone,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onHost,
              onLongPress: longPress,
              child: SizedBox.square(
                dimension: _size,
                child: Center(child: Icon(AppIcons.remoteHosts, size: 24, color: scheme.onSurface)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Scrim + panel; the only part that rebuilds while the panel moves. The
/// panel keeps its state when closed, while Visibility suppresses painting,
/// semantics and tickers until the first drag frame reveals it.
/// The fluid tier: as the panel slides over, the page below drifts a little
/// the same way. Only a translation: scaling would make its glass re-sample
/// at a new size.
class _PanelOverlay extends StatelessWidget {
  const _PanelOverlay({
    required this.animation,
    required this.width,
    required this.panel,
    required this.onClose,
    this.fromRight = false,
  });

  final Animation<double> animation;
  final double width;
  final Widget panel;
  final VoidCallback onClose;
  final bool fromRight;

  @override
  Widget build(BuildContext context) {
    final scrim = DshSurfaces.of(context).scrim;
    return AnimatedBuilder(
      animation: animation,
      child: RepaintBoundary(child: panel),
      builder: (context, panel) {
        final progress = animation.value;
        return Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: IgnorePointer(
                ignoring: progress == 0,
                child: GestureDetector(
                  onTap: onClose,
                  child: ColoredBox(color: scrim.withValues(alpha: scrim.a * progress)),
                ),
              ),
            ),
            // 面板位置用 Transform 走(paint-only):每帧改 Positioned.left 会让
            // Stack 和整块面板重新布局,拖动时白白多一层成本。
            Positioned(
              left: fromRight ? null : 0,
              right: fromRight ? 0 : null,
              top: 0,
              bottom: 0,
              width: width,
              child: Visibility(
                visible: progress > 0,
                maintainState: true,
                child: Transform.translate(
                  // 面板位置用 Transform 走(paint-only):每帧改 Positioned.left 会让
                  // Stack 和整块面板重新布局,拖动时白白多一层成本。
                  offset: Offset((progress - 1) * (width + 24) * (fromRight ? -1 : 1), 0),
                  child: panel!,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
