import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

/// Real loopback HTTP and public readFile, serving a fixed 8-byte file in
/// 2-byte windows, so resumed reads (offset) can be asserted precisely.
class _Files {
  _Files(this.server) : file = [1, 2, 3, 4, 5, 6, 7, 8];
  final HttpServer server;
  final List<int> file;
  final offsets = <int>[];
  int fallbackReads = 0;
  late final client = DshClient(DshConnection(Uri.parse('http://127.0.0.1:${server.port}')));

  static Future<_Files> start() async {
    final host = _Files(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    host.server.listen((request) async {
      try {
        if (request.uri.path == '/api/file') {
          host.fallbackReads++;
          request.response.add([9, 9]);
        } else {
          final envelope = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          Map<String, Object?> value;
          if (request.uri.path == '/api/workspaceFiles/stat') {
            value = {'absolutePath': '/synthetic/file', 'bytes': host.file.length, 'version': 'v1'};
          } else if (request.uri.path == '/api/workspaceFiles/readBytes') {
            final args = (envelope['payload'] as Map)['args'] as Map;
            final range = (args['options'] as Map)['range'] as Map;
            final offset = range['offset'] as int;
            host.offsets.add(offset);
            final end = (offset + 2).clamp(0, host.file.length);
            final data = host.file.sublist(offset, end);
            value = {
              'absolutePath': '/synthetic/file',
              'bytes': host.file.length,
              'offset': offset,
              'data': data,
              'eof': offset + data.length >= host.file.length,
              'version': 'v1',
            };
          } else {
            throw StateError('Unexpected route ${request.uri.path}');
          }
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'type': 'server-response',
              'rpcId': envelope['rpcId'],
              'result': {'ok': true, 'value': value},
            }),
          );
        }
        await request.response.close();
      } catch (error) {
        request.response.statusCode = 500;
        await request.response.close();
      }
    });
    return host;
  }

  Future<void> close() async {
    await client.close();
    await server.close(force: true);
  }
}

void main() {
  test('readFile without offset walks the whole file', () async {
    final host = await _Files.start();
    addTearDown(host.close);
    final chunks = <List<int>>[], progress = <int>[];
    final read = host.client.readFile(
      's',
      'file',
      onChunk: (bytes) => chunks.add(bytes.toList()),
      onProgress: (received, _) => progress.add(received),
    );
    expect(await read, 8);
    expect(host.offsets, [0, 2, 4, 6]);
    expect(chunks, [
      [1, 2],
      [3, 4],
      [5, 6],
      [7, 8],
    ]);
    expect(progress, [0, 2, 4, 6, 8]);
    expect(host.fallbackReads, 0);
  });

  test('readFile from an offset serves only the tail and reports absolute bytes', () async {
    final host = await _Files.start();
    addTearDown(host.close);
    final chunks = <List<int>>[], progress = <int>[];
    final read = host.client.readFile(
      's',
      'file',
      offset: 4,
      onChunk: (bytes) => chunks.add(bytes.toList()),
      onProgress: (received, _) => progress.add(received),
    );
    expect(await read, 8);
    expect(host.offsets, [4, 6]);
    expect(chunks, [
      [5, 6],
      [7, 8],
    ]);
    expect(progress, [4, 6, 8]);
  });

  test('an offset at the end of the file is a single empty eof window', () async {
    final host = await _Files.start();
    addTearDown(host.close);
    final chunks = <List<int>>[];
    final read = host.client.readFile(
      's',
      'file',
      offset: 8,
      onChunk: chunks.add,
    );
    expect(await read, 8);
    expect(host.offsets, [8]);
    expect(chunks, isEmpty);
  });
}
