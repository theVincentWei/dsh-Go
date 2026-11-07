import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_client/src/binary_response.dart';
import 'package:dsh_client/src/decode_worker.dart';
import 'package:dsh_client/src/errors.dart';
import 'package:dsh_client/src/json.dart';
import 'package:test/test.dart';

Uint8List _jsonBody(int chars) => Uint8List.fromList(utf8.encode('{"value": "${'x' * chars}"}'));

/// A multipart binary result in the Host's `fullResponse` layout: a
/// `metadata` field carrying the envelope (its `value.data` a null
/// placeholder) plus one attachment part named by the attachments table.
Uint8List _multipartBody(int attachmentBytes, {String boundary = 'DSHBOUND'}) {
  final metadata = jsonEncode({
    'type': 'server-response',
    'rpcId': 'rpc-1',
    'result': {
      'ok': true,
      'value': {'data': null},
    },
    'attachments': [
      // `path` is relative to `result.value` (binary_response.dart walks
      // `value` first): the bytes replace the null `value.data` placeholder.
      {'path': ['data'], 'codec': 'bytes', 'part': 'file'},
    ],
  });
  return Uint8List.fromList(
    utf8.encode(
      '--$boundary\r\n'
      'Content-Disposition: form-data; name="metadata"\r\n'
      '\r\n'
      '$metadata\r\n'
      '--$boundary\r\n'
      'Content-Disposition: form-data; name="file"\r\n'
      '\r\n'
      '${'a' * attachmentBytes}\r\n'
      '--$boundary--\r\n',
    ),
  );
}

void main() {
  group('DecodeWorker.json', () {
    test('large body equals the inline decode', () async {
      final worker = DecodeWorker();
      final body = _jsonBody(decodeWorkerThresholdBytes);
      expect(await worker.json(body), tryDecodeJson(utf8.decode(body, allowMalformed: true)));
      worker.close();
    });

    test('small body equals the inline decode', () async {
      final worker = DecodeWorker();
      final body = _jsonBody(64);
      expect(await worker.json(body), tryDecodeJson(utf8.decode(body, allowMalformed: true)));
      worker.close();
    });

    test('not-JSON is null, small and large', () async {
      final worker = DecodeWorker();
      expect(await worker.json(Uint8List.fromList(utf8.encode('{oops'))), isNull);
      expect(
        await worker.json(Uint8List.fromList(utf8.encode('{oops${'x' * decodeWorkerThresholdBytes}'))),
        isNull,
      );
      worker.close();
    });

    test('a JSON null body stays null on the worker', () async {
      final worker = DecodeWorker();
      final body = Uint8List.fromList(utf8.encode('null${' ' * decodeWorkerThresholdBytes}'));
      expect(await worker.json(body), isNull);
      worker.close();
    });

    test('close() falls back to inline with the same result', () async {
      final worker = DecodeWorker();
      await worker.json(_jsonBody(decodeWorkerThresholdBytes));
      worker.close();
      final body = _jsonBody(decodeWorkerThresholdBytes);
      expect(await worker.json(body), tryDecodeJson(utf8.decode(body, allowMalformed: true)));
    });
  });

  group('DecodeWorker.binaryResponse', () {
    test('large multipart equals the inline decode', () async {
      final worker = DecodeWorker();
      final body = _multipartBody(decodeWorkerThresholdBytes);
      expect(await worker.binaryResponse(body, 'DSHBOUND'), decodeBinaryResponse(body, 'DSHBOUND'));
      worker.close();
    });

    test('a truncated multipart throws the inline DshProtocolException text', () async {
      final worker = DecodeWorker();
      final whole = _multipartBody(decodeWorkerThresholdBytes);
      final broken = Uint8List.sublistView(whole, 0, whole.length - 12);
      DshProtocolException inlineFailure;
      try {
        decodeBinaryResponse(broken, 'DSHBOUND');
        fail('the inline decoder accepted a truncated multipart body');
      } on DshProtocolException catch (error) {
        inlineFailure = error;
      }
      await expectLater(
        worker.binaryResponse(broken, 'DSHBOUND'),
        throwsA(
          isA<DshProtocolException>().having((e) => e.message, 'message', inlineFailure.message),
        ),
      );
      worker.close();
    });
  });
}
