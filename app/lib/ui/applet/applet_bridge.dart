/// The Applet filesystem bridge: one `DshAppFs` channel served from Dart.
///
/// Contract: docs/apps/container-contract.md. Pages send JSON messages
/// (`{op, path, reqId}`); replies are `{reqId, ok, data?|entries?, error?,
/// message?}`. Every path is sandbox-checked against the app's own data dir
/// before it touches the engine ([resolveWithinAppletData]); the underlying
/// client could read any engine path, so this class is the security boundary.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_client/dsh_client.dart';

import 'applet_paths.dart';

/// What the bridge needs from the connected engine.
abstract class AppletTransport {
  /// The engine host's home directory (`directoryPicker/list` with no path).
  Future<String> engineHome();

  /// Bytes at an absolute engine path (`workspaceFiles/readBytes`).
  Future<Uint8List> readBytes(String absolutePath, {required int maxBytes});

  /// Non-hidden entry names of one directory (`directoryPicker/list`).
  Future<List<String>> listDir(String absolutePath);
}

/// [AppletTransport] over the app's [DshClient]. The engine home is fetched
/// once per transport; hosts are POSIX, so home-joined paths are portable.
class DshAppletTransport implements AppletTransport {
  DshAppletTransport({required this.client, required this.sessionId});

  final DshClient client;
  final String sessionId;
  Future<String>? _home;

  @override
  Future<String> engineHome() {
    return _home ??= client.listDirectory().then((DirectoryListing listing) {
      final String home = listing.home;
      if (home.isEmpty) {
        throw const DshRemoteException('applet/no-home', '引擎没有报告家目录');
      }
      return home;
    });
  }

  @override
  Future<Uint8List> readBytes(String absolutePath, {required int maxBytes}) =>
      client.readFileBytes(sessionId, absolutePath, maxBytes: maxBytes);

  @override
  Future<List<String>> listDir(String absolutePath) async {
    final DirectoryListing listing = await client.listDirectory(absolutePath);
    return listing.entries
        .where((entry) => !entry.hidden)
        .map((entry) => entry.name)
        .toList(growable: false);
  }
}

/// Serves one applet's `DshAppFs` messages.
class AppletFsBridge {
  /// [appId] must be a valid app id: the bridge serves exactly
  /// `~/dsh/apps/<appId>/data/` and nothing else.
  AppletFsBridge({required this.transport, required String appId})
      : _appId = appId {
    if (!isValidAppletId(appId)) {
      throw ArgumentError.value(appId, 'appId', 'invalid app id');
    }
  }

  final AppletTransport transport;
  final String _appId;

  /// Largest file the bridge serves. Container pages and data stay far below;
  /// the cap keeps a runaway page from pulling the engine's disk over the
  /// bridge. `readFileBytes` refuses larger files with `workspace-file/too-large`.
  static const int maxFileBytes = 4 * 1024 * 1024;

  /// Handles one JSON-decoded DshAppFs message. Never throws: every failure
  /// path returns a reply so the page's promise always settles.
  Future<Map<String, Object?>> handle(Map<Object?, Object?> message) async {
    final Object? reqId = message['reqId'];
    try {
      switch (message['op']) {
        case 'read':
          return await _read(reqId, message['path']);
        case 'list':
          return await _list(reqId, message['path']);
        case 'write':
          return _denied(reqId, 'NOT_IMPLEMENTED', '写入要等引擎的文件写端点（容器阶段 2）');
        default:
          return _denied(reqId, 'BAD_OP', '不支持的 op: ${message['op']}');
      }
    } on DshRemoteException catch (error) {
      return _denied(reqId, _mapErrorCode(error.code), error.message);
    } catch (error) {
      return _denied(reqId, 'TRANSPORT_ERROR', '$error');
    }
  }

  Future<Map<String, Object?>> _read(Object? reqId, Object? path) async {
    final String? absolute = await _resolve(path);
    if (absolute == null) {
      return _denied(reqId, 'SANDBOX_ESCAPE', '路径超出该应用的数据目录');
    }
    final Uint8List bytes;
    try {
      bytes = await transport.readBytes(absolute, maxBytes: maxFileBytes);
    } on DshRemoteException catch (error) {
      if (error.code == 'workspace-file/not-found') {
        return _denied(reqId, 'NOT_FOUND', '文件不存在: $path');
      }
      rethrow;
    }
    final String text = utf8.decode(bytes, allowMalformed: true);
    Object? data;
    try {
      data = jsonDecode(text);
    } on FormatException {
      // Non-JSON files (notes, csv, …) come back as text; the page decides.
      data = text;
    }
    return <String, Object?>{'reqId': reqId, 'ok': true, 'data': data};
  }

  Future<Map<String, Object?>> _list(Object? reqId, Object? path) async {
    final String? absolute = await _resolve(path);
    if (absolute == null) {
      return _denied(reqId, 'SANDBOX_ESCAPE', '路径超出该应用的数据目录');
    }
    final List<String> names = await transport.listDir(absolute);
    names.sort();
    return <String, Object?>{'reqId': reqId, 'ok': true, 'entries': names};
  }

  Future<String?> _resolve(Object? path) async {
    if (path is! String) return null;
    // engineHome is cached by the transport; the app id was validated in the
    // constructor, so null here always means a sandbox escape.
    final String home = await transport.engineHome();
    return resolveWithinAppletData(engineHome: home, appId: _appId, relative: path);
  }

  Map<String, Object?> _denied(Object? reqId, String code, String message) =>
      <String, Object?>{'reqId': reqId, 'ok': false, 'error': code, 'message': message};

  String _mapErrorCode(String code) {
    switch (code) {
      case 'workspace-file/not-found':
        return 'NOT_FOUND';
      case 'workspace-file/too-large':
        return 'TOO_LARGE';
      case 'workspace-file/not-allowed':
        return 'NOT_ALLOWED';
      case 'workspace-file/unsupported':
        return 'UNSUPPORTED';
      default:
        return code;
    }
  }
}
