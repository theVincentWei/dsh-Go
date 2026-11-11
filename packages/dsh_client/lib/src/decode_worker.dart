/// Decoding large Host responses off the caller's isolate.
///
/// The dsh-go app runs this client on the UI isolate, so a big response body
/// decoded inline stalls frames: a 1 MiB `workspaceFiles/readBytes` window
/// arrives as a ~1 MiB multipart body to split ([decodeBinaryResponse]) and
/// history reads as megabytes of UTF-8 JSON to parse. This worker moves both
/// whole-body decodes onto one long-lived isolate, spawned lazily on the
/// first large body. Results are identical to the inline decoders and
/// failures carry the same type and message, so a caller cannot tell which
/// path ran; when the isolate cannot spawn or has died, every call falls
/// back to inline on the caller.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'binary_response.dart';
import 'errors.dart';
import 'json.dart';

/// Bodies at or above this size decode on the worker; smaller ones stay
/// inline, where an isolate round trip would cost more than the decode.
const int decodeWorkerThresholdBytes = 64 * 1024;

/// Every decode this class answers is the same bytes the inline decoder
/// would have produced, on this isolate or on the worker's.
class DecodeWorker {
  Isolate? _isolate;
  SendPort? _jobs;
  ReceivePort? _replies;
  Future<SendPort>? _starting;
  bool _broken = false;
  final _pending = <int, Completer<Object?>>{};
  var _nextJobId = 0;

  /// UTF-8 JSON with [tryDecodeJson] semantics: the decoded value, `null`
  /// when the body is not JSON.
  Future<Object?> json(Uint8List body) => _run(
    'json',
    body,
    null,
    () => tryDecodeJson(utf8.decode(body, allowMalformed: true)),
  );

  /// A multipart binary result, with [decodeBinaryResponse]'s exact result
  /// and failure: a [DshProtocolException] carrying the same message.
  Future<Object?> binaryResponse(Uint8List body, String boundary) =>
      _run('binary', body, boundary, () => decodeBinaryResponse(body, boundary));

  /// Stops the worker isolate. Later calls decode inline, with the same
  /// results.
  void close() {
    _broken = true;
    _starting = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _jobs = null;
    _replies?.close();
    _replies = null;
    for (final completer in _pending.values) {
      completer.completeError(const _WorkerGone());
    }
    _pending.clear();
  }

  Future<Object?> _run(
    String op,
    Uint8List body,
    String? boundary,
    Object? Function() inline,
  ) async {
    if (body.length < decodeWorkerThresholdBytes || _broken) return inline();
    Object? reply;
    try {
      reply = await _ask(op, body, boundary);
    } on _WorkerGone {
      return inline();
    }
    if (reply is Map && reply['ok'] == true) return reply['value'];
    throw DshProtocolException(
      reply is Map ? asString(reply['message']) ?? 'decode worker failed' : 'decode worker failed',
    );
  }

  Future<Object?> _ask(String op, Uint8List body, String? boundary) async {
    final jobs = _jobs ?? await (_starting ??= _start());
    final id = _nextJobId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    jobs.send({'id': id, 'op': op, 'body': body, 'boundary': ?boundary});
    return completer.future;
  }

  Future<SendPort> _start() async {
    final replies = ReceivePort();
    final ready = Completer<SendPort>();
    late final StreamSubscription<Object?> subscription;
    subscription = replies.listen((message) {
      if (message is SendPort) {
        ready.complete(message);
      } else {
        _onReply(message);
      }
    });
    try {
      _isolate = await Isolate.spawn(_decodeMain, replies.sendPort, debugName: 'dsh-decode-worker');
      // The worker answers with its inbox before doing anything else; if it
      // never does, this caller falls back to inline instead of hanging.
      return await ready.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw const _WorkerGone(),
      );
    } on Object {
      _broken = true;
      _starting = null;
      await subscription.cancel();
      replies.close();
      throw const _WorkerGone();
    }
  }

  void _onReply(Object? message) {
    final map = asMap(message);
    final id = map == null ? null : asInt(map['id']);
    if (id == null) return;
    _pending.remove(id)?.complete(map);
  }
}

final class _WorkerGone implements Exception {
  const _WorkerGone();
}

/// The worker side: one inbox, one job at a time, replies tagged with the
/// job id.
void _decodeMain(SendPort reply) {
  final inbox = ReceivePort();
  inbox.listen((job) {
    final map = asMap(job);
    final id = map == null ? null : asInt(map['id']);
    if (map == null || id == null) return;
    final body = map['body'];
    try {
      if (body is! Uint8List) throw const DshProtocolException('decode job without a body');
      final value = switch (map['op']) {
        'json' => tryDecodeJson(utf8.decode(body, allowMalformed: true)),
        'binary' => decodeBinaryResponse(body, asString(map['boundary']) ?? ''),
        _ => throw const DshProtocolException('unknown decode op'),
      };
      reply.send({'id': id, 'ok': true, 'value': value});
    } on DshProtocolException catch (error) {
      reply.send({'id': id, 'ok': false, 'message': error.message});
    }
  });
  reply.send(inbox.sendPort);
}
