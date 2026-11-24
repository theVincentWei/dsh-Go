import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/artifact_files.dart';
import '../state/artifacts.dart';

/// No URL entry point: the caller must materialize through its captured Host.
/// The one exception is a loopback [VideoStreamServer] URL, see [openUrl].
class MediaVideoChannel {
  const MediaVideoChannel([this.channel = const MethodChannel('dsh/media_video')]);
  final MethodChannel channel;

  /// Whether this build's platform player accepts loopback stream URLs at
  /// all. Android ships a URL-aware player; other platforms keep the
  /// download-first path.
  bool get supportsUrlSource => !kIsWeb && Platform.isAndroid;

  /// Whether this build can extract a frame at an arbitrary timestamp
  /// (拖动进度条的画面预览). Android ships a retriever-based extractor.
  bool get supportsFrameExtraction => !kIsWeb && Platform.isAndroid;

  // One decoder request at a time across channel instances. Queued requests
  // retain paths only, never decoded frames or full video buffers.
  static Future<void> _posterTail = Future<void>.value();

  Future<MediaVideoHandle> open(String path) async {
    _localPath(path);
    return _fromOpen(await channel.invokeMapMethod<String, dynamic>('open', {'path': path}));
  }

  /// Opens a video from a loopback streaming URL (`http://127.0.0.1:…`, as
  /// produced by [VideoStreamServer]). The player pulls HTTP ranges; the
  /// server translates them into Host byte windows.
  Future<MediaVideoHandle> openUrl(String url) async {
    _loopbackUrl(url);
    return _fromOpen(await channel.invokeMapMethod<String, dynamic>('openUrl', {'url': url}));
  }

  static MediaVideoHandle _fromOpen(Object? value) {
    if (value == null) throw PlatformException(code: 'unsupported');
    if (value case {'texture': final num texture, 'durationMs': final num duration}) {
      final width = (value['width'] as num?)?.toInt() ?? 0;
      final height = (value['height'] as num?)?.toInt() ?? 0;
      return MediaVideoHandle(
        texture: texture.toInt(),
        width: width,
        height: height,
        durationMs: duration.toInt(),
        audioOnly: value['audioOnly'] == true || (width <= 0 || height <= 0),
      );
    }
    throw PlatformException(code: 'unsupported');
  }

  Future<Uint8List?> poster(String path) {
    _localPath(path);
    return _poster('poster', {'path': path});
  }

  /// The same extraction for a loopback streaming URL, so a streamed video
  /// seeds its card poster without the whole file being downloaded.
  Future<Uint8List?> posterUrl(String url) {
    _loopbackUrl(url);
    return _poster('posterUrl', {'url': url});
  }

  Future<Uint8List?> _poster(String method, Map<String, Object?> arguments) {
    final request = _posterTail.then((_) => channel.invokeMethod<Uint8List>(method, arguments));
    _posterTail = request.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return request;
  }

  /// One preview frame at [timeMs] from a local materialized file
  /// (拖动进度条的缩略图). Null when the decoder cannot answer — the
  /// preview is decoration, never a gate. Serialized platform-side like
  /// posters so a broken decoder cannot queue up workers.
  Future<Uint8List?> frame(String path, int timeMs) {
    _localPath(path);
    return channel.invokeMethod<Uint8List>('frame', {'path': path, 'timeMs': timeMs});
  }

  /// The same extraction from a loopback streaming URL: only the ranges the
  /// extractor asks for are pulled, the whole file is never downloaded.
  Future<Uint8List?> frameUrl(String url, int timeMs) {
    _loopbackUrl(url);
    return channel.invokeMethod<Uint8List>('frameUrl', {'url': url, 'timeMs': timeMs});
  }

  Future<void> play(int texture) => channel.invokeMethod<void>('play', {'texture': texture});
  Future<void> pause(int texture) => channel.invokeMethod<void>('pause', {'texture': texture});
  Future<void> seek(int texture, int positionMs) =>
      channel.invokeMethod<void>('seek', {'texture': texture, 'positionMs': positionMs});

  /// Temporary playback rate (长按倍速). 1.0 restores normal speed.
  Future<void> speed(int texture, double rate) =>
      channel.invokeMethod<void>('speed', {'texture': texture, 'rate': rate});
  Future<void> close(int texture) => channel.invokeMethod<void>('close', {'texture': texture});
  Future<MediaVideoState> state(int texture) async {
    final value = await channel.invokeMapMethod<String, dynamic>('state', {'texture': texture});
    if (value == null) throw PlatformException(code: 'closed');
    return MediaVideoState(
      positionMs: (value['positionMs'] as num).toInt(),
      durationMs: (value['durationMs'] as num).toInt(),
      playing: value['playing'] == true,
      buffering: value['buffering'] == true,
    );
  }

  static void _localPath(String path) {
    if (!path.startsWith('/') || Uri.tryParse(path)?.hasScheme == true) {
      throw ArgumentError.value(path, 'path', 'Expected an absolute local materialized file');
    }
  }

  static void _loopbackUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'http' || !_isLoopback(uri.host)) {
      throw ArgumentError.value(url, 'url', 'Expected a loopback streaming URL');
    }
  }

  static bool _isLoopback(String host) {
    final lowered = host.toLowerCase();
    if (lowered == 'localhost' || lowered == '127.0.0.1' || lowered == '[::1]' || lowered == '::1') return true;
    final address = InternetAddress.tryParse(host);
    return address != null && address.isLoopback;
  }
}

class MediaVideoHandle {
  const MediaVideoHandle({
    required this.texture,
    required this.width,
    required this.height,
    required this.durationMs,
    this.audioOnly = false,
  });
  final int texture;
  final int width;
  final int height;
  final int durationMs;

  /// 没有视频轨(纯音频):画面层走音频形态,不渲染纹理、不锁屏。
  final bool audioOnly;
  double get aspectRatio => width > 0 && height > 0 ? width / height : 16 / 9;
}

class MediaVideoState {
  const MediaVideoState({
    required this.positionMs,
    required this.durationMs,
    required this.playing,
    this.buffering = false,
  });
  final int positionMs;
  final int durationMs;
  final bool playing;

  /// The platform player is waiting on more bytes (缓冲中): the UI shows a
  /// spinner so a stall reads as buffering, not as a broken video.
  final bool buffering;
}

final mediaVideoChannelProvider = Provider<MediaVideoChannel>((ref) => const MediaVideoChannel());

// Keyed by captured ArtifactFiles, not a mutable active-host provider. Bounded
// per Host snapshot, with weak ownership when that connection is discarded.
final _posters = Expando<Map<(String, String), Future<ImageProvider?>>>();

/// Card thumbnail: NEVER downloads a remote video simply because it scrolled
/// into view. Remote posters become available after an explicit viewer open.
Future<ImageProvider?> mediaVideoThumbnail(
  ArtifactFiles files,
  MediaVideoChannel video,
  String sessionId,
  MediaItem item,
) {
  final cache = _posters[files] ??= {};
  final key = (sessionId, item.path);
  if (cache[key] case final existing?) return existing;
  if (!files.isLocal) return Future.value(null);
  return cacheMediaVideoThumbnail(files, video, sessionId, item);
}

/// After user-requested materialization, also seed the card's remote poster.
Future<ImageProvider?> cacheMediaVideoThumbnail(
  ArtifactFiles files,
  MediaVideoChannel video,
  String sessionId,
  MediaItem item, {
  File? materialized,
}) {
  final cache = _posters[files] ??= {};
  final key = (sessionId, item.path);
  if (cache[key] case final existing?) return existing;
  if (materialized == null && !files.isLocal) return Future.value(null);
  if (cache.length >= 24) cache.remove(cache.keys.first);
  final future = () async {
    try {
      final file =
          materialized ??
          await files.materialize(sessionId, Artifact(path: item.path, origin: ArtifactOrigin.linked, turn: 0));
      final bytes = await video.poster(file.path);
      return bytes == null || bytes.isEmpty ? null : MemoryImage(bytes);
    } catch (_) {
      // Optional decoration: a failed poster never prevents playback or retries.
      return null;
    }
  }();
  cache[key] = future;
  future.then((value) {
    if (value == null && identical(cache[key], future)) cache.remove(key);
  });
  return future;
}

/// After a streamed open, seed the card's poster straight from the loopback
/// stream — no download, only the few ranges the extractor asks for.
Future<ImageProvider?> cacheStreamedVideoPoster(
  ArtifactFiles files,
  MediaVideoChannel video,
  String sessionId,
  MediaItem item,
  String url,
) {
  final cache = _posters[files] ??= {};
  final key = (sessionId, item.path);
  if (cache[key] case final existing?) return existing;
  if (cache.length >= 24) cache.remove(cache.keys.first);
  final future = () async {
    try {
      final bytes = await video.posterUrl(url);
      return bytes == null || bytes.isEmpty ? null : MemoryImage(bytes);
    } catch (_) {
      // Optional decoration: a failed poster never prevents playback.
      return null;
    }
  }();
  cache[key] = future;
  future.then((value) {
    if (value == null && identical(cache[key], future)) cache.remove(key);
  });
  return future;
}

String mediaVideoTime(int milliseconds) {
  final seconds = milliseconds < 0 ? 0 : milliseconds ~/ 1000;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}
