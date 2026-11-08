/// 「应用市场」页:AppHub 上的小程序市场(宫格「应用市场」入口进入)。
///
/// 最大复用:SearchCapsule(搜索)、SegmentedPill(应用/已安装胶囊)、
/// showAppSheet(详情弹层)、AppIcons(单色线性图标,与自带应用同风格;
/// 小程序元数据的 icon 字段 → AppIcons 常量映射)。数据源:AppHub
/// `/api/v1/apps`(市场列表)+ DiminaHost.installed(本机已装版本)。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../l10n/l10n.dart';
import '../../notify/apphub_base.dart' show appHubBase;
import '../theme/app_icons.dart';
import '../common/app_sheet.dart' show showAppSheet, kSheetGutter;
import '../common/sheet_title_bar.dart' show SheetTitleBar;
import '../common/search_capsule.dart'
    show SearchCapsule;
import '../common/segmented_pill.dart';
import 'dimina/dimina_host.dart';

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
        versionCode = (json['versionCode'] as num?)?.toInt(),
        versionName = json['versionName'] as String? ?? '';

  final String appId;
  final String name;
  final String description;
  final String category;
  final String changelog;
  final String? iconKey;
  final int? versionCode;
  final String versionName;
}

class ApphubMarketPage extends StatefulWidget {
  const ApphubMarketPage({super.key});

  @override
  State<ApphubMarketPage> createState() => _ApphubMarketPageState();
}

class _ApphubMarketPageState extends State<ApphubMarketPage> {
  _MarketTab _tab = _MarketTab.apps;
  String _query = '';
  final TextEditingController _search = TextEditingController();
  List<_HubApp> _apps = const <_HubApp>[];
  bool _loaded = false;
  bool _failed = false;
  final Map<String, Map<String, Object?>?> _installed = <String, Map<String, Object?>?>{};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
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
    await DiminaHost.open(
      appId: app.appId,
      name: app.name,
      // 未装 = manifest 首装;已装旧版 = 后台拉新包自动升级。
      updateManifestUrl: '$appHubBase/apps/${app.appId}/manifest.json',
    );
    // 首装/升级落沙盒需要一点时间,稍后刷新已装状态。
    Timer(const Duration(seconds: 6), () {
      if (mounted) unawaited(_queryInstalled());
    });
  }

  Future<void> _uninstall(_HubApp app) async {
    final L10n l10n = context.l10n;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialog) => AlertDialog(
        title: Text('${l10n.apphubUninstall} ${app.name}'),
        content: Text(l10n.apphubUninstallBody),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(dialog).pop(false), child: Text(l10n.commonCancel)),
          FilledButton(onPressed: () => Navigator.of(dialog).pop(true), child: Text(l10n.apphubUninstall)),
        ],
      ),
    );
    if (ok != true) return;
    await DiminaHost.uninstall(app.appId, clearUserData: true);
    if (!mounted) return;
    setState(() => _installed[app.appId] = <String, Object?>{'installed': false});
  }

  Future<void> _showDetail(_HubApp app) async {
    final L10n l10n = context.l10n;
    await showAppSheet(
      context,
      heightFactor: 0.6,
      builder: (BuildContext sheet) => SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(kSheetGutter),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              SheetTitleBar(app.name, actions: <Widget>[
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: l10n.apphubUninstall,
                  onPressed: () {
                    Navigator.of(sheet).pop();
                    unawaited(_uninstall(app));
                  },
                ),
              ]),
              Row(children: <Widget>[
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: Theme.of(sheet).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(_glyph(app.iconKey), size: 26),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'v${app.versionName.isEmpty ? app.versionCode ?? '?' : app.versionName}'
                    '${app.category.isEmpty ? '' : ' · ${app.category}'}',
                    style: Theme.of(sheet).textTheme.bodySmall,
                  ),
                ),
              ]),
              if (app.description.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(app.description, style: Theme.of(sheet).textTheme.bodyMedium),
                ),
              if (app.changelog.isNotEmpty)
                Container(
                  margin: const EdgeInsets.only(top: 12),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Theme.of(sheet).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(app.changelog, style: Theme.of(sheet).textTheme.bodySmall),
                ),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: () {
                  Navigator.of(sheet).pop();
                  unawaited(_open(app));
                },
                icon: const Icon(Icons.open_in_new, size: 17),
                label: Text(_isInstalled(app)
                    ? (_hasUpdate(app) ? l10n.apphubUpdate : l10n.apphubOpen)
                    : l10n.apphubInstall),
              ),
            ],
          ),
        ),
      ),
    );
  }

  IconData _glyph(String? key) => switch (key) {
        'book' => AppIcons.skill,
        'chart' => AppIcons.sessionDetails,
        'puzzle' => AppIcons.plugin,
        'star' => AppIcons.favorite,
        _ => AppIcons.allFeatures,
      };

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
            padding: const EdgeInsets.symmetric(horizontal: 16),
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
                            for (final _HubApp app in apps)
                              ListTile(
                                leading: Icon(_glyph(app.iconKey)),
                                title: Text(app.name.isEmpty ? app.appId : app.name),
                                subtitle: Text(_rowSubtitle(app)),
                                trailing: _action(app),
                                onTap: () => unawaited(_showDetail(app)),
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
    final bool installed = _isInstalled(app);
    final bool update = _hasUpdate(app);
    if (!installed) {
      return FilledButton.tonal(
        onPressed: () => unawaited(_open(app)),
        style: FilledButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 14),
        ),
        child: Text(l10n.apphubInstall),
      );
    }
    return FilledButton(
      onPressed: () => unawaited(_open(app)),
      style: FilledButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 14),
      ),
      child: Text(update ? l10n.apphubUpdate : l10n.apphubOpen),
    );
  }
}
