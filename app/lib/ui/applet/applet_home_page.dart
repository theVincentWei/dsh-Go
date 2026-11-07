/// 小程序组:已安装的 Applet(`~/dsh/apps/`),渲染成和功能目录同一风格的
/// 图标瓷贴组,插在全部功能页最前。只加这一组,不碰页面原有的分区。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/connection_state.dart';
import '../../state/sessions_state.dart';
import '../common/app_sheet.dart' show groupTitleStyle;
import '../common/tile_grid.dart';
import '../theme/app_icons.dart';
import 'applet_bridge.dart';
import 'applet_screen.dart';

/// Applet 图标名映射进 App 自己的字形体系;不认识的当 emoji 渲染,icon.png 优先。
final Map<String, IconData> _appletGlyphs = <String, IconData>{
  'balance': AppIcons.balance,
  'wallet': AppIcons.balance,
  'book': AppIcons.skill,
  'chart': AppIcons.chart,
};

/// 一个已安装的 Applet。
typedef AppletEntry = ({String id, String name, String icon, Uint8List? iconPng});

final appletEntriesProvider = FutureProvider.autoDispose<List<AppletEntry>>((ref) async {
  final DshClient? client = ref.watch(activeConnectionProvider).value?.client;
  if (client == null) return const <AppletEntry>[];
  final String sessionId = ref.watch(currentSessionProvider) ?? 'applet';
  final DshAppletTransport transport =
      DshAppletTransport(client: client, sessionId: sessionId);
  final String home = await transport.engineHome();
  final String appsRoot = '$home/dsh/apps';
  final List<AppletEntry> apps = <AppletEntry>[];
  for (final String dir in await transport.listDir(appsRoot)) {
    try {
      final Object? appJson = jsonDecode(
        utf8.decode(
          await transport.readBytes('$appsRoot/$dir/app.json', maxBytes: 64 * 1024),
        ),
      );
      Uint8List? iconPng;
      try {
        iconPng = await transport.readBytes('$appsRoot/$dir/icon.png', maxBytes: 256 * 1024);
      } catch (_) {
        // icon.png 可选,缺了就用 app.json 的 icon 字段。
      }
      apps.add((
        id: dir,
        name: appJson is Map && appJson['name'] is String ? appJson['name'] as String : dir,
        icon: appJson is Map && appJson['icon'] is String ? appJson['icon'] as String : '🧩',
        iconPng: iconPng,
      ));
    } catch (_) {
      // 没有可读 app.json 的目录不是 App,跳过。
    }
  }
  return apps;
});

/// 已安装 Applet 的图标瓷贴组:分组标签 + 4 列网格,与功能目录同款。
class AppletGroup extends ConsumerWidget {
  const AppletGroup({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FutureBuilder<List<AppletEntry>>(
      future: ref.watch(appletEntriesProvider.future),
      builder: (BuildContext context, AsyncSnapshot<List<AppletEntry>> snapshot) {
        final List<AppletEntry> apps = snapshot.data ?? const <AppletEntry>[];
        if (apps.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('小程序', style: groupTitleStyle(context)),
            TileGrid(
              columns: 4,
              spacing: 16,
              children: <Widget>[
                for (final AppletEntry app in apps)
                  _AppletTile(
                    app: app,
                    onOpen: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(builder: (_) => AppletScreen(appId: app.id)),
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

class _AppletTile extends StatelessWidget {
  const _AppletTile({required this.app, required this.onOpen});

  final AppletEntry app;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Widget icon = app.iconPng != null
        ? ClipRRect(
            borderRadius: BorderRadius.circular(11),
            child: Image.memory(app.iconPng!, width: 34, height: 34, fit: BoxFit.contain),
          )
        : _appletGlyphs.containsKey(app.icon)
            ? Icon(_appletGlyphs[app.icon], size: 20, color: scheme.primary)
            : Text(app.icon, style: const TextStyle(fontSize: 18));
    return Semantics(
      button: true,
      label: app.name,
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(14),
        child: Column(
          children: <Widget>[
            SizedBox.square(
              dimension: 46,
              child: DecoratedBox(
                decoration: ShapeDecoration(
                  color: scheme.primary.withValues(
                    alpha: scheme.brightness == Brightness.dark ? 0.16 : 0.10,
                  ),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: Center(child: icon),
              ),
            ),
            const SizedBox(height: 5),
            Text(
              app.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
      ),
    );
  }
}
