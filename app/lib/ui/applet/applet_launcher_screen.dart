/// The launcher: mini apps the active engine hosts under `~/dsh/apps/`.
/// Phase 1 lives on the engine page; a nicer surface comes with 阶段 3.
library;

import 'dart:async';
import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/connection_state.dart';
import '../../state/sessions_state.dart';
import 'applet_bridge.dart';
import 'applet_screen.dart';

/// One launchable app: its directory name and `app.json` name.
typedef AppletEntry = ({String id, String name});

class AppletLauncherScreen extends ConsumerStatefulWidget {
  const AppletLauncherScreen({super.key});

  @override
  ConsumerState<AppletLauncherScreen> createState() => _AppletLauncherScreenState();
}

class _AppletLauncherScreenState extends ConsumerState<AppletLauncherScreen> {
  late final Future<List<AppletEntry>> _apps = _loadApps();

  Future<List<AppletEntry>> _loadApps() async {
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
        apps.add((id: dir, name: name));
      } catch (_) {
        // A directory without a readable app.json is not an app; skip it.
      }
    }
    apps.sort((AppletEntry a, AppletEntry b) => a.name.compareTo(b.name));
    return apps;
  }

  @override
  Widget build(BuildContext context) {
    final L10n l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.appletEntry)),
      body: FutureBuilder<List<AppletEntry>>(
        future: _apps,
        builder: (BuildContext context, AsyncSnapshot<List<AppletEntry>> snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
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
          return ListView.builder(
            itemCount: apps.length,
            itemBuilder: (BuildContext context, int index) => ListTile(
              leading: const Icon(Icons.widgets_outlined),
              title: Text(apps[index].name),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => AppletScreen(appId: apps[index].id)),
              ),
            ),
          );
        },
      ),
    );
  }
}
