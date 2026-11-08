/// apphubctl — the AppHub CLI: publish packages, list apps, roll back,
/// manage gateway routes, set tool manifests. Thin HTTP client over the
/// AppHub API; the server does all the gating and auditing.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:http/http.dart' as http;

const String _usage = '''
apphubctl — AppHub CLI

  apphubctl publish <zip> --app <id> --name <name> [--path <p>]
                    [--version-code N] [--version-name V] [--tools tools.json]
  apphubctl list
  apphubctl rollback --app <id>
  apphubctl tools --app <id> --file tools.json
  apphubctl routes
  apphubctl route add --app <id> --prefix /v1 --target http://127.0.0.1:8081
  apphubctl route remove --app <id> --prefix /v1

Common flags: --server http://127.0.0.1:7610  --key <publisherKey>
''';

Future<void> main(List<String> args) async {
  final String command = args.isEmpty ? '' : args.first;

  final parser = ArgParser()
    ..addOption('server', defaultsTo: 'http://127.0.0.1:7610')
    ..addOption('key', defaultsTo: Platform.environment['APPHUB_KEY'] ?? '')
    ..addOption('app')
    ..addOption('name')
    ..addOption('path')
    ..addOption('version-code')
    ..addOption('version-name')
    ..addOption('tools')
    ..addOption('prefix')
    ..addOption('target');

  final ArgResults parsed;
  try {
    parsed = parser.parse(args.skip(1).toList());
  } on ArgParserException catch (error) {
    stderr.writeln(error.message);
    stdout.write(_usage);
    exitCode = 64;
    return;
  }

  final String server = parsed['server'] as String;
  final String key = parsed['key'] as String;

  try {
    switch (command) {
      case 'publish':
        if (parsed.rest.isEmpty) {
          stderr.writeln('publish needs a zip path');
          exitCode = 64;
          return;
        }
        await _publish(parsed, server, key);
      case 'list':
        await _list(server, key);
      case 'rollback':
        await _post(server, key, '/api/v1/apps/${parsed['app']}/rollback');
      case 'tools':
        await _tools(parsed, server, key);
      case 'routes':
        await _get(server, key, '/api/v1/gateway/routes');
      case 'route':
        await _route(parsed, server, key);
      default:
        stdout.write(_usage);
    }
  } catch (error) {
    stderr.writeln('error: $error');
    exitCode = 1;
  }
}

Map<String, String> _headers(String key) => <String, String>{
      if (key.isNotEmpty) 'authorization': 'Bearer $key',
    };

Future<void> _print(http.Response response) async {
  try {
    final Object? body = jsonDecode(response.body);
    stdout
        .writeln('${response.statusCode} ${const JsonEncoder.withIndent('  ').convert(body)}');
  } catch (_) {
    stdout.writeln('${response.statusCode} ${response.body}');
  }
  if (response.statusCode >= 400) exitCode = 1;
}

Future<void> _publish(ArgResults parsed, String server, String key) async {
  final String zipPath = parsed.rest.first;
  final String? appId = parsed['app'] as String?;
  if (appId == null || appId.isEmpty) {
    stderr.writeln('--app is required');
    exitCode = 64;
    return;
  }
  final Uint8List bytes = await File(zipPath).readAsBytes();
  final String? toolsFile = parsed['tools'] as String?;
  final String name = parsed['name'] as String? ?? appId;
  final String path = parsed['path'] as String? ?? 'pages/index/index';
  final http.Response response = await http.post(
    Uri.parse('$server/api/v1/apps/$appId/versions'),
    headers: <String, String>{
      ..._headers(key),
      'content-type': 'application/zip',
      // UTF-8 in headers is latin-1-mangled; send metadata base64-encoded.
      'x-app-name-b64': base64Encode(utf8.encode(name)),
      'x-app-path-b64': base64Encode(utf8.encode(path)),
      if (parsed['version-code'] != null) 'x-version-code': parsed['version-code'] as String,
      if (parsed['version-name'] != null) 'x-version-name': parsed['version-name'] as String,
      if (toolsFile != null && toolsFile.isNotEmpty)
        'x-tools-b64': base64Encode(File(toolsFile).readAsBytesSync()),
    },
    body: bytes,
  );
  await _print(response);
}

Future<void> _list(String server, String key) async =>
    _print(await http.get(Uri.parse('$server/api/v1/apps'), headers: _headers(key)));

Future<void> _tools(ArgResults parsed, String server, String key) async {
  final String? file = parsed['file'] as String?;
  final String? appId = parsed['app'] as String?;
  if (file == null || appId == null) {
    stderr.writeln('--app and --file are required');
    exitCode = 64;
    return;
  }
  await _print(await http.post(
    Uri.parse('$server/api/v1/apps/$appId/tools'),
    headers: <String, String>{
      ..._headers(key),
      'content-type': 'application/json; charset=utf-8',
    },
    body: File(file).readAsStringSync(),
  ));
}

Future<void> _route(ArgResults parsed, String server, String key) async {
  final String? appId = parsed['app'] as String?;
  final String? prefix = parsed['prefix'] as String?;
  final String? target = parsed['target'] as String?;
  if (appId == null || prefix == null) {
    stderr.writeln('--app and --prefix are required');
    exitCode = 64;
    return;
  }
  if (target != null) {
    await _print(await http.post(
      Uri.parse('$server/api/v1/gateway/routes'),
      headers: <String, String>{
        ..._headers(key),
        'content-type': 'application/json; charset=utf-8',
      },
      body: jsonEncode(<String, Object?>{
        'appId': appId,
        'prefix': prefix,
        'target': target,
      }),
    ));
  } else {
    await _print(await http.delete(
      Uri.parse('$server/api/v1/gateway/routes/$appId${Uri.encodeComponent(prefix)}'),
      headers: _headers(key),
    ));
  }
}

Future<void> _post(String server, String key, String path) async =>
    _print(await http.post(Uri.parse('$server$path'), headers: _headers(key)));

Future<void> _get(String server, String key, String path) async =>
    _print(await http.get(Uri.parse('$server$path'), headers: _headers(key)));
