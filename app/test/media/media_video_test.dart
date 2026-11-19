import 'dart:async';
import 'dart:io';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/media/gallery.dart';
import 'package:dsh_app/media/video.dart';
import 'package:dsh_app/media/video_stream_server.dart';
import 'package:dsh_app/state/artifact_files.dart';
import 'package:dsh_app/state/artifacts.dart';
import 'package:dsh_app/ui/chat/media/media_video_viewer.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _item = MediaItem(path: '/host/movie.mp4', mime: 'video/mp4');
const _handle = MediaVideoHandle(texture: 17, width: 1920, height: 1080, durationMs: 5000);

class _Files extends ArtifactFiles {
  _Files({this.local = false}) : super(connection: null, channel: const FilesChannel());
  final bool local;
  int reads = 0;
  int external = 0;
  @override
  bool get isLocal => local;
  @override
  bool get canFetch => true;
  @override
  Future<File> materialize(
    String sessionId,
    Artifact artifact, {
    void Function(double?)? onProgress,
    int maxBytes = maxRemoteArtifactBytes,
    String? taskLabel,
  }) async {
    reads++;
    onProgress?.call(0.5);
    return File('/phone/movie.mp4');
  }

  @override
  Future<void> open(
    String sessionId,
    Artifact artifact, {
    bool chooser = false,
    void Function(double?)? onProgress,
  }) async {
    external++;
  }
}

class _Video extends MediaVideoChannel {
  int posters = 0;
  int plays = 0;
  int pauses = 0;
  int closes = 0;
  int opens = 0;
  int position = 0;
  bool playing = false;
  bool failOpen = false;
  Completer<MediaVideoHandle>? delayedOpen;
  @override
  Future<Uint8List?> poster(String path) async {
    posters++;
    return Uint8List.fromList([1, 2, 3]);
  }

  @override
  Future<MediaVideoHandle> open(String path) async {
    opens++;
    if (failOpen) throw PlatformException(code: 'unsupported');
    return delayedOpen == null ? _handle : delayedOpen!.future;
  }

  @override
  Future<void> play(int texture) async {
    plays++;
    // ignore: avoid_print
    print('PROBE play#$plays at ${DateTime.now().microsecondsSinceEpoch % 10000000}');
    playing = true;
  }

  @override
  Future<void> pause(int texture) async {
    pauses++;
    playing = false;
  }

  @override
  Future<void> close(int texture) async {
    closes++;
    playing = false;
  }

  @override
  Future<void> seek(int texture, int positionMs) async {
    position = positionMs;
  }

  @override
  Future<MediaVideoState> state(int texture) async =>
      MediaVideoState(positionMs: position, durationMs: 5000, playing: playing);
}

class _StreamVideo extends _Video {
  int urlOpens = 0;
  int posterUrls = 0;
  bool failUrlOpen = false;
  Object? urlOpenError;
  final speeds = <double>[];
  @override
  bool get supportsUrlSource => true;
  @override
  Future<void> speed(int texture, double rate) async {
    speeds.add(rate);
  }
  @override
  Future<MediaVideoHandle> openUrl(String url) async {
    urlOpens++;
    if (!url.startsWith('http://127.0.0.1:')) throw ArgumentError.value(url, 'url', 'expected the loopback proxy');
    if (failUrlOpen) throw urlOpenError ?? PlatformException(code: 'playback');
    return _handle;
  }
  @override
  Future<Uint8List?> posterUrl(String url) async {
    posterUrls++;
    return Uint8List.fromList([9, 8, 7]);
  }
}

class _StreamServer extends VideoStreamServer {
  int opens = 0;
  @override
  Future<VideoStreamSession> openStream({required VideoByteSource source}) async {
    opens++;
    return VideoStreamSession(this, Uri.parse('http://127.0.0.1:9/v/token$opens/movie.mp4'));
  }
}

Future<void> _doubleTap(WidgetTester tester) async {
  await tester.tap(find.byType(Texture));
  await tester.pump(const Duration(milliseconds: 60));
  await tester.tap(find.byType(Texture));
  await tester.pump();
}

Future<void> _pumpViewer(WidgetTester tester, _Files files, _Video video, [VideoStreamServer? streams]) async {
  await tester.pumpWidget(
    MaterialApp(
      home: MediaVideoViewerPage(
        sessionId: 's1',
        item: _item,
        files: files,
        video: video,
        gallery: const MediaChannel(),
        streamServer: streams,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('channel rejects URL and relative paths without platform invocation', () async {
    const video = MediaVideoChannel();
    for (final path in [
      'https://example.com/movie.mp4',
      'file:///tmp/movie.mp4',
      'content://media/1',
      'relative.mp4',
    ]) {
      expect(() => video.poster(path), throwsArgumentError);
      await expectLater(video.open(path), throwsArgumentError);
    }
  });

  test('channel forwards local texture controls, seek and state', () async {
    const channel = MethodChannel('test/video');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'open' => {'texture': 17, 'width': 1920, 'height': 1080, 'durationMs': 5000},
        'state' => {'positionMs': 1200, 'durationMs': 5000, 'playing': true},
        _ => null,
      };
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
    );
    const video = MediaVideoChannel(channel);
    final handle = await video.open('/phone/movie.mp4');
    expect(handle.aspectRatio, 1920 / 1080);
    await video.play(handle.texture);
    await video.seek(handle.texture, 1200);
    expect((await video.state(handle.texture)).positionMs, 1200);
    await video.speed(handle.texture, 2.0);
    await video.pause(handle.texture);
    await video.close(handle.texture);
    expect(calls.map((c) => c.method), ['open', 'play', 'seek', 'state', 'speed', 'pause', 'close']);
    expect(calls[2].arguments, {'texture': 17, 'positionMs': 1200});
    expect(calls[4].arguments, {'texture': 17, 'rate': 2.0});
  });

  test('remote scrolling never materializes or extracts a poster', () async {
    final files = _Files();
    final video = _Video();
    expect(await mediaVideoThumbnail(files, video, 's1', _item), isNull);
    expect(files.reads, 0);
    expect(video.posters, 0);
    final poster = await cacheMediaVideoThumbnail(files, video, 's1', _item, materialized: File('/phone/movie.mp4'));
    expect(poster, isA<MemoryImage>());
    expect(await mediaVideoThumbnail(files, video, 's1', _item), same(poster));
    expect(files.reads, 0);
    expect(video.posters, 1);
    // Same path on another Host snapshot must not see the first Host's poster.
    expect(await mediaVideoThumbnail(_Files(), video, 's1', _item), isNull);
  });

  test('local thumbnails materialize once and deduplicate extraction', () async {
    final files = _Files(local: true);
    final video = _Video();
    final one = mediaVideoThumbnail(files, video, 's1', _item);
    final two = mediaVideoThumbnail(files, video, 's1', _item);
    expect(await one, same(await two));
    expect(files.reads, 1);
    expect(video.posters, 1);
  });

  test('concurrent local video cards serialize decoder requests without dropping posters', () async {
    const channel = MethodChannel('test/concurrent-video-posters');
    var active = 0;
    var maximum = 0;
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      active++;
      calls++;
      if (active > maximum) maximum = active;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      active--;
      return Uint8List.fromList([1, 2, 3]);
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
    );
    final files = _Files(local: true);
    final posters = await Future.wait([
      for (var i = 0; i < 3; i++)
        mediaVideoThumbnail(files, const MediaVideoChannel(channel), 's1', MediaItem(path: '/host/movie-$i.mp4')),
    ]);
    expect(posters, everyElement(isA<MemoryImage>()));
    expect(calls, 3);
    expect(maximum, 1);
    expect(files.reads, 3);
  });

  test('poster queue continues after an extraction failure', () async {
    const channel = MethodChannel('test/poster-error-queue');
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (++calls == 1) throw PlatformException(code: 'timeout');
      return Uint8List.fromList([1]);
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
    );
    const video = MediaVideoChannel(channel);
    final failed = video.poster('/phone/one.mp4');
    final next = video.poster('/phone/two.mp4');
    await expectLater(failed, throwsA(isA<PlatformException>()));
    expect(await next, isNotNull);
    expect(calls, 2);
  });

  test('video gallery save sends path not complete video bytes', () async {
    const channel = MethodChannel('test/gallery-video');
    MethodCall? captured;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      captured = call;
      return 'Movies/Wanqi/movie.mp4';
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
    );
    expect(
      await const MediaChannel(channel).saveVideoFile('/phone/movie.mp4', name: 'movie.mp4'),
      'Movies/Wanqi/movie.mp4',
    );
    expect(captured!.method, 'saveVideoFile');
    expect(captured!.arguments, {'path': '/phone/movie.mp4', 'name': 'movie.mp4'});
  });

  test('time labels clamp negative position', () {
    expect(mediaVideoTime(-1), '0:00');
    expect(mediaVideoTime(65_999), '1:05');
  });

  testWidgets('late prepared player is released after viewer disposal', (tester) async {
    final files = _Files();
    final video = _Video()..delayedOpen = Completer<MediaVideoHandle>();
    await _pumpViewer(tester, files, video);
    expect(video.opens, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    video.delayedOpen!.complete(_handle);
    await tester.pump();
    expect(video.closes, 1);
    expect(video.plays, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unsupported playback can retry or open original Host externally', (tester) async {
    final files = _Files();
    final video = _Video()..failOpen = true;
    await _pumpViewer(tester, files, video);
    expect(find.text(appL10n.mediaVideoCannotPlay), findsOneWidget);
    await tester.tap(find.byTooltip(appL10n.mediaOpenElsewhere));
    await tester.pump();
    expect(files.external, 1);
    video.failOpen = false;
    await tester.tap(find.text(appL10n.commonRetry));
    await tester.pump();
    await tester.pump();
    expect(video.opens, 2);
    expect(files.reads, 1);
    expect(find.byType(Texture), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(video.closes, 1);
  });

  testWidgets('background transition pauses and disposal releases playback', (tester) async {
    final files = _Files();
    final video = _Video();
    await _pumpViewer(tester, files, video);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(video.pauses, greaterThan(0));
    expect(find.byIcon(AppIcons.mediaPlay), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(video.closes, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  test('channel rejects foreign URLs for playback and poster extraction', () async {
    const video = MediaVideoChannel();
    for (final url in [
      'https://127.0.0.1/v/t/a.mp4',
      'http://192.168.1.5:8080/v/t/a.mp4',
      'http://example.com/v/t/a.mp4',
      'file:///tmp/a.mp4',
      'not a url',
    ]) {
      expect(() => video.openUrl(url), throwsArgumentError);
      expect(() => video.posterUrl(url), throwsArgumentError);
    }
  });

  test('channel forwards loopback openUrl to the platform', () async {
    const channel = MethodChannel('test/video-url');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return {'texture': 5, 'width': 640, 'height': 360, 'durationMs': 1200};
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
    );
    const video = MediaVideoChannel(channel);
    final handle = await video.openUrl('http://127.0.0.1:41235/v/abc/movie.mp4');
    expect(handle.texture, 5);
    expect(handle.aspectRatio, 640 / 360);
    expect(calls.single.method, 'openUrl');
    expect(calls.single.arguments, {'url': 'http://127.0.0.1:41235/v/abc/movie.mp4'});
  });

  testWidgets('remote videos stream over the loopback proxy and download only on save', (tester) async {
    final files = _Files();
    final video = _StreamVideo();
    final streams = _StreamServer();
    await _pumpViewer(tester, files, video, streams);
    expect(video.urlOpens, 1);
    expect(streams.opens, 1);
    expect(files.reads, 0, reason: 'streaming must not materialize the whole video');
    expect(find.byType(Texture), findsOneWidget);
    await tester.pump();
    expect(video.posterUrls, 1, reason: 'the streamed open seeds the card poster');
    // The top-right save is the only path that downloads the file.
    await tester.tap(find.byIcon(AppIcons.save));
    await tester.pump();
    await tester.pump();
    expect(files.reads, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(video.closes, 1);
  });

  testWidgets('a failed stream falls back to downloading once', (tester) async {
    final files = _Files();
    final video = _StreamVideo()
      ..failUrlOpen = true
      ..urlOpenError = PlatformException(code: 'playback');
    await _pumpViewer(tester, files, video, _StreamServer());
    expect(video.urlOpens, 1);
    expect(files.reads, 1);
    expect(video.opens, 1);
    expect(find.byType(Texture), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('an unsupported source stops trying to stream on retry', (tester) async {
    final files = _Files();
    final video = _StreamVideo()
      ..failUrlOpen = true
      ..urlOpenError = PlatformException(code: 'unsupported')
      ..failOpen = true;
    await _pumpViewer(tester, files, video, _StreamServer());
    expect(video.urlOpens, 1);
    expect(files.reads, 1);
    expect(find.text(appL10n.mediaVideoCannotPlay), findsOneWidget);
    video.failUrlOpen = false;
    video.failOpen = false;
    await tester.tap(find.text(appL10n.commonRetry));
    await tester.pump();
    await tester.pump();
    expect(video.urlOpens, 1, reason: 'a refused source is refused downloaded too');
    expect(files.reads, 1, reason: 'the downloaded copy is reused');
    expect(video.opens, 2);
    expect(find.byType(Texture), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
  testWidgets('double-tap toggles play and pause', (tester) async {
    final files = _Files();
    final video = _StreamVideo();
    await _pumpViewer(tester, files, video, _StreamServer());
    await _doubleTap(tester);
    expect(video.plays, 1);
    await _doubleTap(tester);
    expect(video.pauses, 1);
    // 单击窗口 timer 泵过它,免得测试收尾报 pending timer。
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('long-press boosts playback speed back to normal on release', (tester) async {
    final files = _Files();
    final video = _StreamVideo();
    await _pumpViewer(tester, files, video, _StreamServer());
    await _doubleTap(tester); // 播放中才倍速;暂停中长按不起播。
    await tester.pump();
    await tester.longPress(find.byType(Texture));
    await tester.pump();
    expect(video.speeds, [2.0, 1.0]);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('a single tap toggles the controls and never starts playback', (tester) async {
    final files = _Files();
    final video = _StreamVideo();
    await _pumpViewer(tester, files, video, _StreamServer());
    expect(find.byIcon(AppIcons.save), findsOneWidget, reason: '控制层浮在画面上');
    await tester.tap(find.byType(Texture));
    await tester.pump();
    expect(find.byIcon(AppIcons.save), findsNothing, reason: '单击隐藏控制层');
    expect(video.plays, 0, reason: '单击绝不播放');
    await tester.pump(const Duration(milliseconds: 350)); // 关掉单击窗口
    await tester.tap(find.byType(Texture));
    await tester.pump();
    expect(find.byIcon(AppIcons.save), findsOneWidget, reason: '再单击显示控制层');
    expect(video.plays, 0);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('horizontal drag previews and seeks the position', (tester) async {
    final files = _Files();
    final video = _StreamVideo();
    await _pumpViewer(tester, files, video, _StreamServer());
    final width = MediaQuery.sizeOf(tester.element(find.byType(Texture))).width;
    final dx = (width * 0.1).round(); // 10% of the screen ≈ 12s; duration clamps to 5s.
    await tester.drag(find.byType(Texture), Offset(dx.toDouble(), 0));
    await tester.pump();
    final expected = (dx / width * 120 * 1000).round().clamp(0, 5000);
    expect(video.position, expected, reason: 'drag preview target became the seek');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
