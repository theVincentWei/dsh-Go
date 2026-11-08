/// AppHub server entrypoint: config → DB → market + gateway admin + gateway
/// proxy + observation sink, cascaded in that order (specific market routes
/// win over the proxy catch-all).
library;

import 'dart:io';

import 'package:mysql1/mysql1.dart' show ConnectionSettings;
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'package:apphub/ai_gateway.dart';
import 'package:apphub/config.dart';
import 'package:apphub/db.dart';
import 'package:apphub/gateway.dart';
import 'package:apphub/market.dart';
import 'package:apphub/notices.dart';
import 'package:apphub/obs.dart';
import 'package:apphub/store.dart';

Future<void> main(List<String> args) async {
  String configPath = '${Platform.environment['HOME']}/dsh/apphub/config.json';
  for (int i = 0; i < args.length - 1; i++) {
    if (args[i] == '--config') configPath = args[i + 1];
  }

  final AppConfig cfg = await AppConfig.load(configPath);
  await Directory(cfg.packagesDir).create(recursive: true);

  final Db db = Db(ConnectionSettings(
    host: cfg.db.host,
    port: cfg.db.port,
    user: cfg.db.user,
    password: cfg.db.password,
    db: cfg.db.database,
  ));
  await db.connect();
  await db.initSchema();

  final Store store = Store(db);
  final Market market = Market(cfg, db, store);
  final Gateway gateway = Gateway(cfg, db, store);
  final Obs obs = Obs(cfg);
  final Notices notices = Notices(db);
  final AiGateway ai = AiGateway(cfg, db, cfg.engineLaunchUrlFile);
  await gateway.reload();

  final shelf.Handler handler = shelf.Cascade(statusCodes: <int>[404])
      .add(market.router.call)
      .add(gateway.adminRouter.call)
      .add(obs.router.call)
      .add(notices.router.call)
      .add(ai.router.call)
      .add((shelf.Request request) async {
    final String path = request.url.path;
    if (path.startsWith('api/v1/apps/')) {
      final String rest = path.substring('api/v1/apps/'.length);
      final int slash = rest.indexOf('/');
      if (slash > 0) {
        return gateway.proxy(
            request, rest.substring(0, slash), rest.substring(slash + 1));
      }
    }
    return shelf.Response.notFound('not found');
  }).handler;

  final server = await shelf_io.serve(handler, InternetAddress.anyIPv4, cfg.port);
  stdout.writeln('AppHub listening on :${server.port}');
  stdout.writeln('  market   /apps/<appId>/manifest.json  /packages/…  /api/v1/apps');
  stdout.writeln('  gateway  /api/v1/apps/<appId>/<prefix>/… → backends');
  stdout.writeln('  packages ${cfg.packagesDir}');
  stdout.writeln('  logs     ${cfg.engineAppsDir}/<appId>/data/logs/');
}
