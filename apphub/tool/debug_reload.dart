/// One-off: reproduce the gateway reload cast failure with a full stack.
library;

import 'dart:io';

import 'package:mysql1/mysql1.dart' show ConnectionSettings;
import 'package:apphub/config.dart';
import 'package:apphub/db.dart';
import 'package:apphub/gateway.dart';
import 'package:apphub/store.dart';

Future<void> main() async {
  final String configPath =
      '${Platform.environment['HOME']}/dsh/apphub/config.json';
  final AppConfig cfg = await AppConfig.load(configPath);
  final Db db = Db(ConnectionSettings(
    host: cfg.db.host,
    port: cfg.db.port,
    user: cfg.db.user,
    password: cfg.db.password,
    db: cfg.db.database,
  ));
  await db.connect();
  final Store store = Store(db);
  final Gateway gateway = Gateway(cfg, db, store);
  try {
    final routes = await store.listRoutes();
    print('routes: $routes');
    await gateway.reload();
    print('reload OK');
  } catch (error, stack) {
    print('FAILED: $error');
    print(stack);
  }
}
