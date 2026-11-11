// 「小程序」Tab 的宿主适配层:画布本体在引擎包 hub_desktop(HubDesktopView),
// 这里只做 dsh-go 语义的进出 ——
// - 打开:delegate.onOpen 按 key 查目录快照,走 DiminaHost.open(含
//   bundle 图标、更新 manifest 与 6s 复核)/ feature 的页面与网页口,
//   最近使用的记录也在这条路上;
// - 编排:首装迁移(ensureSeeded)与 autoSync 静默同步仍在这里(依赖
//   BuildContext 文案与页面时序);目录、角标、卸载钩子的注册者已迁去
//   state/hub_desktop_sync.dart(keep-alive,应用根装配养活),新装自动
//   垫组也由它经 upsertTiles 的锚点落位接管;
// - 壳:页面大标题与「完成」按钮仍归 AppPage(滚动轴经 bodyScroll 与引擎
//   共享);头部占位(PageBodyInsets)翻译成引擎的 HubPageInsets。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hub_desktop/hub_desktop.dart';

import '../../l10n/l10n.dart';
import '../../notify/apphub_proxy.dart' show appHubProxyBase;
import '../../performance/performance_state.dart' show performanceDefaultsProvider;
import '../../state/auto_sync_state.dart' show autoSyncProvider;
import '../../state/hub_desktop_sync.dart' show hubNewMinisProvider;
import '../../state/sessions_state.dart' show currentSessionProvider;
import '../applet/dimina/dimina_host.dart';
import '../applet/hub_app_icon.dart' show HubAppIcon;
import '../applet/hub_apps_group.dart'
    show HubInstalledApp, hubInstalledProvider;
import '../applet/hub_icon_cache.dart' show hubIconCache;
import '../common/round_key.dart' show RoundKey;
import '../features/all_features_page.dart' show dshWebOpenerProvider;
import '../features/feature_catalog.dart';
import '../notify/notification_center.dart' show consumeMiniAppNotices;
import '../notify/service_notices_key.dart' show ServiceNoticesKey;
import '../shell/page_frame.dart' show AppPage, PageBodyInsets;
import '../theme/theme.dart' show DshColors, DshSurfaces, GlassStyle;
import 'hub_apps_catalog.dart';

/// 桌面页。[sections] 仅供测试喂假目录;生产读 [featureSectionsProvider]。
class HubDesktopPage extends ConsumerStatefulWidget {
  const HubDesktopPage({super.key, this.sections});

  final List<FeatureSection>? sections;

  @override
  ConsumerState<HubDesktopPage> createState() => _HubDesktopPageState();
}

class _HubDesktopPageState extends ConsumerState<HubDesktopPage> {
  /// 桌面的滚动轴:引擎画布自持视口,controller 从这里注入,壳(AppPage)
  /// 用它驱动标题洗白 —— 同一条滚动轴。
  final ScrollController _scroll = ScrollController();

  /// build 时的目录快照,delegate 回调里按 key 查语义。
  Map<String, HubAppRef> _byRef = const <String, HubAppRef>{};

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  // ---------- 打开(delegate 的实现;卸载在 state/hub_desktop_sync) ----------

  void _openFeature(FeatureItem item) {
    final String? sessionId = ref.read(currentSessionProvider);
    if (item.native case final page?) {
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page(sessionId)));
    } else if (item.action case final action?) {
      unawaited(Future.sync(() => action(context, ref, sessionId)));
    } else if (item.web case final web?) {
      ref.read(dshWebOpenerProvider)(context, ref, item.webFor(sessionId) ?? web);
    }
  }

  Future<void> _open(String key) async {
    final HubAppRef? app = _byRef[key];
    if (app == null) return;
    switch (app) {
      case FeatureAppRef(:final item):
        ref.read(hubLayoutProvider.notifier).touch(app.key);
        _openFeature(item);
      case final MiniAppRef mini:
        // async gap 前取齐主题值,免 BuildContext 跨 await。
        final Color iconColor = Theme.of(context).colorScheme.primary;
        // bundle 图标优先直通原生;没有再按 key 栅格化。
        final Uint8List? bundlePng = await hubIconCache.load(
          mini.app.appId,
          mini.app.installedVersionCode ?? mini.app.marketVersionCode,
          mini.app.iconUrl,
        );
        final bool ok = await DiminaHost.open(
          appId: mini.app.appId,
          name: mini.app.name,
          // 菜单弹层头部图标:与桌面格子同款(bundle 图标或图标库栅格)。
          iconKey: mini.app.iconKey,
          iconColor: iconColor,
          iconPng: bundlePng,
          // 未装 = manifest 首装;已装旧版 = 后台拉新包自动升级。
          // 固定端口反代:原生容器拿到 URL 后才发请求,动态隧道端口可能
          // 已被重连换掉(见 apphub_proxy.dart)。
          updateManifestUrl:
              '$appHubProxyBase/apps/${mini.app.appId}/manifest.json',
          // 升级全自动(2026-11-11):一律跳过容器「发现新版本」确认弹窗
          // ——后台静默同步通常已把包换好,这里兜住「发版后立刻点开」的
          // 竞态,打开即冷重启到新版。
          autoUpdate: true,
        );
        if (ok) {
          ref.read(hubLayoutProvider.notifier).touch(mini.key);
          // 打开即消费该 app 的全部未读(主流惯例:角标随打开消,§6.1):
          // 整批已读 + 撤通知栏,图标角标/组头/钥匙随未读归零同步熄灭。
          consumeMiniAppNotices(ref, mini.app.appId);
          // iOS 式新装指示:打开一次即熄灭「新装未打开」名字点(prefs 持久
          // 化,跨重启保持;熄灭后注册者重发瓷贴)。
          ref.read(hubNewMinisProvider.notifier).markOpened(mini.key);
          // 升级/兜底首装后版本号变了:重查已装清单,更新角标随之准确。
          // 落沙盒要一点时间,延迟复核一次(与市场页同款)。
          ref.invalidate(hubInstalledProvider);
          Timer(const Duration(seconds: 6), () {
            if (mounted) ref.invalidate(hubInstalledProvider);
          });
        }
    }
  }

  // ---------- 渲染 ----------

  @override
  Widget build(BuildContext context) {
    final L10n l10n = context.l10n;
    final HubLayout layout = ref.watch(hubLayoutProvider);
    final AsyncValue<List<HubInstalledApp>> minis = ref.watch(hubInstalledProvider);
    final List<FeatureSection> sections =
        widget.sections ?? ref.watch(featureSectionsProvider);
    final HubCatalog catalog = buildHubCatalog(
      minis: minis.value ?? const <HubInstalledApp>[],
      sections: sections,
      settled: !minis.isLoading,
    );
    _byRef = <String, HubAppRef>{for (final HubAppRef app in catalog.apps) app.key: app};

    // 首装迁移:等布局读好、动态源落定,再把原静态目录原样转成用户分组。
    if (layout.loaded && !layout.seeded && catalog.settled && catalog.apps.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(ref
            .read(hubLayoutProvider.notifier)
            .ensureSeeded(catalog.seedGroups, defaultGroupName: l10n.hubDefaultGroup));
      });
    }

    // autoSync 静默同步:链路/目录落定时触发(单飞+冷却在 runner 内)。
    // 没装的 autoSync 应用静默装上、落后的静默升级;装/升成功后重查已装
    // 清单,新瓷贴由注册者的 upsertTiles 锚点落位自动垫进 AppHub 组。
    // 总开关:设置 → 通用。
    if (layout.loaded && layout.seeded && catalog.settled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.read(autoSyncProvider.notifier).runIfDue(onApplied: () {
          if (!mounted) return;
          ref.invalidate(hubInstalledProvider);
          Timer(const Duration(seconds: 6), () {
            if (mounted) ref.invalidate(hubInstalledProvider);
          });
        });
      });
    }

    // 文案:宿主从现有 l10n 取词注入(语言切换时这里随 build 重建)。
    final HubDesktopStrings strings = HubDesktopStrings(
      searchHint: l10n.apphubSearchHint,
      recentGroup: l10n.hubRecentGroup,
      defaultGroup: l10n.hubDefaultGroup,
      newGroup: l10n.hubNewGroup,
      rename: l10n.hubRename,
      moveUp: l10n.hubMoveUp,
      moveDown: l10n.hubMoveDown,
      deleteGroup: l10n.hubDeleteGroup,
      deleteGroupBody: l10n.hubDeleteGroupBody,
      dropHere: l10n.hubDropHere,
      noMatch: l10n.hubNoMatch,
      cancel: l10n.commonCancel,
      save: l10n.commonSave,
      clearLabel: l10n.commonClear,
      closeLabel: l10n.commonClose,
    );

    // 灵动档:与壳根同一来源(性能默认值),交给引擎的 HubMotionScope。
    final bool fluid = ref.watch(performanceDefaultsProvider.select((d) => d.fluidMotion)) &&
        !(MediaQuery.maybeDisableAnimationsOf(context) ?? false);
    final bool editing = ref.watch(hubEditingProvider);

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        AppPage(
          title: l10n.tabMiniApps,
          bodyScroll: _scroll,
          body: Builder(
            builder: (BuildContext bodyContext) {
              // 壳把头部占位(PageBodyInsets)挂在这层,翻译给引擎的
              // HubPageInsets;主题桥(HubColors/HubGlassTheme)也从宿主
              // 主题取值注入。
              final PageBodyInsets? insets = PageBodyInsets.maybeOf(bodyContext);
              final ThemeData baseTheme = Theme.of(bodyContext);
              // 主题桥:在宿主主题之上并入引擎的两个 extension(引擎子树只读
              // 它们;宿主自家的 extension 原样带上,framework 的 map 是整表
              // 替换,不能只给增量)。
              final List<ThemeExtension<ThemeExtension<dynamic>>> bridgedExtensions =
                  <ThemeExtension<ThemeExtension<dynamic>>>[
                for (final ThemeExtension<dynamic> extension in baseTheme.extensions.values)
                  extension as ThemeExtension<ThemeExtension<dynamic>>,
                HubColors(textTertiary: DshColors.of(bodyContext).textTertiary),
                _hubGlassTheme(DshSurfaces.of(bodyContext)),
              ];
              return HubPageInsets(
                top: insets?.top ?? MediaQuery.paddingOf(bodyContext).top,
                headerHeight: insets?.headerHeight ?? 0,
                child: HubMotionScope(
                  fluid: fluid,
                  child: Theme(
                    data: baseTheme.copyWith(extensions: bridgedExtensions),
                    child: HubDesktopView(
                      delegate: _HubDelegate(this),
                      strings: strings,
                      controller: _scroll,
                      glyphBuilder: (String glyphKey) =>
                          HubAppIcon(iconKey: glyphKey, size: IconTile.dimension, tiled: false),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        // 标题行右侧的钥匙槽(E5):普通态一颗「服务通知」钥匙,编辑态
        // 「完成」+「最近使用开关」两颗并排(间距 10)——同一槽位,两副
        // 面孔。top 见 [_overlayKeyTop](与大标题行视觉中线对齐),固定不随
        // 滚动。未读时服务通知钥匙挂计数角标(契约 §6.1)。
        if (!editing)
          Positioned(
            top: _overlayKeyTop(context),
            right: 24,
            child: const ServiceNoticesKey(),
          ),
        if (editing)
          Positioned(
            top: _overlayKeyTop(context),
            right: 24,
            child: Row(
              children: <Widget>[
                RoundKey(
                  icon: Icons.check,
                  tooltip: l10n.commonDone,
                  onTap: () => ref.read(hubEditingProvider.notifier).set(false),
                ),
                const SizedBox(width: 10),
                // 最近使用显示/隐藏:隐藏态置灰(iOS 式 45%)。
                Opacity(
                  opacity: layout.smartSection().hidden ? 0.45 : 1.0,
                  child: RoundKey(
                    icon: Icons.history,
                    tooltip: l10n.hubToggleRecents,
                    onTap: () => ref
                        .read(hubLayoutProvider.notifier)
                        .setRecentsHidden(!layout.smartSection().hidden),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// 标题行钥匙的 top(E5)。对齐基准 = page_frame compact 头的大标题行:
  /// 从 padding.top 起、上内距 6、行高按 headlineLarge 现量(TextPainter,
  /// 与 page_frame 的实测同式),钥匙(RoundKey.size 34)与标题行「视觉
  /// 中线」对齐 = padding.top + 6 + (lineHeight − keySize) / 2。其他页浮
  /// 栏按钮走的 NavigationToolbar 56dp 槽在 compact 头不存在,故按标题行
  /// 直接对齐。
  double _overlayKeyTop(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextPainter painter = TextPainter(
      text: TextSpan(text: '国A', style: theme.textTheme.headlineLarge),
      textDirection: Directionality.of(context),
      maxLines: 1,
    )..layout();
    final double line = painter.height;
    painter.dispose();
    return MediaQuery.paddingOf(context).top + 6 + (line - RoundKey.size) / 2;
  }

  /// 宿主 DshSurfaces → 引擎玻璃材质(值逐字段翻译,渲染公式在引擎侧)。
  HubGlassTheme _hubGlassTheme(DshSurfaces s) => HubGlassTheme(
        sheet: _hubGlassStyle(s.sheet),
        card: _hubGlassStyle(s.card),
        blurEnabled: s.blurEnabled,
      );

  HubGlassStyle _hubGlassStyle(GlassStyle s) => HubGlassStyle(
        fill: s.fill,
        fallbackFill: s.fallbackFill,
        hairline: s.hairline,
        rim: s.rim,
        blurSigma: s.blurSigma,
        saturation: s.saturation,
        hairlineWidth: s.hairlineWidth,
        shadows: s.shadows,
      );
}

/// 引擎回调 → 宿主语义:打开按 key 查目录快照再分发。
class _HubDelegate implements HubDesktopDelegate {
  _HubDelegate(this._page);

  final _HubDesktopPageState _page;

  @override
  void onOpen(HubTile tile) => unawaited(_page._open(tile.key));

  @override
  void onUnavailableTap(HubTile tile) {
    final BuildContext context = _page.context;
    if (!context.mounted) return;
    // 多机语义:点了「依赖后端而这台机器没部署」的置灰瓷贴。删除/卸载
    // 不受置灰影响,这里只解释为什么点不开。
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(context.l10n.hubAppUnavailableOnMachine(tile.name)),
        duration: const Duration(seconds: 4),
      ));
  }
}
