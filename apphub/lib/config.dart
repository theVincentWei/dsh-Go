/// AppHub configuration: a JSON file, see tool/apphub.config.example.json.
///
/// Defaults keep the whole thing runnable on one Mac: port 7610, MariaDB on
/// localhost, packages under ~/dsh/apphub/, observation logs into the engine's
/// ~/dsh/apps/<appId>/data/logs/ so the Agent can read them.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

class DbConfig {
  const DbConfig({
    required this.host,
    required this.port,
    required this.user,
    required this.password,
    required this.database,
  });

  final String host;
  final int port;
  final String user;
  final String password;
  final String database;
}

class AppConfig {
  const AppConfig({
    required this.port,
    required this.db,
    required this.publisherKey,
    required this.deviceToken,
    required this.dataDir,
    required this.engineAppsDir,
    required this.appDbPassword,
    required this.engineLaunchUrl,
    required this.engineLaunchUrlFile,
  });

  final int port;
  final DbConfig db;

  /// Bearer key that publishes versions and mutates gateway routes.
  final String publisherKey;

  /// Bearer token for device-facing reads/writes (events, logs). Empty string
  /// means "LAN trust" — M1 on the home LAN runs tokenless reads.
  final String deviceToken;

  /// Package store: <dataDir>/packages/<appId>-<versionCode>.zip
  final String dataDir;

  /// The engine's ~/dsh/apps — observation logs land in
  /// <engineAppsDir>/<appId>/data/logs/ where the Agent reads them.
  final String engineAppsDir;

  /// Password AppHub assigns to each per-app MariaDB user (app_<appId>).
  final String appDbPassword;

  /// The engine's launch URL (http://127.0.0.1:<port>/?token=…, minted by
  /// `dsh web` / the GUI's device pairing). Empty = AI gateway answers 503.
  final String engineLaunchUrl;

  /// Preferred over [engineLaunchUrl]: a file whose last `dsh web:` line is
  /// the current launch URL — works across engine restarts, where the token
  /// rotates (the AppHub engine supervisor maintains this file).
  final String engineLaunchUrlFile;

  String get packagesDir => p.join(dataDir, 'packages');

  String packagePath(String appId, int versionCode) =>
      p.join(packagesDir, '$appId-$versionCode.zip');

  /// The app icon extracted from the bundle's main/icon.png at publish time;
  /// served back as /icons/<appId>-<versionCode>-icon.png.
  String iconPath(String appId, int versionCode) =>
      p.join(packagesDir, '$appId-$versionCode-icon.png');

  String logFileFor(String appId, DateTime now) {
    final String day =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
    return p.join(engineAppsDir, appId, 'data', 'logs', 'apphub-$day.log');
  }

  static Future<AppConfig> load(String path) async {
    final Object? decoded =
        jsonDecode(await File(path).readAsString()) as Object?;
    if (decoded is! Map<String, Object?>) {
      throw StateError('config must be a JSON object: $path');
    }
    final Map<String, Object?> db =
        (decoded['db'] ?? <String, Object?>{}) as Map<String, Object?>;
    final String home = Platform.environment['HOME'] ?? '/tmp';
    String expand(String raw) => raw.startsWith('~') ? p.join(home, raw.substring(1)) : raw;
    return AppConfig(
      port: (decoded['port'] as num?)?.toInt() ?? 7610,
      db: DbConfig(
        host: (db['host'] as String?) ?? '127.0.0.1',
        port: (db['port'] as num?)?.toInt() ?? 3306,
        user: (db['user'] as String?) ?? 'apphub',
        password: (db['password'] as String?) ?? 'apphub-local',
        database: (db['database'] as String?) ?? 'apphub',
      ),
      publisherKey: (decoded['publisherKey'] as String?) ?? '',
      deviceToken: (decoded['deviceToken'] as String?) ?? '',
      dataDir: expand((decoded['dataDir'] as String?) ?? '~/dsh/apphub'),
      engineAppsDir: expand((decoded['engineAppsDir'] as String?) ?? '~/dsh/apps'),
      appDbPassword: (decoded['appDbPassword'] as String?) ?? 'app-apphub-local',
      engineLaunchUrl: expand((decoded['engine'] as Map<String, Object?>?)?['launchUrl'] as String? ?? ''),
      engineLaunchUrlFile:
          expand((decoded['engine'] as Map<String, Object?>?)?['launchUrlFile'] as String? ?? ''),
    );
  }
}
