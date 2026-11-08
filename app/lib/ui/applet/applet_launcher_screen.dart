/// The launcher / mini-program market.
///
/// Two sections:
///  * 引擎侧单文件 HTML 应用(~/dsh/apps,契约 v1)—— WebView 容器打开;
///  * AppHub 小程序(Dimina 包)—— 列表来自 AppHub 市场,点按在原生 Dimina
///    容器打开(updateManifestUrl 兜底:未安装则首装,已装旧版则后台升级),
///    长按卸载(clearUserData,引擎侧业务库保留)。
///
/// AppHub base 是 loopback:仿真器经 `adb reverse tcp:7610`,真机经 ssh 隧道
/// 或(M4 后)HTTPS。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../notify/apphub_base.dart' show appHubBase;
import '../../state/connection_state.dart';
import '../../state/sessions_state.dart';
import 'applet_bridge.dart';
import 'applet_screen.dart';
import 'dimina/dimina_host.dart';

/// One launchable engine app: directory name, display name, container kind.
typedef AppletEntry = ({String id, String name, String runtime, String? manifestUrl});

/// One AppHub mini program as listed by the market.
typedef HubApp = ({String appId, String name, int? versionCode});

class AppletLauncherScreen extends ConsumerStatefulWidget {
  const AppletLauncherScreen({super.key});

  @override
  ConsumerState<AppletLauncherScreen> createState() => _AppletLauncherScreenState();
}

class _AppletLauncherScreenState extends ConsumerState<AppletLauncherScreen> {
  Future<List<AppletEntry>>? _engineApps;
  Future<List<HubApp>>? _hubApps;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _engineApps ??= _loadEngineApps();
    _hubApps ??= _loadHubApps();
  }

  Future<List<AppletEntry>> _loadEngineApps() async {
    final DshClient? client = ref.read(activeConnectionProvider).value?.client;
    if (client == null) return const <AppletEntry>[];
    final String sessionId = ref.read(currentSessionProvider) ?? 'applet';
    final DshAppletTransport transport =
        DshAppletTransport(client: client, sessionId: sessionId);
    final String home = await transport.engineHome();
    final String appsRoot = '$home/dsh/apps';
    final List<String> dirs = await transport.listDir(appsRoot);
    final List<AppletEntry> apps = <AppletEntry>[];
    for (final String dir in dirs) {
      try {
        final Object? appJson = jsonDecode(
          utf8.decode(
            await transport.readBytes('$appsRoot/$dir/app.json', maxBytes: 64 * 1024),
          ),
        );
        final String name = appJson is Map && appJson['name'] is String
            ? appJson['name'] as String
            : dir;
        // 契约 v2: runtime = html(默认,契约 v1) | dimina(原生容器,包在 AppHub)。
        final String runtime = appJson is Map && appJson['runtime'] is String
            ? appJson['runtime'] as String
            : 'html';
        final String? manifestUrl =
            appJson is Map && appJson['manifestUrl'] is String
                ? appJson['manifestUrl'] as String
                : null;
        apps.add((id: dir, name: name, runtime: runtime, manifestUrl: manifestUrl));
      } catch (_) {
        // A directory without a readable app.json is not an app; skip it.
      }
    }
    apps.sort((AppletEntry a, AppletEntry b) => a.name.compareTo(b.name));
    return apps;
  }

  /// AppHub market list; unreachable server → empty(section 整体隐藏)。
  Future<List<HubApp>> _loadHubApps() async {
    try {
      final HttpClient client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 3);
      final HttpClientResponse response =
          await client.getUrl(Uri.parse('$appHubBase/api/v1/apps')).then((r) => r.close());
      final Object? body = jsonDecode(await response.transform(utf8.decoder).join());
      client.close(force: false);
      if (body is! Map || body['apps'] is! List) return const <HubApp>[];
      return <HubApp>[
        for (final dynamic app in body['apps'] as List<dynamic>)
          if (app is Map)
            (
              appId: app['appId'] as String? ?? '',
              name: app['name'] as String? ?? '',
              versionCode: app['versionCode'] is int
                  ? app['versionCode'] as int
                  : int.tryParse('${app['versionCode']}'),
            ),
      ];
    } catch (_) {
      return const <HubApp>[];
    }
  }

  Future<void> _openHubApp(HubApp app) async {
    final bool ok = await DiminaHost.open(
      appId: app.appId,
      name: app.name.isEmpty ? app.appId : app.name,
      // Install-on-open: 无底包首装;已装旧版后台自动升级。
      updateManifestUrl: '$appHubBase/apps/${app.appId}/manifest.json',
    );
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('无法打开 ${app.name}(容器未就绪?)')),
      );
    }
  }

  Future<void> _confirmUninstall(HubApp app) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialog) => AlertDialog(
        title: Text('卸载 ${app.name}'),
        content: const Text('删除手机上的小程序包与本地数据;引擎侧业务数据库保留。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            child: const Text('卸载'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final bool done = await DiminaHost.uninstall(app.appId, clearUserData: true);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(done ? '已卸载 ${app.name}' : '卸载失败(可能未安装)')),
    );
    setState(() => _hubApps = _loadHubApps());
  }

  @override
  Widget build(BuildContext context) {
    final L10n l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.appletEntry)),
      body: ListView(
        children: <Widget>[
          FutureBuilder<List<HubApp>>(
            future: _hubApps,
            builder: (BuildContext context, AsyncSnapshot<List<HubApp>> snapshot) {
              final List<HubApp> apps = snapshot.data ?? const <HubApp>[];
              if (snapshot.connectionState != ConnectionState.done || apps.isEmpty) {
                return const SizedBox.shrink();
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text('AppHub 小程序', style: Theme.of(context).textTheme.titleSmall),
                  ),
                  for (final HubApp app in apps)
                    ListTile(
                      leading: const Icon(Icons.widgets),
                      title: Text(app.name.isEmpty ? app.appId : app.name),
                      subtitle: app.versionCode == null
                          ? null
                          : Text('v${app.versionCode} · 点按打开,长按卸载'),
                      onTap: () => _openHubApp(app),
                      onLongPress: () => _confirmUninstall(app),
                    ),
                  const Divider(height: 16),
                ],
              );
            },
          ),
          FutureBuilder<List<AppletEntry>>(
            future: _engineApps,
            builder: (BuildContext context, AsyncSnapshot<List<AppletEntry>> snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: CircularProgressIndicator(),
                  ),
                );
              }
              final List<AppletEntry> apps = snapshot.data ?? const <AppletEntry>[];
              if (apps.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      l10n.appletEmpty,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: Text('引擎 HTML 应用', style: Theme.of(context).textTheme.titleSmall),
                  ),
                  for (final AppletEntry app in apps)
                    ListTile(
                      leading: Icon(
                        app.runtime == 'dimina' ? Icons.widgets : Icons.code,
                      ),
                      title: Text(app.name),
                      subtitle: app.runtime == 'dimina' ? const Text('Dimina 原生容器') : null,
                      onTap: () async {
                        if (app.runtime == 'dimina') {
                          // 契约 v2: 包在 AppHub/远端 manifest,原生容器打开。
                          await DiminaHost.open(
                            appId: app.id,
                            name: app.name,
                            updateManifestUrl:
                                app.manifestUrl ?? '$appHubBase/apps/${app.id}/manifest.json',
                          );
                        } else {
                          if (!context.mounted) return;
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(builder: (_) => AppletScreen(appId: app.id)),
                          );
                        }
                      },
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
