// `dshgo://mini/<appId>?path=<页路径>`:跳进一个 AppHub 小程序(Dimina)的
// 指定页。助手回复里的小程序跳转卡片(ui/chat/render/mini_app_card.dart)与
// 纯链接写法都经 [openReplyMiniLink] 交路由;来自 App 外部的链接照常由
// [LinkHost] 送进同一条路。
//
// 应用按「桌面同款配方」拉起:目录快照取名字/图标,未装=首装,已装旧版=
// 后台拉新包,打开成功消费该 app 的未读。目录里查不到的应用回 false,由
// 调用方提示「无法打开」。

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../notify/apphub_proxy.dart' show appHubProxyBase;
import '../state/apphub_notices_state.dart'
    show appHubAppNamesProvider, appHubNoticesProvider, consumeMiniAppNoticesBy;
import '../state/notify_state.dart' show notifyChannelProvider;
import '../ui/applet/dimina/dimina_host.dart';
import '../ui/applet/hub_apps_group.dart' show HubInstalledApp, hubInstalledProvider;
import '../ui/applet/hub_icon_cache.dart' show hubIconCache;
import 'app_links.dart' show LinkRouter, appLinkScheme, linkRouterProvider;

/// The host of mini program links: `dshgo://mini/<appId>`.
const miniAppLinkHost = 'mini';

/// 一个小程序跳转:appId 必有;path 为空进容器首页。
class MiniAppLink {
  const MiniAppLink({required this.appId, this.path});

  final String appId;
  final String? path;
}

/// [uri] 是 `dshgo://mini/<appId>?path=<页路径>` 时返回跳转,否则 null。
/// appId 占一个路径段(字母数字开头,不含 `/`);path 可带自己的 query,
/// 页路径交给容器解释,这里不校验形状。
MiniAppLink? miniAppLink(Uri uri) {
  if (uri.scheme.toLowerCase() != appLinkScheme || uri.host.toLowerCase() != miniAppLinkHost) return null;
  if (uri.userInfo.isNotEmpty || uri.hasPort || uri.hasFragment) return null;
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segments.length != 1) return null;
  final appId = segments.single;
  if (appId.length > 64 || !RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]*$').hasMatch(appId)) return null;
  final path = uri.queryParameters['path'];
  return MiniAppLink(appId: appId, path: (path == null || path.isEmpty) ? null : path);
}

/// 拉起一个小程序(卡片点按与链接路由共用)。
typedef MiniAppOpener = Future<bool> Function(BuildContext context, String appId, String? path);

/// 桌面同款配方拉起小程序:目录快照优先(名字/图标/版本),快照未落定或
/// 查不到再问市场名单,都没有也能开(名字落 appId,图标落字母瓦片)。
/// 打开成功消费该 app 的全部未读并让桌面清单复核(可能刚首装/升级)。
/// 原生打不开(容器报错、appId 无人认领)回 false。
Future<bool> openMiniApp(BuildContext context, String appId, String? path) async {
  final ProviderContainer container = ProviderScope.containerOf(context, listen: false);
  // async gap 前取齐主题值,免 BuildContext 跨 await(桌面同款纪律)。
  final Color iconColor = Theme.of(context).colorScheme.primary;
  HubInstalledApp? app;
  for (final HubInstalledApp candidate in container.read(hubInstalledProvider).value ?? const <HubInstalledApp>[]) {
    if (candidate.appId == appId) {
      app = candidate;
      break;
    }
  }
  String name = app?.name ?? '';
  if (name.isEmpty) {
    try {
      name = (await container.read(appHubAppNamesProvider.future))[appId] ?? '';
    } catch (_) {
      name = ''; // 市场名单拉不到:名字落 appId,不挡跳转。
    }
  }
  final Uint8List? bundlePng =
      app == null ? null : await hubIconCache.load(appId, app.installedVersionCode ?? app.marketVersionCode, app.iconUrl);
  final bool ok;
  try {
    ok = await DiminaHost.open(
      appId: appId,
      name: name.isNotEmpty ? name : appId,
      path: path,
      iconKey: app?.iconKey,
      iconColor: iconColor,
      iconPng: bundlePng,
      // 固定端口反代(与桌面/市场同款):未装 = 首装,已装 = 后台拉新包。
      updateManifestUrl: '$appHubProxyBase/apps/$appId/manifest.json',
      autoUpdate: true,
    );
  } catch (_) {
    return false;
  }
  if (ok) {
    consumeMiniAppNoticesBy(
      notices: container.read(appHubNoticesProvider.notifier),
      channel: container.read(notifyChannelProvider),
      appId: appId,
    );
    container.invalidate(hubInstalledProvider);
  }
  return ok;
}

/// Routes `dshgo://mini/…` to the opener. Returns the unregister function.
VoidCallback registerMiniLinks(LinkRouter router, {MiniAppOpener? opener}) =>
    router.registerLinkHandler(miniAppLinkHost, (uri) async {
      final MiniAppLink? link = miniAppLink(uri);
      final BuildContext? context = router.context;
      if (link == null || context == null || !context.mounted) return false;
      final MiniAppOpener open = opener ?? openMiniApp;
      return open(context, link.appId, link.path);
    });

/// A link tapped in a reply: when it is a mini program link (`dshgo://mini/…`),
/// hands it to the router and returns true. False for every other link.
bool openReplyMiniLink(BuildContext context, String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || uri.scheme.toLowerCase() != appLinkScheme || uri.host.toLowerCase() != miniAppLinkHost) {
    return false;
  }
  try {
    unawaited(ProviderScope.containerOf(context, listen: false).read(linkRouterProvider).open(uri));
  } catch (_) {
    // No provider scope above this text (a detached render): nothing to open.
  }
  return true;
}
