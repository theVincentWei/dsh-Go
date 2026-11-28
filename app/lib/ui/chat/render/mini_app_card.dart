// 回复里的小程序跳转卡片(`<miniapp …>`):图标 + 应用名与「小程序」角标
// (主行)+ 页名副行,整卡可点,按 mini_links.dart 的桌面同款配方拉起。
//
// 旧版 App 不认识这个标签会原样显示文字;App 静默自动升级,升到即正常。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../../../l10n/l10n.dart';
import '../../../links/mini_links.dart' show MiniAppLink, miniAppLink, openMiniApp;
import '../../applet/hub_app_icon.dart' show HubAppIcon, hubAppHasIcon;
import '../../applet/hub_apps_group.dart' show HubInstalledApp, hubInstalledProvider;
import '../../applet/hub_icon_cache.dart' show HubBundleIcon;
import '../../theme/app_icons.dart' show AppIcons;

/// 一张小程序跳转卡片。缺 `app` 属性的标签画不出来(标记写错了,留空比
/// 画一张废卡诚实)。
class MiniAppCard extends ConsumerWidget {
  const MiniAppCard({super.key, required this.appId, this.path, this.title});

  final String appId;

  /// 页面路径;null 进容器首页。
  final String? path;

  /// 页名(卡片标题);缺省回落应用名,再落 appId。
  final String? title;

  /// The `miniapp` tag for gpt_markdown's HTML table. 属性:
  /// `app`(应用 appId,必有)、`title`(页名,应有)、`path`(页面路径,可省)。
  /// 属性拼不出合法跳转时画不出来——与链接解析([miniAppLink])同一道门。
  static Widget tag(BuildContext context, HtmlElementDetails element) {
    final MiniAppLink? link = miniAppLink(Uri(
      scheme: 'dshgo',
      host: 'mini',
      pathSegments: [element['app']?.trim() ?? ''],
      queryParameters: element.attributes.containsKey('path') ? {'path': element['path']!.trim()} : null,
    ));
    if (link == null) return const SizedBox.shrink();
    return MiniAppCard(appId: link.appId, path: link.path, title: element['title']?.trim());
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final TextStyle style = DefaultTextStyle.of(context).style;
    final double fontSize = style.fontSize ?? 16;
    final HubInstalledApp? app = ref
        .watch(hubInstalledProvider)
        .value
        ?.where((HubInstalledApp candidate) => candidate.appId == appId)
        .firstOrNull;
    final String appName = app?.name ?? '';
    final bool hasTitle = title?.isNotEmpty ?? false;
    // 主行 = 应用名(「小程序」角标跟着主行),副行 = 页名;应用不在目录时
    // 主行落页名,再落 appId,此时没有副行。
    final String heading = appName.isNotEmpty ? appName : (hasTitle ? title! : appId);
    final String? sub = hasTitle && title != heading ? title : null;

    return Semantics(
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _open(context),
        child: Container(
          margin: EdgeInsets.only(top: fontSize * 0.6, bottom: fontSize * 0.2),
          padding: EdgeInsets.symmetric(horizontal: fontSize * 0.7, vertical: fontSize * 0.6),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLow,
            border: Border.all(color: theme.colorScheme.outlineVariant, width: 0.5),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              HubBundleIcon(
                appId: appId,
                versionCode: app?.installedVersionCode ?? app?.marketVersionCode,
                url: app?.iconUrl,
                size: 42,
                fallback: hubAppHasIcon(app?.iconKey)
                    ? HubAppIcon(iconKey: app?.iconKey, size: 42)
                    : _letterTile(context, appName),
              ),
              SizedBox(width: fontSize * 0.7),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            heading,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: style.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ),
                        SizedBox(width: fontSize * 0.3),
                        _badge(context, style, fontSize),
                      ],
                    ),
                    if (sub != null) ...[
                      SizedBox(height: fontSize * 0.15),
                      Text(
                        sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: style.copyWith(
                          fontSize: fontSize * 0.8,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              SizedBox(width: fontSize * 0.3),
              Icon(AppIcons.disclosure, size: fontSize * 1.1, color: theme.colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }

  /// 目录里没图标时的兜底:应用名首字母瓦片(原生容器同款回落)。
  Widget _letterTile(BuildContext context, String name) {
    final ThemeData theme = Theme.of(context);
    final String letter = name.isEmpty ? '·' : name.characters.first.toUpperCase();
    return Container(
      width: 42,
      height: 42,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(42 * HubBundleIcon.cornerRadiusRatio),
      ),
      child: Text(
        letter,
        style: TextStyle(
          fontSize: 19,
          fontWeight: FontWeight.w600,
          color: theme.colorScheme.onPrimaryContainer,
        ),
      ),
    );
  }

  Widget _badge(BuildContext context, TextStyle style, double fontSize) {
    final ThemeData theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        context.l10n.chatMiniAppBadge,
        style: style.copyWith(
          fontSize: fontSize * 0.72,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context) async {
    final bool ok = await openMiniApp(context, appId, path);
    if (!ok && context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(context.l10n.stateLinkOpenFailed)),
      );
    }
  }
}
