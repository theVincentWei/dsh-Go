/// 小程序组的数据:已安装的 Applet(`~/dsh/apps/`),渲染样式(公共图标
/// 助手)供桌面(app_desktop)与别处共用。分组与排序已归桌面布局
/// (hub_layout_state),这里只提供「有哪些」与「长什么样」。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/connection_state.dart';
import '../../state/sessions_state.dart';
import '../theme/app_icons.dart';
import 'applet_bridge.dart';

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

/// 图标方块里的内容:icon.png 优先,字形映射次之,不认识的当 emoji。
/// 桌面瓷贴与将来的其他入口共用这一份,保证星河应用在哪都长一个样。
Widget appletIconWidget(AppletEntry app) {
  if (app.iconPng != null) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(11),
      child: Image.memory(app.iconPng!, width: 34, height: 34, fit: BoxFit.contain),
    );
  }
  if (_appletGlyphs.containsKey(app.icon)) {
    return Consumer(
      builder: (BuildContext context, WidgetRef ref, _) => Icon(
        _appletGlyphs[app.icon],
        size: 20,
        color: Theme.of(context).colorScheme.primary,
      ),
    );
  }
  return Text(app.icon, style: const TextStyle(fontSize: 18));
}
