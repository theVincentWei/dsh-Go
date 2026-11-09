// 「小程序」桌面的应用清单:AppHub 已装小程序、自带功能(含插件面板)与
// 「应用市场」入口,合成本目录。桌面渲染这份清单 + 布局(hub_layout_state);
// 分组与排序属于布局,这里只管「有哪些应用」。
//
// 注意 hubInstalledProvider 的落定节奏:市场没连上时 settled 为 true 但小
// 程序为空——迁移照做,小程序装好后按「新应用」进默认组;源还在加载
// (settled=false)时页面先不做迁移,免得把本该回原位的应用当新应用。

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../applet/apphub_market_page.dart' show ApphubMarketPage;
import '../applet/hub_apps_group.dart' show HubInstalledApp, hubInstalledProvider;
import '../features/feature_catalog.dart'
    show FeatureItem, FeatureSection, featureSectionsProvider;
import '../theme/app_icons.dart' show AppIcons;

/// 桌面上一个可打开的应用。[key] 是布局身份:`mini:<appId>` /
/// `feature:<id>`;两条命名空间互不相撞,卸载重装、换语言都不挪窝。
sealed class HubAppRef {
  const HubAppRef();

  String get key;
  String get name;
}

/// 一个已安装的 AppHub 小程序(Dimina)。
class MiniAppRef extends HubAppRef {
  const MiniAppRef(this.app);

  final HubInstalledApp app;

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

  /// 迁移种子:AppHub、原静态目录各一条(应用 key 按展示顺序)。
  final List<({String title, List<String> keys})> seedGroups;

  /// AppHub 动态源落定了(有值或出错)。落定前页面不做迁移。
  final bool settled;

  HubAppRef? byKey(String key) =>
      apps.where((app) => app.key == key).firstOrNull;
}

/// 「应用市场」入口 = 一个普通 feature 应用,桌面里可以拖去任何分组。
FeatureItem hubMarketFeature() => FeatureItem.localized(
      id: 'apphub-market',
      title: (l10n) => l10n.catalogAppHubMarket,
      summary: (l10n) => l10n.catalogAppHubMarketSummary,
      icon: AppIcons.allFeatures,
      native: (_) => const ApphubMarketPage(),
    );

/// 组装目录。[sections] 一般来自 featureSectionsProvider(含插件面板);
/// 测试可以直接喂假 sections。
HubCatalog buildHubCatalog({
  required List<HubInstalledApp> minis,
  required List<FeatureSection> sections,
  required bool settled,
}) {
  final List<HubAppRef> apps = <HubAppRef>[
    for (final HubInstalledApp app in minis) MiniAppRef(app),
    FeatureAppRef(hubMarketFeature()),
    for (final FeatureSection section in sections)
      for (final FeatureItem item in section.items) FeatureAppRef(item),
  ];
  return HubCatalog(
    apps: apps,
    seedGroups: <({String title, List<String> keys})>[
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

/// 生产目录:两个源都在 provider 里,页面直接 watch。
final hubCatalogProvider = Provider.autoDispose<HubCatalog>((ref) {
  final AsyncValue<List<HubInstalledApp>> minis = ref.watch(hubInstalledProvider);
  final List<FeatureSection> sections = ref.watch(featureSectionsProvider);
  return buildHubCatalog(
    minis: minis.value ?? const <HubInstalledApp>[],
    sections: sections,
    settled: !minis.isLoading,
  );
});
