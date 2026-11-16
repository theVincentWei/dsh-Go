// AppHub over DSH Remote proxy client (contract
// `ds-harness-remote/docs/apphub-proxy.v1.md`): forwards the phone-side
// AppHub HTTP traffic (market listing, versions, notifications, icons, mini
// app bundles — plain HTTP aimed at `127.0.0.1:7610` on the Host) over the
// existing encrypted tunnel RPCs once the Host declares the
// `remote.apphub.proxy.v1` capability. Bodies above the inline bound reuse
// the `harness.remote.transfer` wire shapes of `tunnel_carrier.dart`
// verbatim: client→Host open/chunk/commit, Host→client descriptor plus
// indexed reads, with the same strict descriptor validation.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_client/dsh_client.dart';

import '../carrier/tunnel_carrier.dart'
    show RemoteHostSession, RemoteTunnelCarrier, maxRemoteTransferBytes, remoteTransferChunkBytes;
import '../channel/rpc_client.dart' show RemoteRpcException;
import '../util/bytes.dart';

/// Capability the Host must list in `harness.transport.describe` (contract
/// §1) for [RemoteAppHubClient.supported].
const String appHubProxyCapability = 'remote.apphub.proxy.v1';

/// Tunnel RPC the proxy requests travel on (contract §2), next to
/// `harness.remote.call` and `harness.remote.transfer.*`.
const String appHubProxyRpc = 'harness.remote.apphub.request';

/// Largest inline body on either direction, decoded (contract §2.1/§2.2);
/// anything larger goes through `harness.remote.transfer.*`.
const int appHubInlineBytes = 65536;

/// Allowed upstream methods (contract §2.1). Everything else is refused
/// locally first with the Host's own `UNSUPPORTED_METHOD` code.
const Set<String> appHubProxyMethods = {'GET', 'POST', 'PUT', 'DELETE', 'HEAD', 'OPTIONS'};

final class AppHubHttpResponse {
  const AppHubHttpResponse({required this.status, required this.headers, required this.body});

  /// Upstream HTTP status code, verbatim.
  final int status;

  /// Response headers with lower-cased keys (hop-by-hop headers removed by
  /// the Host).
  final Map<String, String> headers;

  /// The complete response body, already assembled.
  final List<int> body;
}

final class RemoteAppHubClient {
  /// [carrier] 为当前 relay 连接的 RemoteTunnelCarrier。
  RemoteAppHubClient(this._carrier);

  final RemoteTunnelCarrier _carrier;

  /// Same strict shape `_readFrame` enforces on stream transfer ids.
  static final RegExp _transferIdPattern = RegExp(
    r'^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$',
  );

  /// capabilities 含 remote.apphub.proxy.v1 才为 true。
  bool get supported => _carrier.capabilities.contains(appHubProxyCapability);

  /// 链路断开抛 DshClosedException;Host 不支持抛含 CAPABILITY_NOT_SUPPORTED
  /// 语义的 RemoteRpcException;上游错误按 §2.3 映射(Host rpc.error 原样透传:
  /// `APPHUB_BAD_PATH` / `UNSUPPORTED_METHOD` / `APPHUB_UNREACHABLE` /
  /// `APPHUB_TIMEOUT` / `PAYLOAD_TOO_LARGE`,retryable 随 Host)。
  Future<AppHubHttpResponse> request({
    required String method,
    required String path,
    String? query,
    Map<String, String>? headers,
    List<int>? body, // null 即 kind:none
  }) async {
    if (!appHubProxyMethods.contains(method)) {
      throw const RemoteRpcException(
        'UNSUPPORTED_METHOD',
        'The AppHub proxy allows GET, POST, PUT, DELETE, HEAD and OPTIONS only.',
      );
    }
    if (!_validPath(path) || (query != null && !_validQuery(query))) {
      throw const RemoteRpcException('APPHUB_BAD_PATH', 'The AppHub proxy path or query is invalid.');
    }
    if (!supported) {
      throw const RemoteRpcException(
        'CAPABILITY_NOT_SUPPORTED',
        'The Host does not declare remote.apphub.proxy.v1.',
      );
    }
    if (body != null && body.length > maxRemoteTransferBytes) {
      throw const RemoteRpcException(
        'PAYLOAD_TOO_LARGE',
        'The AppHub request exceeds the 288 MiB transfer limit.',
      );
    }
    final session = _carrier.session;
    if (session == null || session.isClosed) {
      throw const DshClosedException('The remote AppHub link is not connected.');
    }
    final transferId = body != null && body.length > appHubInlineBytes ? uuidV7() : null;
    final Object? bodyField;
    if (transferId != null) {
      bodyField = {
        'kind': 'transfer',
        'transferId': transferId,
        'totalBytes': body!.length,
        'totalChunks': (body.length + remoteTransferChunkBytes - 1) ~/ remoteTransferChunkBytes,
      };
    } else if (body != null && body.isNotEmpty) {
      bodyField = {'kind': 'inline', 'data': base64Encode(body)};
    } else {
      bodyField = const {'kind': 'none'};
    }
    final params = <String, Object?>{
      'method': method,
      'path': path,
      if (query != null && query.isNotEmpty) 'query': query,
      if (headers != null && headers.isNotEmpty)
        'headers': {for (final entry in headers.entries) entry.key.toLowerCase(): entry.value},
      'body': bodyField,
    };
    if (transferId != null) await _uploadBody(session, body!, transferId);
    return _parseResponse(session, await session.rpc.call(appHubProxyRpc, params, timeout: _carrier.callTimeout));
  }

  /// Large request bodies take the existing transfer write path, mirrored
  /// from `_callTransferred` of `tunnel_carrier.dart`: same open/chunk/commit
  /// parameter shapes, same 512 KiB canonical base64 chunks, same `finally`
  /// cleanup on the request's own connection. The uploaded bytes are the raw
  /// HTTP body; commit only confirms the resource, the main RPC's body
  /// reference then consumes it (contract §2.1).
  Future<void> _uploadBody(RemoteHostSession session, List<int> body, String transferId) async {
    final rpc = session.rpc;
    final perCall = _carrier.callTimeout;
    final encoded = body is Uint8List ? body : Uint8List.fromList(body);
    final totalChunks = (encoded.length + remoteTransferChunkBytes - 1) ~/ remoteTransferChunkBytes;
    try {
      await rpc.call(
        'harness.remote.transfer.open',
        {'transferId': transferId, 'totalBytes': encoded.length, 'totalChunks': totalChunks},
        timeout: perCall,
      );
      for (var index = 0; index < totalChunks; index++) {
        final start = index * remoteTransferChunkBytes;
        final end = start + remoteTransferChunkBytes < encoded.length
            ? start + remoteTransferChunkBytes
            : encoded.length;
        await rpc.call(
          'harness.remote.transfer.chunk',
          {
            'transferId': transferId,
            'index': index,
            'data': base64Encode(Uint8List.sublistView(encoded, start, end)),
          },
          timeout: perCall,
        );
      }
      await rpc.call('harness.remote.transfer.commit', {'transferId': transferId}, timeout: perCall);
    } finally {
      // An open timeout can follow allocation on the Host. Closing a missing
      // UUID is harmless; keep cleanup on this request's original connection.
      unawaited(
        rpc
            .call('harness.remote.transfer.close', {'transferId': transferId}, timeout: const Duration(seconds: 5))
            .then((_) {}, onError: (Object _) {}),
      );
    }
  }

  /// Contract §2.2 response value: `{status, headers, body}`.
  Future<AppHubHttpResponse> _parseResponse(RemoteHostSession session, Object? value) async {
    final map = asMap(value);
    if (map == null) throw const DshProtocolException('The Host returned an invalid AppHub response.');
    final status = asInt(map['status']);
    if (status == null || status < 100 || status > 599) {
      throw const DshProtocolException('The Host returned an invalid AppHub status.');
    }
    final headers = <String, String>{};
    final rawHeaders = map['headers'];
    if (rawHeaders != null) {
      final mapHeaders = asMap(rawHeaders);
      if (mapHeaders == null) {
        throw const DshProtocolException('The Host returned invalid AppHub headers.');
      }
      mapHeaders.forEach((key, value) {
        final text = asString(value);
        if (text == null) {
          throw const DshProtocolException('The Host returned invalid AppHub headers.');
        }
        headers[key.toLowerCase()] = text;
      });
    }
    return AppHubHttpResponse(status: status, headers: headers, body: await _parseBody(session, map['body']));
  }

  /// Contract §2.1/§2.2 Body: none | inline | transfer.
  Future<Uint8List> _parseBody(RemoteHostSession session, Object? raw) async {
    final body = asMap(raw);
    if (body == null) {
      throw const DshProtocolException('The Host returned an invalid AppHub body.');
    }
    switch (body['kind']) {
      case 'none':
        return Uint8List(0);
      case 'inline':
        final data = asString(body['data']);
        if (data == null) {
          throw const DshProtocolException('The Host returned an invalid AppHub inline body.');
        }
        final Uint8List bytes;
        try {
          bytes = base64Decode(data);
        } on FormatException {
          throw const DshProtocolException('The Host returned a malformed AppHub inline body.');
        }
        if (bytes.length > appHubInlineBytes || base64Encode(bytes) != data) {
          throw const DshProtocolException('The Host returned a non-canonical AppHub inline body.');
        }
        return bytes;
      case 'transfer':
        final id = asString(body['transferId']);
        final totalBytes = asInt(body['totalBytes']);
        final totalChunks = asInt(body['totalChunks']);
        if (id == null || totalBytes == null) {
          throw const DshProtocolException('Invalid AppHub transfer descriptor.');
        }
        return _readTransfer(session, id, totalBytes, totalChunks);
      default:
        throw const DshProtocolException('The Host returned an unknown AppHub body kind.');
    }
  }

  /// Host→client direction: descriptor plus indexed reads, with the exact
  /// validation `_callTransferred` / `_readFrame` apply (`kind:"chunked"`,
  /// `totalBytes`, `totalChunks=ceil(totalBytes/524288)`, UUID-shaped
  /// `transferId`, canonical base64, exact chunk lengths). Unlike the
  /// existing JSON streams this assembles raw HTTP body bytes (§2.2).
  Future<Uint8List> _readTransfer(RemoteHostSession session, String transferId, int totalBytes, int? descriptorChunks) async {
    final rpc = session.rpc;
    final perCall = _carrier.callTimeout;
    final responseChunks = (totalBytes + remoteTransferChunkBytes - 1) ~/ remoteTransferChunkBytes;
    try {
      if (!_transferIdPattern.hasMatch(transferId) ||
          totalBytes <= 0 ||
          totalBytes > maxRemoteTransferBytes ||
          descriptorChunks != responseChunks) {
        throw const DshProtocolException('Invalid AppHub transfer descriptor.');
      }
      final out = BytesBuilder(copy: false);
      for (var index = 0; index < responseChunks; index++) {
        final chunk = asMapOrEmpty(
          await rpc.call('harness.remote.transfer.read', {'transferId': transferId, 'index': index}, timeout: perCall),
        );
        final data = asString(chunk['data']);
        if (chunk['transferId'] != transferId || chunk['index'] != index || data == null) {
          throw const DshProtocolException('Out-of-order AppHub transfer chunk.');
        }
        final Uint8List bytes;
        try {
          bytes = base64Decode(data);
        } on FormatException {
          throw const DshProtocolException('Malformed AppHub transfer chunk.');
        }
        final remaining = totalBytes - index * remoteTransferChunkBytes;
        final expected = remaining < remoteTransferChunkBytes ? remaining : remoteTransferChunkBytes;
        if (bytes.length != expected || base64Encode(bytes) != data) {
          throw const DshProtocolException('Non-canonical AppHub transfer chunk.');
        }
        out.add(bytes);
      }
      return out.takeBytes();
    } finally {
      // Releases Host backpressure even on malformed data or cancellation.
      unawaited(
        rpc
            .call('harness.remote.transfer.close', {'transferId': transferId}, timeout: const Duration(seconds: 5))
            .then((_) {}, onError: (Object _) {}),
      );
    }
  }

  // Contract §2.1/§3.2: starts with "/", no ".." segment, no 0x00-0x1f.
  static bool _validPath(String path) {
    if (!path.startsWith('/') || path.length > 2048) return false;
    for (final segment in path.split('/')) {
      if (segment == '..') return false;
    }
    return !_hasControlChars(path);
  }

  // Contract §2.1: no leading "?"; validated like the path otherwise.
  static bool _validQuery(String query) => !query.startsWith('?') && !_hasControlChars(query);

  static bool _hasControlChars(String value) {
    for (final char in value.codeUnits) {
      if (char < 0x20) return true;
    }
    return false;
  }
}
