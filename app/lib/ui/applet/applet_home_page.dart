/// 小程序 tab: installed applets first (~/dsh/apps/ on the active host), then
/// every hub feature — one tile language, one grid, no nesting. The end state
/// is that hub features become applets themselves; until then they share the
/// grid.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/connection_state.dart';
import '../../state/sessions_state.dart';
import '../features/all_features_page.dart' show dshWebOpenerProvider;
import '../features/feature_catalog.dart';
import '../theme/app_icons.dart';
import '../web/web_target.dart';
import 'applet_bridge.dart';
import 'applet_screen.dart';

/// One grid tile, however it is backed.
sealed class _Tile {
  const _Tile();
}

/// An installed applet: opens the container.
class _AppletTileData extends _Tile {
  const _AppletTileData(this.id, this.name, this.icon, this.iconPng);

  final String id;
  final String name;
  final String icon; // glyph name from the app's whitelist, or an emoji
  final Uint8List? iconPng;
}

/// A hub feature: same behavior as its tile in 全部功能.
class _FeatureTileData extends _Tile {
  const _FeatureTileData(this.item);

  final FeatureItem item;
}

/// Applet icon names that map into the app's own glyph system (AppIcons);
/// anything else renders as the emoji it is. icon.png always wins.
final Map<String, IconData> _appletGlyphs = <String, IconData>{
  'balance': AppIcons.balance,
  'wallet': AppIcons.balance,
  'book': AppIcons.skill,
  'chart': AppIcons.chart,
};

class _AppletHomePageState extends ConsumerState<AppletHomePage> {
  late Future<List<_Tile>> _tiles = _loadTiles();

  Future<List<_Tile>> _reload() async {
    final List<_Tile> tiles = await _loadTiles();
    if (mounted) setState(() => _tiles = Future.value(tiles));
    return tiles;
  }

  Future<List<_Tile>> _loadTiles() async {
    final List<_Tile> tiles = <_Tile>[];
    final DshClient? client = ref.read(activeConnectionProvider).value?.client;
    final String sessionId = ref.read(currentSessionProvider) ?? 'applet';
    if (client != null) {
      final DshAppletTransport transport =
          DshAppletTransport(client: client, sessionId: sessionId);
      try {
        final String home = await transport.engineHome();
        final String appsRoot = '$home/dsh/apps';
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
              // icon.png is optional.
            }
            final String rawIcon =
                appJson is Map && appJson['icon'] is String ? appJson['icon'] as String : '🧩';
            tiles.add(_AppletTileData(
              dir,
              appJson is Map && appJson['name'] is String ? appJson['name'] as String : dir,
              rawIcon,
              iconPng,
            ));
          } catch (_) {
            // A directory without a readable app.json is not an app; skip it.
          }
        }
      } catch (_) {
        // Host unreachable: the hub tiles below still render.
      }
    }
    for (final FeatureSection section in featureSections) {
      for (final FeatureItem item in section.items) {
        tiles.add(_FeatureTileData(item));
      }
    }
    return tiles;
  }

  void _openTile(_Tile tile) {
    final String sessionId = ref.read(currentSessionProvider) ?? 'applet';
    switch (tile) {
      case _AppletTileData(:final id):
        Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => AppletScreen(appId: id)),
        );
      case _FeatureTileData(:final item):
        if (item.native case final Widget Function(String) build) {
          Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => build(sessionId)),
          );
        } else if (item.webFor(sessionId) case final DshWebTarget target?) {
          ref.read(dshWebOpenerProvider)(context, ref, target);
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final L10n l10n = context.l10n;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: RefreshIndicator(
        onRefresh: _reload,
        child: FutureBuilder<List<_Tile>>(
          future: _tiles,
          builder: (BuildContext context, AsyncSnapshot<List<_Tile>> snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            final List<_Tile> tiles = snapshot.data ?? const <_Tile>[];
            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: <Widget>[
                if (tiles.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 48),
                    child: Text(
                      l10n.appletEmpty,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  )
                else
                  GridView.count(
                    crossAxisCount: 4,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    childAspectRatio: 0.82,
                    children: <Widget>[
                      for (final _Tile tile in tiles) _GridTile(tile: tile, onOpen: _openTile),
                    ],
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _GridTile extends StatelessWidget {
  const _GridTile({required this.tile, required this.onOpen});

  final _Tile tile;
  final void Function(_Tile) onOpen;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final (Widget iconWidget, String label) = switch (tile) {
      _AppletTileData(:final icon, :final iconPng, :final name) => (
          iconPng != null
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.memory(iconPng, width: 48, height: 48, fit: BoxFit.contain),
                )
              : _appletGlyphs.containsKey(icon)
                  ? Icon(_appletGlyphs[icon], size: 28, color: colors.primary)
                  : Text(icon, style: const TextStyle(fontSize: 28)),
          name,
        ),
      _FeatureTileData(:final item) => (
          Icon(item.icon, size: 28, color: colors.primary),
          item.title,
        ),
    };
    return InkWell(
      onTap: () => onOpen(tile),
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: colors.surfaceContainerHighest.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(14),
              ),
              alignment: Alignment.center,
              child: iconWidget,
            ),
            const SizedBox(height: 6),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class AppletHomePage extends ConsumerStatefulWidget {
  const AppletHomePage({super.key});

  @override
  ConsumerState<AppletHomePage> createState() => _AppletHomePageState();
}
