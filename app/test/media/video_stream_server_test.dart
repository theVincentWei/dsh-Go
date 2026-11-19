import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dsh_app/media/video_stream_server.dart';
import 'package:flutter_test/flutter_test.dart';

class _CountingSource implements VideoByteSource {
  _CountingSource(this._data, {this.type = 'video/mp4', this.delay = Duration.zero});

  final Uint8List _data;
  final String type;
  final Duration delay;
  final List<(int, int)> calls = [];

  @override
  String get contentType => type;

  @override
  String get displayName => 'movie.mp4';

  @override
  Future<int> totalBytes() async => _data.length;

  @override
  Future<Uint8List> window(int offset, int length) async {
    final end = min(offset + length, _data.length);
    calls.add((offset, end));
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    return Uint8List.sublistView(_data, offset, end);
  }

  Uint8List slice(int start, int end) => Uint8List.sublistView(_data, start, end);
}

void main() {
  final data = Uint8List.fromList([
    for (var i = 0; i < 2 * 1024 * 1024 + 17; i++) i % 251,
  ]);
  late VideoStreamServer server;
  late VideoStreamSession session;

  setUp(() async {
    server = VideoStreamServer();
    session = await server.openStream(source: _CountingSource(data));
    expect(session.url.host, '127.0.0.1');
    expect(session.url.pathSegments.first, 'v');
  });

  tearDown(() async {
    await server.shutdown();
  });

  Future<HttpClientResponse> get(Uri url, {String? range}) async {
    final client = HttpClient();
    final request = await client.getUrl(url);
    if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
    final response = await request.close();
    client.close();
    return response;
  }

  Future<Uint8List> drain(HttpClientResponse response) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  test('a loopback URL is served for the registered session only', () async {
    final foreign = Uri.parse(session.url.toString().replaceFirst('/v/', '/v/deadbeef'));
    final response = await get(foreign);
    expect(response.statusCode, 404);
    final missing = Uri.parse('http://${session.url.host}:${session.url.port}/nowhere');
    expect((await get(missing)).statusCode, 404);
  });

  test('an open-ended range streams the full remainder in one response', () async {
    final response = await get(session.url, range: 'bytes=0-');
    expect(response.statusCode, 206);
    expect(response.headers.value(HttpHeaders.acceptRangesHeader), 'bytes');
    expect(response.headers.value(HttpHeaders.contentRangeHeader), 'bytes 0-${data.length - 1}/${data.length}');
    final body = await drain(response);
    expect(body.length, data.length);
    expect(body, data);
  });

  test('a request without a range header behaves like bytes=0-', () async {
    final response = await get(session.url);
    expect(response.statusCode, 206);
    expect(response.headers.value(HttpHeaders.contentRangeHeader), 'bytes 0-${data.length - 1}/${data.length}');
    expect(await drain(response), data);
  });

  test('an explicit range straddling window boundaries is exact', () async {
    const start = 1024 * 1024 - 6;
    const end = 1024 * 1024 + 6;
    final response = await get(session.url, range: 'bytes=$start-$end');
    expect(response.statusCode, 206);
    expect(response.headers.value(HttpHeaders.contentRangeHeader), 'bytes $start-$end/${data.length}');
    final body = await drain(response);
    expect(body.length, end - start + 1);
    expect(body, data.sublist(start, end + 1));
  });

  test('a suffix range reads the tail', () async {
    final response = await get(session.url, range: 'bytes=-5');
    expect(response.statusCode, 206);
    expect(response.headers.value(HttpHeaders.contentRangeHeader), 'bytes ${data.length - 5}-${data.length - 1}/${data.length}');
    expect(await drain(response), data.sublist(data.length - 5));
  });

  test('an end past EOF clamps to the file', () async {
    final response = await get(session.url, range: 'bytes=${data.length - 10}-999999999');
    expect(response.statusCode, 206);
    expect(response.headers.value(HttpHeaders.contentRangeHeader), 'bytes ${data.length - 10}-${data.length - 1}/${data.length}');
    final body = await drain(response);
    expect(body.length, 10);
    expect(body, data.sublist(data.length - 10));
  });

  test('unsatisfiable and foreign ranges answer 416 with the real extent', () async {
    final response = await get(session.url, range: 'bytes=${data.length}-');
    expect(response.statusCode, 416);
    expect(response.headers.value(HttpHeaders.contentRangeHeader), 'bytes */${data.length}');
    expect((await get(session.url, range: 'bytes=-0')).statusCode, 416);
  });

  test('cached windows serve repeat ranges without new source reads', () async {
    final source = _CountingSource(data);
    final local = await server.openStream(source: source);
    await drain(await get(local.url, range: 'bytes=0-999'));
    await drain(await get(local.url, range: 'bytes=0-999'));
    expect(source.calls.where((call) => call.$1 == 0).length, 1, reason: 'window 0 was fetched exactly once');
  });

  test('serving prefetches ahead so sequential playback stays warm', () async {
    final big = Uint8List.fromList([
      for (var i = 0; i < 8 * 1024 * 1024; i++) i % 251,
    ]);
    final source = _CountingSource(big);
    final local = await server.openStream(source: source);
    await drain(await get(local.url, range: 'bytes=0-999999'));
    // The whole 8 MiB file fits inside the prefetch horizon (12 MiB ahead of
    // the served position): every window lands warm after the response.
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (source.calls.length < 8 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(source.calls.length, greaterThanOrEqualTo(8));
    final offsets = source.calls.map((call) => call.$1).toList();
    expect(offsets.take(2), [0, 1024 * 1024]);
  });

  test('closing the session releases its URL', () async {
    await session.close();
    expect((await get(session.url, range: 'bytes=0-1')).statusCode, 404);
  });

  test('a disposed session stops serving mid-response quietly', () async {
    final source = _CountingSource(data, delay: const Duration(milliseconds: 30));
    final local = await server.openStream(source: source);
    final client = HttpClient();
    final request = await client.getUrl(local.url);
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-');
    final response = await request.close();
    await server.close(local.url);
    // 会话被丢弃:整段余量响应提前收线,客户端拿到半截内容是预期,服务端不崩。
    try {
      await drain(response);
    } on Object {
      // Client-side truncated response: expected after disposal.
    }
    client.close();
  });

  test('content type comes from the source', () async {
    final local = await server.openStream(source: _CountingSource(data, type: 'video/webm'));
    final response = await get(local.url, range: 'bytes=0-1');
    expect(response.headers.contentType?.mimeType, 'video/webm');
    await drain(response);
  });
}
