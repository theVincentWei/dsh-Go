import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_remote/dsh_remote.dart';
import 'package:dsh_remote/src/channel/message_decode_worker.dart';
import 'package:dsh_remote/src/protocol/messages.dart';
import 'package:test/test.dart';
import 'support/rpc_event_host.dart';

String _inlineErrorText(Uint8List bytes) {
  try {
    RemoteMessage.decode(bytes);
    fail('the inline decode accepted a malformed message');
  } on Object catch (error) {
    return error.toString();
  }
}

void main() {
  group('MessageDecodeWorker.decode', () {
    test('large message equals the inline decode', () async {
      final worker = MessageDecodeWorker();
      final bytes = RemoteMessage('event', {'event': 'big', 'data': 'x' * messageDecodeThresholdBytes}).encode();
      final viaWorker = await worker.decode(bytes);
      final inline = RemoteMessage.decode(bytes);
      expect(viaWorker.id, inline.id);
      expect(viaWorker.type, inline.type);
      expect(viaWorker.timestamp, inline.timestamp);
      expect(viaWorker.payload, inline.payload);
      worker.close();
    });

    test('small message equals the inline decode', () async {
      final worker = MessageDecodeWorker();
      final bytes = RemoteMessage('rpc.response', {'requestId': 'r1', 'result': {'ok': true, 'value': 1}}).encode();
      final viaWorker = await worker.decode(bytes);
      final inline = RemoteMessage.decode(bytes);
      expect(viaWorker.id, inline.id);
      expect(viaWorker.payload, inline.payload);
      worker.close();
    });

    test('a duplicate JSON key fails with the inline error text', () async {
      final worker = MessageDecodeWorker();
      final bytes = Uint8List.fromList(
        utf8.encode(
          '{"v":1,"id":"dup","type":"event","timestamp":1,'
          '"payload":{"event":"a","event":"b"},"pad":"${'x' * messageDecodeThresholdBytes}"}',
        ),
      );
      final inlineError = _inlineErrorText(bytes);
      await expectLater(worker.decode(bytes), throwsA(predicate((Object e) => e.toString() == inlineError)));
      worker.close();
    });

    test('not-JSON fails with the inline error text', () async {
      final worker = MessageDecodeWorker();
      final bytes = Uint8List.fromList(utf8.encode('{oops${'x' * messageDecodeThresholdBytes}'));
      final inlineError = _inlineErrorText(bytes);
      await expectLater(worker.decode(bytes), throwsA(predicate((Object e) => e.toString() == inlineError)));
      worker.close();
    });

    test('close() falls back to inline with the same result', () async {
      final worker = MessageDecodeWorker();
      await worker.decode(RemoteMessage('event', {'event': 'warm', 'data': 'x' * messageDecodeThresholdBytes}).encode());
      worker.close();
      final bytes = RemoteMessage('event', {'event': 'after', 'data': 'x' * messageDecodeThresholdBytes}).encode();
      final viaWorker = await worker.decode(bytes);
      final inline = RemoteMessage.decode(bytes);
      expect(viaWorker.id, inline.id);
      expect(viaWorker.payload, inline.payload);
    });
  });

  test('a large event does not let the next small event overtake it', () async {
    final f = EventHost();
    await f.start();
    addTearDown(f.close);
    final seenSmall = Completer<void>();
    f.rpc.events.listen((event) {
      if (event.event == 'small') seenSmall.complete();
    });
    // The first message is over the threshold and takes the worker isolate;
    // the second is small and would finish earlier if handling were not
    // chained in arrival order. The large one goes out as DSHF fragments,
    // like every real send above 48 KiB (a single Noise plaintext caps at
    // 65519 bytes).
    final big = SecureMessageCodec().encode(
      RemoteMessage('event', {'event': 'big', 'data': 'x' * (messageDecodeThresholdBytes + 1024)}).encode(),
    );
    for (final fragment in big) {
      f.sendBytes(fragment);
    }
    f.sendBytes(RemoteMessage('event', {'event': 'small', 'data': 2}).encode());
    await seenSmall.future;
    expect(f.events, ['big', 'small']);
  });
}
