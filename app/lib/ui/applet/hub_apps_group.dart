/// AppHub 已装小程序的数据与样式:清单(hubInstalledProvider,市场目录 +
/// DiminaHost.installed 逐个核对,冷启先回持久化快照)与字形映射
/// (hubAppGlyph)。桌面(注册者 hub_desktop_sync 与引擎画布)用它们渲染
/// 已装小程序组;「应用市场」入口已归桌面目录(hub_apps_catalog),这里
/// 不再自带瓷贴组。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

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
    this.autoSync = false,
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

  /// autoSync 静默同步(bundle.json 顶层字段,缺省 false):true = 打开时
  /// 升级跳过容器确认弹窗;后台同步服务也会静默装/升。
  final bool autoSync;

  /// 市场比本机新 = 桌面瓷贴可以挂「有更新」角标。
  bool get updateAvailable {
    final int? installed = installedVersionCode;
    final int? market = marketVersionCode;
    return installed != null && market != null && market > installed;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'appId': appId,
    'name': name,
    if (iconKey != null) 'iconKey': iconKey,
    if (iconUrl != null) 'iconUrl': iconUrl,
    if (installedVersionCode != null) 'installedVersionCode': installedVersionCode,
    if (marketVersionCode != null) 'marketVersionCode': marketVersionCode,
    if (autoSync) 'autoSync': true,
  };

  /// 快照反序列化,字段逐个容错(坏条目退缺省,不让一颗坏数据废整份快照)。
  static HubInstalledApp fromJson(Map<String, Object?> json) => HubInstalledApp(
    appId: json['appId'] as String? ?? '',
    name: json['name'] as String? ?? '',
    iconKey: json['iconKey'] as String?,
    iconUrl: json['iconUrl'] as String?,
    installedVersionCode: (json['installedVersionCode'] as num?)?.toInt(),
    marketVersionCode: (json['marketVersionCode'] as num?)?.toInt(),
    autoSync: json['autoSync'] == true,
  );
}

/// 已装清单的持久化快照(prefs `hub.installed-snapshot.v1`):每次成功
/// 落定且非空整批覆盖;冷启动/重挂载先回快照,真清单落定后对账,缩编
/// 条目由 hub_desktop_sync 的差量 removeTile 收走(槽位保留,重装原位
/// 恢复)。损坏即弃(当没有快照,直接走真抓取),不挡真数据。
class HubInstalledSnapshot {
  static const String _key = 'hub.installed-snapshot.v1';

  static Future<List<HubInstalledApp>?> load() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return null;
      final Object? json = jsonDecode(raw);
      if (json is! List) return null;
      final List<HubInstalledApp> apps = <HubInstalledApp>[
        for (final dynamic item in json)
          if (item is Map)
            HubInstalledApp.fromJson(Map<String, Object?>.from(item)),
      ];
      // 一颗 appId 都没有 = 没有可用快照,不当真。
      return apps.any((HubInstalledApp app) => app.appId.isNotEmpty) ? apps : null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(List<HubInstalledApp> apps) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _key,
        jsonEncode(<Object?>[for (final HubInstalledApp app in apps) app.toJson()]),
      );
    } catch (_) {
      // 只留这轮。
    }
  }
}

/// 真抓取:市场目录 × DiminaHost.installed 逐个核对(旧 FutureProvider
/// 的 body,行为不变;host 断开时逐个 continue,一条没有就空清单)。
Future<List<HubInstalledApp>> _fetchInstalled() async {
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
      autoSync: app['autoSync'] == true,
    ));
  }
  return installed;
}

/// 已装清单。冷启语义(现象 A「整页弹入」的修复):
/// - 第一次 build 若有非空快照,**先以快照为现状返回**(状态即刻 AsyncData,
///   loading 不经过 UI,AppHub 组不再从 0 弹入),再排一轮静默刷新把状态
///   换成真值;之后的 invalidate 不再走快照,直接拉真数据——避免已显示的
///   真值被闪回旧快照;
/// - **空结果一律不覆盖非空现状**(无论快照路径还是 invalidate 路径):
///   空多半是 host 断开读不到,不是用户把小程序全卸了——网络抖动/断连
///   都不塌目录;只有现状本来就空(首次)才落空值;
/// - 首次安装(无快照)保持现状:loading→真值,弹入一次属预期。
///
/// keep-alive 注册者(hub_desktop_sync)从应用根 watch,控制器实例整个
/// 生命周期存活,`_bootstrapped` 只在真正的冷启动为 false。
class HubInstalledController extends AsyncNotifier<List<HubInstalledApp>> {
  bool _bootstrapped = false;

  /// 测试注入点:替换真抓取。生产一律 [`_fetchInstalled`]。
  @visibleForTesting
  static Future<List<HubInstalledApp>> Function() fetcher = _fetchInstalled;

  @override
  Future<List<HubInstalledApp>> build() async {
    final List<HubInstalledApp> previous = state.value ?? const <HubInstalledApp>[];
    if (!_bootstrapped) {
      _bootstrapped = true;
      final List<HubInstalledApp>? snapshot = await HubInstalledSnapshot.load();
      if (snapshot != null && snapshot.isNotEmpty) {
        unawaited(_refresh());
        return snapshot;
      }
    }
    final List<HubInstalledApp> apps = await fetcher();
    if (!ref.mounted) return previous;
    if (apps.isEmpty && previous.isNotEmpty) return previous;
    if (apps.isNotEmpty) unawaited(HubInstalledSnapshot.save(apps));
    return apps;
  }

  /// 静默刷新:不经过 loading(状态从快照直接换成真值,或保持快照)。
  Future<void> _refresh() async {
    // 排到 build 完成之后(Riverpod 不允许 build 期间写状态)。
    await Future<void>.delayed(Duration.zero);
    try {
      final List<HubInstalledApp> apps = await fetcher();
      if (!ref.mounted) return;
      final List<HubInstalledApp> current = state.value ?? const <HubInstalledApp>[];
      if (apps.isEmpty && current.isNotEmpty) return;
      state = AsyncData<List<HubInstalledApp>>(apps);
      if (apps.isNotEmpty) unawaited(HubInstalledSnapshot.save(apps));
    } catch (_) {
      // 拉取失败:保持现状(目录不塌);下次 invalidate 重试。
    }
  }
}

final hubInstalledProvider = AsyncNotifierProvider.autoDispose<HubInstalledController, List<HubInstalledApp>>(
  HubInstalledController.new,
);
