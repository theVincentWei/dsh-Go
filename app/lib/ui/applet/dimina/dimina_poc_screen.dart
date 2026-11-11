/// M0 POC: drives the Dimina container through the three manifest chains —
/// bundled open (with background upgrade), no-bottom-package install, and
/// uninstall — against the AppHub POC manifest server
/// (scripts/apphub_poc_server.py, reached via `adb reverse tcp:7610`).
/// Temporary by design; the real market UI lands with 容器契约 v2.
library;

import 'package:flutter/material.dart';

import '../apphub_market_page.dart';
import 'dimina_host.dart';

/// The WeUI example app, bundled at v67 under android assets jsapp/.
const String _bundledAppId = 'wx92269e3b2f304afc';

/// A second example app, deliberately NOT bundled: its first install comes
/// from the manifest server (无底包首次安装).
const String _remoteAppId = 'wx9f8c2d7e6a5b4c3d';

/// The POC manifest server, reached from the phone over adb reverse tcp:7610
/// (loopback is the only cleartext this app permits, per network_security_config).
const String _manifestBase = 'http://127.0.0.1:7610/manifest';

/// Build with `--dart-define=DSH_DIMINA_POC=1` to boot straight into this page
/// (no engine connection needed); consumed by main.dart.
const bool kDiminaPoc = bool.fromEnvironment('DSH_DIMINA_POC');

class DiminaPocScreen extends StatefulWidget {
  const DiminaPocScreen({super.key});

  @override
  State<DiminaPocScreen> createState() => _DiminaPocScreenState();
}

class _DiminaPocScreenState extends State<DiminaPocScreen> {
  final List<String> _log = <String>[];

  void _append(String line) {
    if (!mounted) return;
    setState(() {
      _log.insert(0, '${DateTime.now().toIso8601String().substring(11, 19)}  $line');
    });
  }

  Future<void> _run(String label, Future<bool> Function() action) async {
    _append('$label …');
    try {
      final bool ok = await action();
      _append('$label → ${ok ? 'OK' : '返回 false'}');
    } catch (error) {
      _append('$label → 失败:$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Dimina POC (M0)')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          FilledButton(
            onPressed: () => _run('打开内置 WeUI v67', () => DiminaHost.open(
                  appId: _bundledAppId,
                  name: 'WeUI for 小程序',
                  path: 'example/index',
                  versionCode: 67,
                  versionName: '1.0.66',
                  // The server serves v68 > 67: the SDK downloads it in the
                  // background and the patched package applies it on ready.
                  updateManifestUrl: '$_manifestBase/$_bundledAppId.json',
                )),
            child: const Text('① 打开内置包 v67(manifest 自动升到 v68)'),
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: () => _run('无底包安装 星河空战', () => DiminaHost.open(
                  appId: _remoteAppId,
                  name: '星河空战',
                  // No versionCode: the manifest supplies name/path/version on
                  // first install (无底包首次安装).
                  updateManifestUrl: '$_manifestBase/$_remoteAppId.json',
                )),
            child: const Text('② 无底包安装「星河空战」(manifest 首装)'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () => _run('关闭 $_bundledAppId', () => DiminaHost.close(_bundledAppId)),
            child: const Text('③ 关闭运行中的小程序'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () => _run(
                '卸载 $_bundledAppId(含数据)',
                () => DiminaHost.uninstall(_bundledAppId, clearUserData: true)),
            child: const Text('④ 卸载内置包(clearUserData)'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () => _run(
                '卸载 $_remoteAppId(含数据)',
                () => DiminaHost.uninstall(_remoteAppId, clearUserData: true)),
            child: const Text('⑤ 卸载第二示例(clearUserData)'),
          ),
          const SizedBox(height: 8),
          FilledButton.tonal(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const ApphubMarketPage()),
            ),
            child: const Text('应用市场(AppHub)'),
          ),
          const Divider(height: 24),
          for (final String line in _log)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(line, style: Theme.of(context).textTheme.bodySmall),
            ),
        ],
      ),
    );
  }
}
