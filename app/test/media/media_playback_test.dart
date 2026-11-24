// MediaPlayback 引擎的直接测试:seek 加固是续播后「拉回开头播不动」的根治,
// 这里锁住三条铁律——命令不丢、位置钉住、存档按目标写(开头=清档)。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/media/media_playback.dart';
import 'package:dsh_app/media/video.dart';
import 'package:dsh_app/media/video_progress.dart';
import 'package:dsh_app/state/artifact_files.dart';
import 'package:dsh_app/state/artifacts.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _handle = MediaVideoHandle(texture: 17, width: 1920, height: 1080, durationMs: 5000);
const _audioHandle = MediaVideoHandle(texture: 18, width: 0, height: 0, durationMs: 5000, audioOnly: true);
const _path = '/host/voice.mp3';

class _Files extends ArtifactFiles {
  _Files() : super(connection: null, channel: const FilesChannel());
  int reads = 0;
  @override
  bool get isLocal => false;
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
    return File('/phone/voice.mp3');
  }
}

class _Video extends MediaVideoChannel {
  final trace = <String>[];
  int position = 0;
  bool playing = false;
  bool seekMovesPosition = true;

  /// 命令卡住的窗口:seek 要能穿过它,不能被丢。
  Completer<void>? blockCommands;

  @override
  Future<MediaVideoHandle> open(String path) async {
    trace.add('open');
    return _handle;
  }

  @override
  Future<void> play(int texture) async {
    trace.add('play');
    if (blockCommands != null) await blockCommands!.future;
    playing = true;
  }

  @override
  Future<void> pause(int texture) async {
    trace.add('pause');
    if (blockCommands != null) await blockCommands!.future;
    playing = false;
  }

  @override
  Future<void> seek(int texture, int positionMs) async {
    trace.add('seek:$positionMs');
    if (blockCommands != null) await blockCommands!.future;
    if (seekMovesPosition) position = positionMs;
  }

  @override
  Future<void> close(int texture) async {
    trace.add('close');
  }

  @override
  Future<MediaVideoState> state(int texture) async =>
      MediaVideoState(positionMs: position, durationMs: 5000, playing: playing);
}

class _AudioVideo extends _Video {
  @override
  Future<MediaVideoHandle> open(String path) async {
    trace.add('open');
    return _audioHandle;
  }

  @override
  Future<Uint8List?> frame(String path, int timeMs) async {
    trace.add('frame:$timeMs');
    return null;
  }
}

MediaPlayback _playback(_Video video, {String? mime}) => MediaPlayback(
  files: _Files(),
  video: video,
  sessionId: 's1',
  path: _path,
  name: 'voice.mp3',
  mime: mime ?? 'audio/mpeg',
);

String _key() => VideoProgressStore.keyFor(hostId: null, sessionId: 's1', path: _path);

Future<Map<String, Object?>?> _stored() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(videoProgressPrefsKey);
  return raw == null ? null : jsonDecode(raw) as Map<String, Object?>;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('seek 穿过进行中的命令:暂停没完成,拉回开头也不丢', () async {
    SharedPreferences.setMockInitialValues({
      videoProgressPrefsKey: jsonEncode({
        _key(): {'positionMs': 2000, 'durationMs': 5000, 'updatedAt': 1700000000000},
      }),
    });
    final video = _Video();
    final playback = _playback(video)..open();
    // 引擎打开:无前台生命周期,续播定位但不自动播。
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(video.trace, ['open', 'seek:2000'], reason: '续播定位到位');

    // 暂停命令卡在通道里(慢设备/长往返),此刻用户拉回开头:
    video.blockCommands = Completer<void>();
    playback.togglePlay(); // 未播 → 起播命令(卡住)
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final seekDone = playback.seekTo(0);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(playback.commanding, isTrue, reason: '前提:命令还在飞');
    video.blockCommands!.complete();
    await seekDone;
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(video.trace.contains('seek:0'), isTrue, reason: 'seek 不能被互斥丢掉');
    // 开头=清档:下次打开从 0 开始,不会再被旧续播点拽回去。
    expect(await _stored(), isNull);
    playback.dispose();
  });

  test('位置钉在 seek 目标:确认循环没等到就再发一次', () async {
    SharedPreferences.setMockInitialValues({});
    final video = _Video()..seekMovesPosition = false;
    video.position = 2000;
    final playback = _playback(video)..open();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    final done = playback.seekTo(0);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(playback.displayMs, 0, reason: '确认前 UI 钉在目标,不回跳旧位置');
    await done;

    final seeks = video.trace.where((step) => step == 'seek:0');
    expect(seeks, hasLength(2), reason: '第一发没确认,自动补了一发');
    expect(playback.displayMs, 2000, reason: '播放器真没动,放开钉位回到实况');
    playback.dispose();
  });

  test('audio-only:拖动不抽帧,seek 与存档照常', () async {
    SharedPreferences.setMockInitialValues({});
    final video = _AudioVideo();
    final playback = _playback(video)..open();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(playback.audioOnly, isTrue);

    playback.dragTo(2000);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    playback.dragEnd(2000);
    // seek 确认轮询的第一拍在 160ms;存档在确认后落笔,给足时间。
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(video.trace.any((step) => step.startsWith('frame:')), isFalse, reason: '音频没有帧');
    expect(video.trace.contains('seek:2000'), isTrue);
    final stored = await _stored();
    expect(stored?[_key()], isNotNull);
    expect((stored![_key()]! as Map)['positionMs'], 2000);
    playback.dispose();
  });
}
