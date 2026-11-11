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
import '../../state/sessions_state.dart' show currentSessionProvider;
import '../applet/dimina/dimina_host.dart';
import '../applet/hub_app_icon.dart' show HubAppIcon;
import '../applet/hub_apps_group.dart'
    show HubInstalledApp, hubInstalledProvider;
import '../applet/hub_icon_cache.dart' show hubIconCache;
import '../features/all_features_page.dart' show dshWebOpenerProvider;
import '../features/feature_catalog.dart';
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
          // autoSync 包:升级跳过容器确认弹窗(发布侧已表达确认语义)。
          autoUpdate: mini.app.autoSync,
        );
        if (ok) {
          ref.read(hubLayoutProvider.notifier).touch(mini.key);
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
      editingHint: l10n.hubEditing,
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
        // 「服务通知」钥匙(契约 §6.1;2026-11-11 拍板:星河容器 Header 不再放
        // 通知铃铛,入口收在宿主页面头):大标题行右上角,固定不随滚动,
        // 未读时挂计数角标;整理模式让位给同槽位的「完成」键。
        if (!editing)
          Positioned(
            top: MediaQuery.paddingOf(context).top + 10,
            right: 24,
            child: const ServiceNoticesKey(),
          ),
        // 编辑态「完成」长在大标题行右端(与 iOS 桌面编辑同款):根路由没有
        // 浮动栏(page_frame 的 compact 态),叠加是唯一的出处,固定不随滚动。
        if (editing)
          Positioned(
            top: MediaQuery.paddingOf(context).top + 10,
            right: 24,
            child: FilledButton.tonalIcon(
              onPressed: () => ref.read(hubEditingProvider.notifier).set(false),
              icon: const Icon(Icons.check, size: 17),
              label: Text(l10n.commonDone),
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ),
      ],
    );
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
}
