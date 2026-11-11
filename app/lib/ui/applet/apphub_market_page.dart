/// 「应用市场」页:AppHub 上的小程序市场(宫格「应用市场」入口进入)。
///
/// 最大复用:SearchCapsule(搜索)、SegmentedPill(应用/已安装胶囊)、
/// showAppSheet(详情弹层)、AppIcons(单色线性图标,与自带应用同风格;
/// 小程序元数据的 icon 字段 → AppIcons 常量映射)。数据源:AppHub
/// `/api/v1/apps`(市场列表)+ DiminaHost.installed(本机已装版本)。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../l10n/l10n.dart';
import '../../notify/apphub_base.dart' show appHubBase;
import '../../notify/apphub_proxy.dart' show appHubProxyBase;
import '../../state/auto_sync_state.dart' show autoSyncProvider;
import '../../state/hub_layout_state.dart' show hubLayoutProvider;
import 'hub_apps_group.dart' show hubInstalledProvider;
import '../common/list_page_row.dart';
import '../theme/theme.dart';
import '../common/search_capsule.dart'
    show SearchCapsule;
import '../common/segmented_pill.dart';
import 'apphub_app_detail_page.dart' show ApphubAppDetailPage, HubAppRef;
import 'dimina/dimina_host.dart';
import 'hub_app_icon.dart' show HubAppIcon, hubAppHasIcon;
import 'hub_apps_group.dart' show hubAppGlyph;
import 'hub_icon_cache.dart' show HubBundleIcon, hubIconCache;

enum _MarketTab { apps, installed }

/// 市场里的一条应用(AppHub `/api/v1/apps` 行)。
class _HubApp {
  _HubApp.fromJson(Map<String, Object?> json)
      : appId = json['appId'] as String? ?? '',
        name = json['name'] as String? ?? '',
        description = json['description'] as String? ?? '',
        category = json['category'] as String? ?? '',
        changelog = json['changelog'] as String? ?? '',
        iconKey = json['icon'] as String?,
        iconUrl = json['iconUrl'] as String?,
        versionCode = (json['versionCode'] as num?)?.toInt(),
        versionName = json['versionName'] as String? ?? '',
        autoSync = json['autoSync'] == true;

  final String appId;
  final String name;
  final String description;
  final String category;
  final String changelog;
  final String? iconKey;

  /// bundle 图标(包内 main/icon.png)的下载地址;空 = 没带图,渲染回落键。
  final String? iconUrl;
  final int? versionCode;
  final String versionName;

  /// autoSync 静默同步(bundle.json 顶层字段,缺省 false):true = open 时
  /// 升级跳过确认弹窗直接激活。
  final bool autoSync;
}

class ApphubMarketPage extends ConsumerStatefulWidget {
  const ApphubMarketPage({super.key});

  @override
  ConsumerState<ApphubMarketPage> createState() => _ApphubMarketPageState();
}

class _ApphubMarketPageState extends ConsumerState<ApphubMarketPage> {
  _MarketTab _tab = _MarketTab.apps;
  String _query = '';
  final TextEditingController _search = TextEditingController();
  List<_HubApp> _apps = const <_HubApp>[];
  bool _loaded = false;
  bool _failed = false;
  StreamSubscription<DiminaUpdateEvent>? _updateSub;
  final Map<String, Map<String, Object?>?> _installed = <String, Map<String, Object?>?>{};

  @override
  void initState() {
    super.initState();
    // 容器升级链路事件(installed/applied/declined/failed/ready)→ 按真实状态刷新。
    _updateSub = DiminaHost.updateEvents.listen(_onUpdateEvent);
    unawaited(_load());
  }

  @override
  void dispose() {
    _updateSub?.cancel();
    _search.dispose();
    super.dispose();
  }

  /// 升级里程碑回传后重查该应用的真实已装版本:升级确认/生效在容器弹窗里完成,
  /// Flutter 只认 config.json 的事实,不做乐观推断。
  Future<void> _onUpdateEvent(DiminaUpdateEvent event) async {
    try {
      _installed[event.appId] = await DiminaHost.installed(event.appId);
    } catch (_) {
      // 查询失败保留旧值,下一次页面加载/定时刷新兜底。
    }
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    try {
      final http.Response response = await http
          .get(Uri.parse('$appHubBase/api/v1/apps'))
          .timeout(const Duration(seconds: 8));
      final Object? body = jsonDecode(utf8.decode(response.bodyBytes));
      if (body is! Map || body['apps'] is! List) throw StateError('bad body');
      final List<_HubApp> apps = <_HubApp>[
        for (final dynamic app in body['apps'] as List<dynamic>)
          if (app is Map<String, Object?>) _HubApp.fromJson(app),
      ];
      if (!mounted) return;
      setState(() {
        _apps = apps;
        _loaded = true;
        _failed = false;
      });
      await _queryInstalled();
      // autoSync 静默同步:市场目录刚刷新,正是检查「没装→静默装、落后→静默升」
      // 的时机(单飞+冷却在 runner 内;总开关设置 → 通用 → 静默同步)。
      ref.read(autoSyncProvider.notifier).runIfDue(onApplied: () {
        if (!mounted) return;
        unawaited(_queryInstalled());
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loaded = true;
          _failed = true;
        });
      }
    }
  }

  /// 逐应用查本机已装版本(Dimina 沙盒;查询失败视为未装)。
  Future<void> _queryInstalled() async {
    for (final _HubApp app in _apps) {
      if (_installed.containsKey(app.appId)) continue;
      try {
        _installed[app.appId] = await DiminaHost.installed(app.appId);
      } catch (_) {
        _installed[app.appId] = null;
      }
    }
    if (mounted) setState(() {});
  }

  bool _isInstalled(_HubApp app) => _installed[app.appId]?['installed'] == true;

  bool _hasUpdate(_HubApp app) {
    if (!_isInstalled(app)) return false;
    final int? local = (_installed[app.appId]?['versionCode'] as num?)?.toInt();
    return local != null && app.versionCode != null && app.versionCode! > local;
  }

  bool _matches(_HubApp app) =>
      _query.isEmpty ||
      app.name.toLowerCase().contains(_query) ||
      app.appId.contains(_query) ||
      app.description.toLowerCase().contains(_query);

  Future<void> _open(_HubApp app) async {
    // async gap 前取齐主题值,免 BuildContext 跨 await。
    final Color iconColor = Theme.of(context).colorScheme.primary;
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    // bundle 图标优先直通原生;没有再按 key 栅格化。
    final Uint8List? bundlePng =
        await hubIconCache.load(app.appId, app.versionCode, app.iconUrl);
    final bool ok = await DiminaHost.open(
      appId: app.appId,
      name: app.name,
      dark: dark,
      // 菜单弹层头部图标:与市场格子同款(bundle 图标或图标库栅格)。
      iconKey: app.iconKey,
      iconColor: iconColor,
      iconPng: bundlePng,
      // 未装 = manifest 首装;已装旧版 = 后台拉新包自动升级。必须走固定端口
      // 反代:原生容器拿到 URL 后才发请求,动态隧道端口可能已被重连换掉。
      updateManifestUrl: '$appHubProxyBase/apps/${app.appId}/manifest.json',
      // 升级全自动(2026-11-11):一律跳过容器「发现新版本」确认弹窗。
      autoUpdate: true,
    );
    // 装完即把状态置为已装;版本号不做乐观改写——升级生效的 versionCode
    // 由升级事件回传/定时核对拿到真实值(全自动下通常秒级,无确认环节)。
    if (ok && mounted) {
      ref.read(hubLayoutProvider.notifier).touch('mini:${app.appId}');
      setState(() {
        _installed[app.appId] = <String, Object?>{
          ...?_installed[app.appId],
          'installed': true,
        };
      });
      // 桌面的已装清单是另一个 provider(带缓存):装/升后让它重查,
      // 否则重装的图标不回桌面。落沙盒要一点时间,稍后再复核一次。
      ref.invalidate(hubInstalledProvider);
      Timer(const Duration(seconds: 6), () {
        if (mounted) ref.invalidate(hubInstalledProvider);
      });
    }
    // 首装/升级落沙盒需要一点时间,稍后刷新已装状态。
    Timer(const Duration(seconds: 6), () {
      if (mounted) unawaited(_queryInstalled());
    });
  }

  Future<void> _showDetail(_HubApp app) async {
    // App Store 式整页详情:服务端从包内 store.json 抽取的元数据(截图/简介/
    // 权限/版本历史)由详情页自己拉取渲染;卸载入口在详情页AppBar。
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ApphubAppDetailPage(
          app: HubAppRef(
            appId: app.appId,
            name: app.name.isEmpty ? app.appId : app.name,
            description: app.description,
            category: app.category,
            changelog: app.changelog,
            iconKey: app.iconKey,
            iconUrl: app.iconUrl,
            versionCode: app.versionCode,
            versionName: app.versionName,
            autoSync: app.autoSync,
          ),
        ),
      ),
    );
    // 从详情页回来后已装状态可能变了(详情页里装/卸/升),重查一次。
    if (mounted) unawaited(_queryInstalled());
  }

  @override
  Widget build(BuildContext context) {
    final L10n l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.catalogAppHubMarket)),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: SearchCapsule(
              controller: _search,
              hint: l10n.apphubSearchHint,
              onChanged: (String text) => setState(() => _query = text.trim().toLowerCase()),
              onClear: () {
                _search.clear();
                setState(() => _query = '');
              },
            ),
          ),
          Padding(
            // tab 底部留间隙,列表卡片不再贴死胶囊(与插件/定时页同款 16)。
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: SegmentedPill<_MarketTab>(
              segments: <PillSegment<_MarketTab>>[
                PillSegment<_MarketTab>(_MarketTab.apps, l10n.apphubTabApps),
                PillSegment<_MarketTab>(_MarketTab.installed, l10n.apphubTabInstalled),
              ],
              selected: _tab,
              onChanged: (_MarketTab tab) => setState(() => _tab = tab),
            ),
          ),
          Expanded(
            child: !_loaded
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: _load,
                    child: Builder(
                      builder: (BuildContext context) {
                        if (_failed && _apps.isEmpty) {
                          return ListView(
                            children: <Widget>[
                              Padding(
                                padding: const EdgeInsets.all(28),
                                child: Text(
                                  l10n.apphubNoMarket,
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                              ),
                            ],
                          );
                        }
                        final Iterable<_HubApp> apps = _apps
                            .where((app) => _tab == _MarketTab.apps || _isInstalled(app))
                            .where(_matches);
                        if (apps.isEmpty) {
                          return ListView(
                            children: <Widget>[
                              Padding(
                                padding: const EdgeInsets.all(28),
                                child: Text(
                                  l10n.apphubEmpty,
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                              ),
                            ],
                          );
                        }
                        return ListView(
                          children: <Widget>[
                            ListPageCard(
                              children: <Widget>[
                                for (final _HubApp app in apps)
                                  ListPageRow(
                                    leading: HubBundleIcon(
                                      appId: app.appId,
                                      versionCode: app.versionCode,
                                      url: app.iconUrl,
                                      size: 32,
                                      fallback: hubAppHasIcon(app.iconKey)
                                          ? HubAppIcon(iconKey: app.iconKey, size: 32)
                                          : Icon(hubAppGlyph(app.iconKey), size: 20),
                                    ),
                                    leadingWidth: 40,
                                    title: app.name.isEmpty ? app.appId : app.name,
                                    subtitle: _rowSubtitle(app),
                                    trailing: _action(app),
                                    onTap: () => unawaited(_showDetail(app)),
                                  ),
                              ],
                            ),
                          ],
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  String _rowSubtitle(_HubApp app) {
    final List<String> parts = <String>[
      if (app.description.isNotEmpty) app.description,
      if (app.category.isNotEmpty) app.category,
    ];
    if (parts.isEmpty) return app.appId;
    return parts.join(' · ');
  }

  Widget _action(_HubApp app) {
    final L10n l10n = context.l10n;
    final ThemeData theme = Theme.of(context);
    final bool installed = _isInstalled(app);
    final bool update = _hasUpdate(app);
    // 应用商店胶囊(与插件市场 PluginInstallButton 同款视觉):
    // 未装=获取底、已装=透明+次级字,更新=获取底,都开详情/直接打开。
    final String label = update
        ? l10n.apphubUpdate
        : (installed ? l10n.apphubOpen : l10n.apphubInstall);
    return FilledButton.tonal(
      style: FilledButton.styleFrom(
        backgroundColor:
            installed ? Colors.transparent : theme.colorScheme.onSurface.withValues(alpha: 0.06),
        foregroundColor: installed ? DshColors.of(context).textTertiary : theme.colorScheme.primary,
        minimumSize: const Size(68, 30),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
        shape: const StadiumBorder(),
        elevation: 0,
        textStyle: theme.textTheme.labelLarge?.copyWith(fontSize: 13.5),
      ),
      onPressed: () => unawaited(_open(app)),
      child: Text(label),
    );
  }
}
