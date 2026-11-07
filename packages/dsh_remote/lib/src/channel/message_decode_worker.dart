/// Decoding large Remote messages off the caller's isolate.
///
/// The phone runs this client on the UI isolate. A 1 MiB
/// `workspaceFiles/readBytes` window arrives as a ~1.4 MB base64 JSON
/// string, and UTF-8 + strict wire JSON decoding of that on the UI isolate
/// drops frames for as long as a download runs. This worker moves
/// [RemoteMessage.decode] for messages at or above
/// [messageDecodeThresholdBytes] onto one long-lived isolate, spawned
/// lazily on the first large message. RemoteRpcClient hands every inbound
/// message to this class, so the small ones answer inline and the worker
/// never reorders anything. Results and failure texts are identical to the
/// inline decode; when the isolate cannot spawn or has died, the decode
/// falls back to inline on the caller.
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../protocol/control.dart';
import '../protocol/messages.dart';
import '../util/bytes.dart';

/// Messages at or above this size decode on the worker; smaller ones stay
/// inline, where an isolate round trip would cost more than the decode.
const int messageDecodeThresholdBytes = 64 * 1024;

/// Every message this class answers is the same [RemoteMessage] the inline
/// decode would have produced — same id, type, timestamp, payload, and the
/// same error text for a malformed one.
class MessageDecodeWorker {
  Isolate? _isolate;
  SendPort? _jobs;
  ReceivePort? _replies;
  Future<SendPort>? _starting;
  bool _broken = false;
  final _pending = <int, Completer<Object?>>{};
  var _nextJobId = 0;

  /// [RemoteMessage.decode] semantics; a malformed message throws with the
  /// inline decode's exact error text.
  Future<RemoteMessage> decode(Uint8List bytes) async {
    if (bytes.length < messageDecodeThresholdBytes || _broken) return RemoteMessage.decode(bytes);
    Object? reply;
    try {
      reply = await _ask(bytes);
    } on _WorkerGone {
      return RemoteMessage.decode(bytes);
    }
    final map = asMap(reply);
    if (map == null || map['ok'] != true) {
      // Same text the inline decode would have thrown.
      throw _DecodeFailure(asString(map?['error']) ?? 'Remote message decode failed');
    }
    return RemoteMessage(
      asString(map['type']) ?? '',
      map['payload'],
      id: asString(map['id']) ?? '',
      timestamp: asInt(map['timestamp']) ?? 0,
    );
  }

  /// Stops the worker isolate. Later decodes run inline, with the same
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

  Future<Object?> _ask(Uint8List bytes) async {
    final jobs = _jobs ?? await (_starting ??= _start());
    final id = _nextJobId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    jobs.send({'job': id, 'body': bytes});
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
      _isolate = await Isolate.spawn(_decodeMain, replies.sendPort, debugName: 'dsh-remote-decode');
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
    final id = map == null ? null : asInt(map['job']);
    if (id == null) return;
    _pending.remove(id)?.complete(map);
  }
}

final class _WorkerGone implements Exception {
  const _WorkerGone();
}

/// Reports a worker decode failure with the inline decode's exact text, so
/// channel-close diagnostics do not depend on which path ran.
final class _DecodeFailure implements Exception {
  const _DecodeFailure(this.text);

  final String text;

  @override
  String toString() => text;
}

/// The worker side: one inbox, one job at a time, replies tagged with the
/// job id.
void _decodeMain(SendPort reply) {
  final inbox = ReceivePort();
  inbox.listen((job) {
    final map = asMap(job);
    final id = map == null ? null : asInt(map['job']);
    if (map == null || id == null) return;
    final body = map['body'];
    try {
      if (body is! Uint8List) throw const ProtocolError('decode job without bytes');
      final message = RemoteMessage.decode(body);
      reply.send({
        'job': id,
        'ok': true,
        'id': message.id,
        'type': message.type,
        'timestamp': message.timestamp,
        'payload': message.payload,
      });
    } on Object catch (error) {
      reply.send({'job': id, 'ok': false, 'error': error.toString()});
    }
  });
  reply.send(inbox.sendPort);
}
