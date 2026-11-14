/// 「应用详情」页:App Store 式整页详情(市场列表点进来),数据全部来自
/// AppHub 服务端从包内 main/store.json 抽取的元数据——截图轮播、简介、
/// 新功能、信息表、权限与隐私、版本历史。字段全部可选:服务端缺哪块,
/// 对应区块直接不渲染,页面永不因缺数据开天窗。
///
/// 打开/安装动作与市场列表行内按钮同一条链路(DiminaHost.open + 桌面
/// touch + 已装清单失效重查),抽出 [openHubApp] 供两处共用。
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
import '../../state/hub_layout_state.dart' show hubLayoutProvider;
import '../notify/notification_center.dart' show consumeMiniAppNotices;
import 'apphub_uninstall_dialog.dart' show showAndRunAppUninstall;
import 'dimina/dimina_host.dart';
import 'hub_app_icon.dart' show HubAppIcon, hubAppHasIcon;
import 'hub_app_permissions.dart';
import 'hub_apps_group.dart' show hubInstalledProvider;
import 'hub_icon_cache.dart' show HubBundleIcon, hubIconCache;

/// 打开/安装一个小程序(市场行内按钮与详情页共用)。
///
/// 走 DiminaHost.open:未装 = manifest 首装,已装旧版 = 后台拉新包自动升级
/// (容器弹窗确认,Flutter 不做乐观推断)。成功后 touch 桌面 + 失效已装
/// 清单,让桌面/市场按真实状态重查。必须走固定端口反代:原生容器拿到 URL
/// 后才发请求,动态隧道端口可能已被重连换掉。
Future<bool> openHubApp(
  BuildContext context,
  WidgetRef ref, {
  required String appId,
  required String name,
  String? iconKey,
  String? iconUrl,
  int? versionCode,
  bool dark = false,
  bool autoSync = false,
}) async {
  final Color iconColor = Theme.of(context).colorScheme.primary;
  final Uint8List? bundlePng =
      await hubIconCache.load(appId, versionCode, iconUrl);
  final bool ok = await DiminaHost.open(
    appId: appId,
    name: name,
    dark: dark,
    iconKey: iconKey,
    iconColor: iconColor,
    iconPng: bundlePng,
    updateManifestUrl: '$appHubProxyBase/apps/$appId/manifest.json',
    // 升级全自动(2026-11-11):一律跳过容器「发现新版本」确认弹窗。
    autoUpdate: true,
  );
  if (ok) {
    ref.read(hubLayoutProvider.notifier).touch('mini:$appId');
    // 打开即消费该 app 的全部未读(主流惯例:角标随打开消,§6.1)。
    consumeMiniAppNotices(ref, appId);
    // 桌面的已装清单是另一个 provider(带缓存):装/升后让它重查,否则
    // 重装的图标不回桌面。落沙盒需要一点时间,稍后再复核一次。
    ref.invalidate(hubInstalledProvider);
    Timer(const Duration(seconds: 6), () => ref.invalidate(hubInstalledProvider));
  }
  return ok;
}

/// 列表行带来的摘要(市场页已有数据,进页面先渲染,详情再异步补全)。
class HubAppRef {
  const HubAppRef({
    required this.appId,
    required this.name,
    this.description = '',
    this.category = '',
    this.changelog = '',
    this.iconKey,
    this.iconUrl,
    this.versionCode,
    this.versionName = '',
    this.autoSync = false,
    this.permissions = HubAppPermissions.empty,
  });

  final String appId;
  final String name;
  final String description;
  final String category;
  final String changelog;
  final String? iconKey;
  final String? iconUrl;
  final int? versionCode;
  final String versionName;

  /// autoSync 静默同步(bundle.json 顶层字段,缺省 false)。
  final bool autoSync;

  /// 权限声明(市场列表行新形态,契约 v1 §5;详情端点旧形态兜底,取并集)。
  final HubAppPermissions permissions;
}

/// 详情接口(`/api/v1/apps/<appId>`)的完整数据。
class _HubAppDetail {
  _HubAppDetail.fromJson(Map<String, Object?> json)
      : subtitle = json['subtitle'] as String? ?? '',
        developer = json['developer'] as String? ?? '',
        description = json['description'] as String? ?? '',
        category = json['category'] as String? ?? '',
        language = json['language'] as String? ?? '',
        compatibility = json['compatibility'] as String? ?? '',
        whatsNew = json['whatsNew'] as String? ?? '',
        collects = json['collects'] == true,
        changelog = json['changelog'] as String? ?? '',
        versionCode = (json['versionCode'] as num?)?.toInt(),
        versionName = json['versionName'] as String? ?? '',
        updatedAt = json['updatedAt'] as String?,
        sizeBytes = (json['sizeBytes'] as num?)?.toInt(),
        keywords = [
          for (final dynamic k in json['keywords'] as List<dynamic>? ?? <dynamic>[])
            if (k is String && k.isNotEmpty) k,
        ],
        permissions = HubAppPermissions.fromJson(json['permissions']),
        screenshots = [
          for (final dynamic s in json['screenshots'] as List<dynamic>? ?? <dynamic>[])
            if (s is String && s.isNotEmpty) s,
        ];

  final String subtitle;
  final String developer;
  final String description;
  final String category;
  final String language;
  final String compatibility;
  final String whatsNew;
  final bool collects;
  final String changelog;
  final int? versionCode;
  final String versionName;
  final String? updatedAt;
  final int? sizeBytes;
  final List<String> keywords;
  final HubAppPermissions permissions;
  final List<String> screenshots;
}

/// 版本历史接口的一行。
class _HubAppVersion {
  _HubAppVersion.fromJson(Map<String, Object?> json)
      : versionCode = (json['versionCode'] as num?)?.toInt(),
        versionName = json['versionName'] as String? ?? '',
        changelog = json['changelog'] as String? ?? '',
        sizeBytes = (json['sizeBytes'] as num?)?.toInt(),
        createdAt = DateTime.tryParse(json['createdAt'] as String? ?? '');

  final int? versionCode;
  final String versionName;
  final String changelog;
  final int? sizeBytes;
  final DateTime? createdAt;
}

/// 权限 key → 展示图标(线性风格,与自带应用一致)。key=wx 口径 scope 串
/// (契约 §4 映射表);旧数据的简称 key 一并兼容。
IconData _permissionIcon(String key) => switch (key) {
      'scope.record' || 'record' || 'microphone' => Icons.mic_none_outlined,
      'scope.notification' || 'notifications' => Icons.notifications_none_outlined,
      'scope.contacts' => Icons.contacts_outlined,
      'scope.camera' || 'camera' => Icons.photo_camera_outlined,
      'scope.writePhotosAlbum' => Icons.photo_outlined,
      'scope.bluetooth' => Icons.bluetooth_outlined,
      'scope.clipboard' => Icons.content_paste_outlined,
      'scope.userLocation' || 'location' => Icons.location_on_outlined,
      'network' || 'network.external' => Icons.public_outlined,
      'storage' => Icons.save_outlined,
      'audio' => Icons.music_note_outlined,
      _ => Icons.extension_outlined,
    };

class ApphubAppDetailPage extends ConsumerStatefulWidget {
  const ApphubAppDetailPage({super.key, required this.app});

  final HubAppRef app;

  @override
  ConsumerState<ApphubAppDetailPage> createState() => _ApphubAppDetailPageState();
}

class _ApphubAppDetailPageState extends ConsumerState<ApphubAppDetailPage>
    with WidgetsBindingObserver {
  _HubAppDetail? _detail;
  List<_HubAppVersion> _versions = const <_HubAppVersion>[];
  Map<String, Object?>? _installed;
  bool _detailFailed = false;
  bool _opening = false;
  bool _descExpanded = false;
  StreamSubscription<DiminaUpdateEvent>? _updateSub;

  // 授权级 scope 的容器 consent(契约 v1 §7:开关状态数据源=容器,不是市场数据)。
  // scope → granted;_consentSupported=false = 容器侧 store 不可用(旧 dimina
  // 依赖),开关降级成只读声明展示。null=还没查到,开关先禁用防误显。
  Map<String, bool> _consent = const <String, bool>{};
  bool? _consentSupported;

  // 截图 bytes 的会话级内存缓存:详情页重进不重复拉,不落盘(截图体量大,
  // 且服务端带 cache-control,重进场景少)。值是 in-flight/完成的 Future,
  // 并发构建同一路径时天然去重。
  final Map<String, Future<Uint8List?>> _shotCache = <String, Future<Uint8List?>>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _updateSub = DiminaHost.updateEvents.listen(_onUpdateEvent);
    unawaited(_refreshInstalled());
    unawaited(_load());
    unawaited(_loadConsent());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _updateSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从容器回来(授权弹窗/容器内设置可能改过 consent)按真实状态刷新开关。
    if (state == AppLifecycleState.resumed) unawaited(_loadConsent());
  }

  Future<void> _onUpdateEvent(DiminaUpdateEvent event) async {
    if (event.appId != widget.app.appId) return;
    await _refreshInstalled();
    if (mounted) setState(() {});
  }

  Future<void> _refreshInstalled() async {
    try {
      final Map<String, Object?>? state = await DiminaHost.installed(widget.app.appId);
      if (!mounted) return;
      setState(() => _installed = state);
    } catch (_) {
      // 查询失败保留旧值;视为未装处理。
    }
  }

  /// 权限声明的合并视图:市场列表行新形态(带 mode/network.domains)优先,
  /// 详情端点旧形态兜底——行里没带(老 server/无声明)时退回 detail 的 scopes。
  HubAppPermissions get _permData {
    final HubAppPermissions row = widget.app.permissions;
    final HubAppPermissions detail = _detail?.permissions ?? HubAppPermissions.empty;
    if (row.scopes.isEmpty && row.networkDomains.isEmpty) return detail;
    final Set<String> rowKeys = <String>{
      for (final HubAppPermission p in row.scopes) p.key,
    };
    return HubAppPermissions(
      scopes: <HubAppPermission>[
        ...row.scopes,
        for (final HubAppPermission p in detail.scopes)
          if (!rowKeys.contains(p.key)) p,
      ],
      networkDomains: row.networkDomains,
    );
  }

  /// 拉容器 consent(经 dsh/dimina → DiminaPlugin → 容器 store):授权级开关
  /// 的事实来源。通道不可用/容器旧版没有 store → supported=false,UI 降级只读。
  Future<void> _loadConsent() async {
    try {
      final Map<String, Object?>? state = await DiminaHost.permissionState(widget.app.appId);
      if (!mounted) return;
      setState(() {
        _consentSupported = state?['supported'] == true;
        _consent = <String, bool>{
          for (final MapEntry<Object?, Object?> entry
              in (state?['scopes'] as Map? ?? const <Object?, Object?>{}).entries)
            if (entry.value is bool) '${entry.key}': entry.value as bool,
        };
      });
    } catch (_) {
      if (mounted) setState(() => _consentSupported = false);
    }
  }

  /// 授权级开关:乐观置位 → 写容器 consent;写失败回滚并提示,不假装成功。
  Future<void> _toggleConsent(HubAppPermission p, bool granted) async {
    final bool prev = _consent[p.key] ?? false;
    setState(() => _consent = <String, bool>{..._consent, p.key: granted});
    final bool ok = await DiminaHost.setPermission(widget.app.appId, p.key, granted);
    if (!mounted) return;
    if (!ok) {
      setState(() => _consent = <String, bool>{..._consent, p.key: prev});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.apphubPermissionSaveFailed)),
      );
    }
  }

  Future<void> _load() async {
    try {
      final http.Response detail = await http
          .get(Uri.parse('$appHubBase/api/v1/apps/${widget.app.appId}'))
          .timeout(const Duration(seconds: 8));
      final Object? body = jsonDecode(utf8.decode(detail.bodyBytes));
      if (body is! Map<String, Object?>) throw StateError('bad body');
      if (!mounted) return;
      setState(() {
        _detail = _HubAppDetail.fromJson(body);
        _detailFailed = false;
      });
    } catch (_) {
      if (mounted) setState(() => _detailFailed = true);
    }
    try {
      final http.Response versions = await http
          .get(Uri.parse('$appHubBase/api/v1/apps/${widget.app.appId}/versions'))
          .timeout(const Duration(seconds: 8));
      final Object? body = jsonDecode(utf8.decode(versions.bodyBytes));
      if (body is Map && body['versions'] is List) {
        _versions = <_HubAppVersion>[
          for (final dynamic v in body['versions'] as List<dynamic>)
            if (v is Map<String, Object?>) _HubAppVersion.fromJson(v),
        ];
        if (mounted) setState(() {});
      }
    } catch (_) {
      // 版本历史拉不到就不渲染该区块。
    }
  }

  bool get _isInstalled => _installed?['installed'] == true;

  bool get _hasUpdate {
    if (!_isInstalled) return false;
    final int? local = (_installed?['versionCode'] as num?)?.toInt();
    final int? market = _detail?.versionCode ?? widget.app.versionCode;
    return local != null && market != null && market > local;
  }

  Future<void> _open() async {
    if (_opening) return;
    setState(() => _opening = true);
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    try {
      final bool ok = await openHubApp(
        context,
        ref,
        appId: widget.app.appId,
        name: widget.app.name,
        iconKey: widget.app.iconKey,
        iconUrl: widget.app.iconUrl,
        versionCode: _detail?.versionCode ?? widget.app.versionCode,
        dark: dark,
      );
      if (ok && mounted) {
        setState(() => _installed = <String, Object?>{
              ...?_installed,
              'installed': true,
            });
        // 首装/升级落沙盒需要一点时间,稍后刷新真实已装版本。
        Timer(const Duration(seconds: 6), () => unawaited(_refreshInstalled()));
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<void> _uninstall() async {
    // 整包卸载语义(规范 §6):弹窗新文案 + 「同时清除主机数据」勾选;
    // 编排 = 先主机 remove(引擎终端通道,停后端/反注册)后本机卸载,
    // 主机不可达降级仅本机(提示条),已装清单在编排里失效重查。
    final bool localOk = await showAndRunAppUninstall(
      context,
      ref,
      appId: widget.app.appId,
      name: widget.app.name,
    );
    if (!localOk || !mounted) return;
    ref.invalidate(hubInstalledProvider);
    setState(() => _installed = <String, Object?>{'installed': false});
  }

  @override
  Widget build(BuildContext context) {
    final L10n l10n = context.l10n;
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.app.name),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: l10n.apphubUninstall,
            onPressed: () => unawaited(_uninstall()),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _header(theme, l10n),
            if (_detailFailed && _detail == null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        l10n.apphubNoMarket,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    TextButton(
                      onPressed: () => unawaited(_load()),
                      child: Text(l10n.commonRetry),
                    ),
                  ],
                ),
              ),
            if ((_detail?.screenshots.isNotEmpty ?? false))
              _screenshots(theme),
            _section(
              theme,
              title: l10n.apphubSectionAbout,
              child: _about(theme, l10n),
              show: (_detail?.description.isNotEmpty ?? widget.app.description.isNotEmpty),
            ),
            _section(
              theme,
              title: l10n.apphubSectionWhatsNew,
              headerExtra: _whatsNewVersionLine(theme),
              child: _whatsNewBody(theme),
              show: _hasWhatsNew,
            ),
            _section(
              theme,
              title: l10n.apphubSectionInfo,
              child: _infoCard(theme, l10n),
              show: true,
            ),
            _section(
              theme,
              title: l10n.apphubSectionPermissions,
              child: _permissions(theme, l10n),
              show: !(_detail?.collects ?? false) || _permData.isNotEmpty,
            ),
            _section(
              theme,
              title: l10n.apphubSectionVersions,
              child: _versionHistory(theme, l10n),
              show: _versions.isNotEmpty,
            ),
          ],
        ),
      ),
    );
  }

  // ---- 头部:图标 + 名称/副标题 + 获取/打开 + 元信息行 -----------------------

  Widget _header(ThemeData theme, L10n l10n) {
    final String subtitle = _detail?.subtitle ?? '';
    final String category = _detail?.category.isNotEmpty ?? false
        ? _detail!.category
        : widget.app.category;
    final String developer = _detail?.developer ?? '';
    final bool collects = _detail?.collects ?? false;
    final List<String> meta = <String>[
      l10n.apphubKindMiniProgram,
      if (category.isNotEmpty) category,
      if (developer.isNotEmpty) developer,
      if (!collects && _detail != null) l10n.apphubPrivacyNone,
    ];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        HubBundleIcon(
          appId: widget.app.appId,
          versionCode: _detail?.versionCode ?? widget.app.versionCode,
          url: widget.app.iconUrl,
          size: 88,
          fallback: hubAppHasIcon(widget.app.iconKey)
              ? HubAppIcon(iconKey: widget.app.iconKey, size: 88)
              : Container(
                  width: 88,
                  height: 88,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(22),
                  ),
                  child: Icon(Icons.apps_outlined, size: 40),
                ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(widget.app.name, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
              if (subtitle.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(height: 1.3),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(96, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 22),
                    textStyle: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  onPressed: _opening ? null : () => unawaited(_open()),
                  child: _opening
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(_isInstalled
                          ? (_hasUpdate ? l10n.apphubUpdate : l10n.apphubOpen)
                          : l10n.apphubGet),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  meta.join(' · '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ---- 截图轮播 ------------------------------------------------------------

  Widget _screenshots(ThemeData theme) {
    final List<String> shots = _detail?.screenshots ?? const <String>[];
    return SizedBox(
      height: 424,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 16),
        scrollDirection: Axis.horizontal,
        itemCount: shots.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (BuildContext context, int i) => _ShotImage(
          url: shots[i],
          cache: _shotCache,
          borderRadius: BorderRadius.circular(16),
        ),
      ),
    );
  }

  // ---- 简介 ----------------------------------------------------------------

  Widget _about(ThemeData theme, L10n l10n) {
    final String desc =
        (_detail?.description.isNotEmpty ?? false) ? _detail!.description : widget.app.description;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          desc,
          maxLines: _descExpanded ? null : 4,
          overflow: _descExpanded ? TextOverflow.visible : TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
        ),
        if (desc.length > 90)
          TextButton(
            style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 0)),
            onPressed: () => setState(() => _descExpanded = !_descExpanded),
            child: Text(_descExpanded ? l10n.apphubCollapse : l10n.apphubMore),
          ),
      ],
    );
  }

  bool get _hasWhatsNew {
    final String body = (_detail?.whatsNew.isNotEmpty ?? false)
        ? _detail!.whatsNew
        : (_detail?.changelog.isNotEmpty ?? false)
            ? _detail!.changelog
            : widget.app.changelog;
    return body.isNotEmpty;
  }

  Widget? _whatsNewVersionLine(ThemeData theme) {
    final String name = _detail?.versionName.isNotEmpty ?? false
        ? _detail!.versionName
        : widget.app.versionName;
    if (name.isEmpty && _detail?.versionCode == null) return null;
    return Text(
      '${context.l10n.apphubVersionPrefix} $name'
      '${(_detail?.versionCode != null) ? ' (${_detail!.versionCode})' : ''}',
      style: theme.textTheme.bodySmall,
    );
  }

  Widget _whatsNewBody(ThemeData theme) {
    final String body = (_detail?.whatsNew.isNotEmpty ?? false)
        ? _detail!.whatsNew
        : (_detail?.changelog.isNotEmpty ?? false)
            ? _detail!.changelog
            : widget.app.changelog;
    return Text(body, style: theme.textTheme.bodyMedium?.copyWith(height: 1.5));
  }

  // ---- 信息表 ---------------------------------------------------------------

  Widget _infoCard(ThemeData theme, L10n l10n) {
    final String date = _detail?.updatedAt != null
        ? _isoDate(_detail!.updatedAt!)
        : '';
    final String size = (_detail?.sizeBytes != null) ? _fmtSize(_detail!.sizeBytes!) : '';
    final String version = (_detail?.versionName.isNotEmpty ?? false)
        ? '${_detail!.versionName}'
            '${(_detail?.versionCode != null) ? ' (${_detail!.versionCode})' : ''}'
        : (widget.app.versionName.isNotEmpty ? widget.app.versionName : '');
    final List<(String, String)> rows = <(String, String)>[
      if ((_detail?.category.isNotEmpty ?? false) || widget.app.category.isNotEmpty)
        (l10n.apphubInfoCategory, _detail?.category.isNotEmpty ?? false ? _detail!.category : widget.app.category),
      if (size.isNotEmpty) (l10n.apphubInfoSize, size),
      if (_detail?.compatibility.isNotEmpty ?? false) (l10n.apphubInfoCompatibility, _detail!.compatibility),
      if (version.trim().isNotEmpty) (l10n.apphubInfoVersion, version.trim()),
      if (date.isNotEmpty) (l10n.apphubInfoUpdated, date),
      if (_detail?.developer.isNotEmpty ?? false) (l10n.apphubInfoDeveloper, _detail!.developer),
      if (_detail?.language.isNotEmpty ?? false) (l10n.apphubInfoLanguage, _detail!.language),
    ];
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: <Widget>[
          for (int i = 0; i < rows.length; i++)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                border: i == 0
                    ? null
                    : Border(top: BorderSide(color: theme.dividerColor.withValues(alpha: 0.3))),
              ),
              child: Row(
                children: <Widget>[
                  Text(rows[i].$1, style: theme.textTheme.bodyMedium?.copyWith(height: 1)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      rows[i].$2,
                      textAlign: TextAlign.right,
                      style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600, height: 1.3),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // ---- 权限与隐私 ------------------------------------------------------------
  //
  // 契约 v1 §7:授权级 scope=名称+说明+开关(容器 consent 置位,经 dsh/dimina
  // 通道写容器 store);声明级/占位级=只读 chip(已声明),占位级置灰;外网
  // 域名白名单=只读展示。容器 store 不可用(旧 dimina 依赖)时授权级同样降级
  // 成只读——没有可写的 consent 就不摆一个永远关不掉的开关骗人。

  Widget _permissions(ThemeData theme, L10n l10n) {
    final bool collects = _detail?.collects ?? false;
    final HubAppPermissions perms = _permData;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (!collects)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: <Widget>[
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: const Color(0xFF3E9E5B),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: const Icon(Icons.shield_outlined, color: Colors.white, size: 19),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(l10n.apphubPrivacyNone, style: theme.textTheme.titleSmall),
                      Text(
                        l10n.apphubPrivacyNoneBody,
                        style: theme.textTheme.bodySmall?.copyWith(height: 1.35),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        for (final HubAppPermission p in perms.scopes)
          if (p.authLevel) _authScopeRow(theme, l10n, p) else _declaredScopeRow(theme, l10n, p),
        if (perms.networkDomains.isNotEmpty)
          _domainsRow(theme, l10n, perms.networkDomains),
      ],
    );
  }

  /// 授权级行:名称+说明+consent 开关。consent 未查到(null)先禁用开关防
  /// 「闪一下全关」;容器 store 不可用(false)→ 降级成只读声明 chip。
  Widget _authScopeRow(ThemeData theme, L10n l10n, HubAppPermission p) {
    if (_consentSupported == false) return _declaredScopeRow(theme, l10n, p);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _permissionLeading(theme, _permissionIcon(p.key)),
          const SizedBox(width: 11),
          Expanded(child: _permissionTitles(theme, p)),
          Switch(
            value: _consent[p.key] ?? false,
            onChanged: _consentSupported == null
                ? null
                : (bool granted) => unawaited(_toggleConsent(p, granted)),
          ),
        ],
      ),
    );
  }

  /// 声明级/占位级行:只读「已声明」chip;占位级(契约 §1:v1 容器诚实 fail)置灰。
  Widget _declaredScopeRow(ThemeData theme, L10n l10n, HubAppPermission p) {
    final bool muted = p.placeholderLevel;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _permissionLeading(theme, _permissionIcon(p.key), muted: muted),
          const SizedBox(width: 11),
          Expanded(child: _permissionTitles(theme, p, muted: muted)),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: muted
                  ? Colors.transparent
                  : theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(999),
              border: muted
                  ? Border.all(color: theme.colorScheme.outline.withValues(alpha: 0.4))
                  : null,
            ),
            child: Text(
              l10n.apphubPermissionDeclared,
              style: theme.textTheme.labelSmall?.copyWith(
                color: muted ? theme.colorScheme.outline : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 外网域名白名单(契约 §2/§5):声明级只读展示,一行一个域名。
  Widget _domainsRow(ThemeData theme, L10n l10n, List<String> domains) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _permissionLeading(theme, Icons.public_outlined),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(l10n.apphubPermissionDomains, style: theme.textTheme.titleSmall),
                for (final String domain in domains)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      domain,
                      style: theme.textTheme.bodySmall?.copyWith(height: 1.35),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _permissionLeading(ThemeData theme, IconData icon, {bool muted = false}) {
    return Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        color: muted
            ? theme.colorScheme.surfaceContainerHighest
            : theme.colorScheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(
        icon,
        color: muted ? theme.colorScheme.outline : theme.colorScheme.primary,
        size: 17,
      ),
    );
  }

  Widget _permissionTitles(ThemeData theme, HubAppPermission p, {bool muted = false}) {
    final TextStyle? titleStyle =
        muted ? theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.outline) : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(p.title.isEmpty ? p.key : p.title, style: titleStyle ?? theme.textTheme.titleSmall),
        if (p.usage.isNotEmpty)
          Text(p.usage, style: theme.textTheme.bodySmall?.copyWith(height: 1.35)),
      ],
    );
  }

  // ---- 版本历史 ---------------------------------------------------------------

  Widget _versionHistory(ThemeData theme, L10n l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (int i = 0; i < _versions.length; i++)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              border: i == 0
                  ? null
                  : Border(top: BorderSide(color: theme.dividerColor.withValues(alpha: 0.3))),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: <Widget>[
                    Text(
                      '${_versions[i].versionName}'
                      '${(_versions[i].versionCode != null) ? ' (${_versions[i].versionCode})' : ''}',
                      style: theme.textTheme.titleSmall,
                    ),
                    if (_versions[i].createdAt != null)
                      Text(
                        _isoDate(_versions[i].createdAt!.toIso8601String()),
                        style: theme.textTheme.bodySmall,
                      ),
                  ],
                ),
                if (_versions[i].changelog.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      _versions[i].changelog,
                      style: theme.textTheme.bodySmall?.copyWith(height: 1.4),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  // ---- 通用区块骨架 ------------------------------------------------------------

  Widget _section(
    ThemeData theme, {
    required String title,
    required Widget child,
    required bool show,
    Widget? headerExtra,
  }) {
    if (!show) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: <Widget>[
              Text(title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              ?headerExtra,
            ],
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }

  String _isoDate(String iso) {
    final DateTime? dt = DateTime.tryParse(iso);
    if (dt == null) return iso;
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }

  String _fmtSize(int bytes) {
    const double mb = 1024 * 1024;
    if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
    final double kb = bytes / 1024;
    if (kb >= 1024) return '${(kb / 1024).toStringAsFixed(1)} MB';
    return '${kb.toStringAsFixed(0)} KB';
  }
}

/// 单张截图:内存缓存 + 失败占位(不阻塞轮播其它张)。
class _ShotImage extends StatelessWidget {
  const _ShotImage({
    required this.url,
    required this.cache,
    required this.borderRadius,
  });

  final String url;
  final Map<String, Future<Uint8List?>> cache;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ClipRRect(
      borderRadius: borderRadius,
      child: Container(
        width: 200,
        height: 424,
        color: theme.colorScheme.surfaceContainerHighest,
        child: FutureBuilder<Uint8List?>(
          future: cache.putIfAbsent(url, () => _fetchShot(url)),
          builder: (BuildContext context, AsyncSnapshot<Uint8List?> snapshot) {
            final Uint8List? bytes = snapshot.data;
            if (bytes == null) {
              return Center(
                child: Icon(Icons.image_outlined, size: 28, color: theme.colorScheme.outline),
              );
            }
            return Image.memory(bytes, fit: BoxFit.cover, alignment: Alignment.topCenter,
                filterQuality: FilterQuality.medium);
          },
        ),
      ),
    );
  }

  static Future<Uint8List?> _fetchShot(String url) async {
    try {
      final http.Response response =
          await http.get(Uri.parse(url)).timeout(const Duration(seconds: 12));
      return response.statusCode == 200 && response.bodyBytes.isNotEmpty
          ? response.bodyBytes
          : null;
    } catch (_) {
      return null;
    }
  }
}
