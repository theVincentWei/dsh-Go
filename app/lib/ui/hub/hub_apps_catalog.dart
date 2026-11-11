// 「小程序」桌面的应用清单:星河(引擎 HTML 应用)、AppHub 已装小程序、自带
// 功能(含插件面板)与「应用市场」入口,三源合一本目录。桌面渲染这份清单 +
// 布局(hub_layout_state);分组与排序属于布局,这里只管「有哪些应用」。
//
// 注意 featureSectionsProvider 与星河/AppHub 两个 FutureProvider 的落定节奏:
// 市场没连上时 settled 为 true 但小程序为空——迁移照做,小程序装好后按
// 「新应用」进默认组;源还在加载(settled=false)时页面先不做迁移,免得把
// 本该回原位的应用当新应用。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hub_desktop/hub_desktop.dart' show HubIcon, HubTile, IconTile;

import '../../l10n/l10n.dart';
import '../applet/apphub_market_page.dart' show ApphubMarketPage;
import '../applet/hub_app_icon.dart' show HubAppIcon, hubAppHasIcon, hubAppIconSpec;
import '../applet/hub_apps_group.dart' show HubInstalledApp, hubAppGlyph, hubInstalledProvider;
import '../applet/hub_icon_cache.dart' show HubBundleIcon;
import '../common/feature_tile.dart' show FeatureTile;
import '../features/feature_catalog.dart'
    show FeatureItem, FeatureSection, featureSectionsProvider, hubDesktopTools;
import '../theme/app_icons.dart' show AppIcons;

/// 桌面上一个可打开的应用。[key] 是布局身份:`applet:<dir>` / `mini:<appId>` /
/// `feature:<id>`;三条命名空间互不相撞,卸载重装、换语言都不挪窝。
sealed class HubAppRef {
  const HubAppRef();

  String get key;
  String get name;
}

/// 一个已安装的 AppHub 小程序(Dimina)。
class MiniAppRef extends HubAppRef {
  const MiniAppRef(this.app, {required this.updateAvailable});

  final HubInstalledApp app;

  /// 市场比本机新:桌面瓷贴挂「有更新」小点。
  final bool updateAvailable;

  @override
  String get key => 'mini:${app.appId}';
  @override
  String get name => app.name;
}

/// 一个自带功能 / 插件面板 / 应用市场入口(后两者也是 FeatureItem)。
class FeatureAppRef extends HubAppRef {
  const FeatureAppRef(this.item);

  final FeatureItem item;

  @override
  String get key => 'feature:${item.id}';
  @override
  String get name => item.title;
}

/// 桌面目录:全部应用 + 首装迁移用的种子分组 + 动态源是否已落定。
class HubCatalog {
  const HubCatalog({
    required this.apps,
    required this.seedGroups,
    required this.settled,
  });

  final List<HubAppRef> apps;

  /// 迁移种子:星河、AppHub、原静态目录各一条(应用 key 按展示顺序)。
  final List<({String title, List<String> keys})> seedGroups;

  /// 星河与 AppHub 两个动态源都落定了(有值或出错)。落定前页面不做迁移。
  final bool settled;

  HubAppRef? byKey(String key) =>
      apps.where((app) => app.key == key).firstOrNull;
}

/// 「应用市场」入口的布局 key(feature: 前缀见 [HubAppRef.key])。新装小程序
/// 的自动安置(absorbUnplaced)拿它当锚点:落进市场入口所在的分组。
const String hubMarketFeatureId = 'apphub-market';

/// 「应用市场」入口 = 一个普通 feature 应用,桌面里可以拖去任何分组。
FeatureItem hubMarketFeature() => FeatureItem.localized(
      id: hubMarketFeatureId,
      title: (l10n) => l10n.catalogAppHubMarket,
      summary: (l10n) => l10n.catalogAppHubMarketSummary,
      icon: AppIcons.allFeatures,
      native: (_) => const ApphubMarketPage(),
    );

/// 组装目录。[sections] 一般来自 featureSectionsProvider(含插件面板);
/// 测试可以直接喂假 sections。种子里「星河」沿用星河组的固定名(非 l10n)。
HubCatalog buildHubCatalog({
  required List<HubInstalledApp> minis,
  required List<FeatureSection> sections,
  required bool settled,
}) {
  final List<HubAppRef> apps = <HubAppRef>[
    for (final HubInstalledApp app in minis)
      MiniAppRef(app, updateAvailable: app.updateAvailable),
    FeatureAppRef(hubMarketFeature()),
    // 「文件」「终端」是 Flutter 原生页,这里当普通应用上桌面(不是 Dimina
    // 小程序);文件是免会话的主机目录版(2026-11-10 拍板),不随会话置灰。
    for (final FeatureItem item in hubDesktopTools) FeatureAppRef(item),
    for (final FeatureSection section in sections)
      for (final FeatureItem item in section.items) FeatureAppRef(item),
  ];
  return HubCatalog(
    apps: apps,
    seedGroups: <({String title, List<String> keys})>[
      // 会话工具排在最前:文件 / 终端是桌面上的「本对话」组。
      (
        title: appL10n.hubConversationTools,
        keys: <String>[for (final FeatureItem item in hubDesktopTools) 'feature:${item.id}'],
      ),
      (
        title: appL10n.catalogAppHubSection,
        keys: <String>[
          for (final app in minis) 'mini:${app.appId}',
          'feature:apphub-market',
        ],
      ),
      for (final FeatureSection section in sections)
        (
          title: section.title,
          keys: <String>[for (final item in section.items) 'feature:${item.id}'],
        ),
    ],
    settled: settled,
  );
}

/// 生产目录:三个源都在 provider 里,页面直接 watch。
final hubCatalogProvider = Provider.autoDispose<HubCatalog>((ref) {
  final AsyncValue<List<HubInstalledApp>> minis = ref.watch(hubInstalledProvider);
  final List<FeatureSection> sections = ref.watch(featureSectionsProvider);
  return buildHubCatalog(
    minis: minis.value ?? const <HubInstalledApp>[],
    sections: sections,
    settled: !minis.isLoading,
  );
});

/// 目录项 → 引擎瓷贴(HubTile)。图标三档对齐原桌面渲染顺序:bundle 图标
/// 直通(widget 档)> 图标库键 + 实底彩块(glyph 档,字形由宿主
/// glyphBuilder 构建)> 万能单色字形(widget 档)。小程序可卸载(宿主给
/// mini: 命名空间注册了卸载钩子);自带功能不可卸。
///
/// 不收 iconColor:装配端(state/hub_desktop_sync 的 keep-alive 注册者)
/// 不是 widget 环境,拿不到 Theme——主色字形由 [_PrimaryIcon] 在引擎子树
/// 渲染时自取。
HubTile hubTileOf(HubAppRef app, {required bool enabled}) {
  final HubIcon icon = switch (app) {
    MiniAppRef(:final app) when app.iconUrl != null => HubIcon.widget(HubBundleIcon(
        appId: app.appId,
        versionCode: app.installedVersionCode ?? app.marketVersionCode,
        url: app.iconUrl,
        size: IconTile.dimension,
        fallback: _libraryIcon(app.iconKey),
      )),
    MiniAppRef(:final app) when hubAppHasIcon(app.iconKey) =>
      HubIcon.glyph(app.iconKey!, color: hubAppIconSpec(app.iconKey)!.color),
    MiniAppRef(:final app) => HubIcon.widget(_libraryIcon(app.iconKey)),
    FeatureAppRef(:final item) => switch (item.tile) {
        final kind? => HubIcon.widget(FeatureTile(kind, size: 30)),
        null => HubIcon.widget(_PrimaryIcon(item.icon)),
      },
  };
  return HubTile(
    key: app.key,
    name: app.name,
    icon: icon,
    enabled: enabled,
    uninstallable: app is MiniAppRef,
  );
}

/// 图标库兜底:库内键白色字形(实底彩块由引擎按 glyph 档的 color 染),
/// 库外落万能单色字形(老行为)。
Widget _libraryIcon(String? iconKey) => hubAppHasIcon(iconKey)
    ? HubAppIcon(iconKey: iconKey, size: IconTile.dimension, tiled: false)
    : _PrimaryIcon(hubAppGlyph(iconKey));

/// 主色单色字形:渲染时自取主题主色(装配时没有 BuildContext)。
class _PrimaryIcon extends StatelessWidget {
  const _PrimaryIcon(this.icon);

  final IconData? icon;

  @override
  Widget build(BuildContext context) =>
      Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary);
}
