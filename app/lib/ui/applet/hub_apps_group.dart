/// AppHub 已安装小程序瓷贴组:插在全部功能页(「星河」组之后),取代静态目录
/// 里的 AppHub 组。已装的小程序排前面,「应用市场」瓷贴固定收尾;数据来自
/// 市场目录(/api/v1/apps)+ DiminaHost.installed 逐个核对,装没装一目了然。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../l10n/l10n.dart';
import '../../notify/apphub_base.dart' show appHubBase;
import '../common/tile_grid.dart';
import '../theme/app_icons.dart';
import 'apphub_market_page.dart' show ApphubMarketPage;
import 'dimina/dimina_host.dart';

/// AppHub 应用图标键 → App 字形(与市场页行内一致);不认识的落 allFeatures。
IconData hubAppGlyph(String? key) => switch (key) {
      'book' => AppIcons.skill,
      'chart' => AppIcons.sessionDetails,
      'puzzle' => AppIcons.plugin,
      'star' => AppIcons.favorite,
      _ => AppIcons.allFeatures,
    };

/// 一个已安装的 AppHub 小程序。
class HubInstalledApp {
  const HubInstalledApp({required this.appId, required this.name, this.iconKey});

  final String appId;
  final String name;
  final String? iconKey;
}

final hubInstalledProvider = FutureProvider.autoDispose<List<HubInstalledApp>>((ref) async {
  final http.Response response =
      await http.get(Uri.parse('$appHubBase/api/v1/apps')).timeout(const Duration(seconds: 8));
  final Object? body = jsonDecode(utf8.decode(response.bodyBytes));
  if (body is! Map || body['apps'] is! List) return const <HubInstalledApp>[];
  final List<HubInstalledApp> installed = <HubInstalledApp>[];
  for (final dynamic app in body['apps'] as List<dynamic>) {
    if (app is! Map) continue;
    final String appId = app['appId'] as String? ?? '';
    if (appId.isEmpty) continue;
    final Object? state;
    try {
      state = await DiminaHost.installed(appId);
    } catch (_) {
      continue;
    }
    if (state is! Map || state['installed'] != true) continue;
    installed.add(HubInstalledApp(
      appId: appId,
      name: app['name'] as String? ?? appId,
      iconKey: app['icon'] as String?,
    ));
  }
  return installed;
});

/// 已安装小程序 + 应用市场入口的瓷贴组:分组标签 + 4 列网格,与功能目录同款。
class HubAppsGroup extends ConsumerWidget {
  const HubAppsGroup({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final L10n l10n = context.l10n;
    final Color iconColor = Theme.of(context).colorScheme.primary;
    return FutureBuilder<List<HubInstalledApp>>(
      future: ref.watch(hubInstalledProvider.future),
      builder: (BuildContext context, AsyncSnapshot<List<HubInstalledApp>> snapshot) {
        final List<HubInstalledApp> apps = snapshot.data ?? const <HubInstalledApp>[];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            FeatureGroupLabel(l10n.catalogAppHubSection),
            TileGrid(
              columns: 4,
              spacing: 16,
              children: <Widget>[
                for (final HubInstalledApp app in apps)
                  IconTile(
                    icon: Icon(hubAppGlyph(app.iconKey), size: 20, color: iconColor),
                    label: app.name,
                    onTap: () => unawaited(DiminaHost.open(
                      appId: app.appId,
                      name: app.name,
                      updateManifestUrl: '$appHubBase/apps/${app.appId}/manifest.json',
                    )),
                  ),
                IconTile(
                  icon: Icon(AppIcons.allFeatures, size: 20, color: iconColor),
                  label: l10n.catalogAppHubMarket,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: (_) => const ApphubMarketPage()),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}
