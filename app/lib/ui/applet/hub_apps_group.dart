/// AppHub 已装小程序的数据与样式:清单(hubInstalledProvider,市场目录 +
/// DiminaHost.installed 逐个核对)与字形映射(hubAppGlyph)。桌面
/// (app_desktop)用它们渲染已装小程序组;「应用市场」入口已归桌面目录
/// (hub_apps_catalog),这里不再自带瓷贴组。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../notify/apphub_base.dart' show appHubBase;
import '../theme/app_icons.dart';
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
  const HubInstalledApp({
    required this.appId,
    required this.name,
    this.iconKey,
    this.iconUrl,
    this.installedVersionCode,
    this.marketVersionCode,
  });

  final String appId;
  final String name;
  final String? iconKey;

  /// bundle 图标(小程序包内 main/icon.png)的下载地址,市场 API 回带;
  /// 空 = 该版本包里没带图,渲染回落 [hubAppGlyph]/图标库。
  final String? iconUrl;

  /// 本机已装版本(DiminaHost.installed);查不到为 null。
  final int? installedVersionCode;

  /// 市场目录的最新版本(/api/v1/apps 行内 versionCode)。
  final int? marketVersionCode;

  /// 市场比本机新 = 桌面瓷贴可以挂「有更新」角标。
  bool get updateAvailable {
    final int? installed = installedVersionCode;
    final int? market = marketVersionCode;
    return installed != null && market != null && market > installed;
  }
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
    final int? marketVersion =
        (app['versionCode'] as num?)?.toInt() ?? int.tryParse('${app['versionCode']}');
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
      iconUrl: app['iconUrl'] as String?,
      installedVersionCode: (state['versionCode'] as num?)?.toInt(),
      marketVersionCode: marketVersion,
    ));
  }
  return installed;
});
