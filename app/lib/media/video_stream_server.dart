// A loopback HTTP server that feeds the platform video player straight from
// the Host: the player's HTTP Range requests map onto `workspaceFiles/readBytes`
// byte windows, so playback starts while the bytes are still arriving. The
// server binds 127.0.0.1 on an ephemeral port, serves only tokenized session
// paths created through [openStream], and never touches any other file — the
// bytes still flow through the captured Host's own channel.

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';

import '../state/artifact_files.dart';
import '../state/artifacts.dart';

/// One readBytes window. The Host caps a single window at 2 MiB; stay below.
const int videoStreamWindowBytes = 1024 * 1024;

/// Bytes fetched past the served position so steady playback never waits on
/// a window that has not been requested yet. Deep enough to ride out slow
/// RPC round-trips (remote tunnel) without starving the player's buffer.
const int videoStreamPrefetchBytes = 12 * 1024 * 1024;

/// Cache ceiling per session: the moov atom plus the played-through tail
/// stay warm for seeks backwards; distant windows fall off the front.
const int videoStreamCacheBytes = 32 * 1024 * 1024;

/// Idle sessions are swept on the next [VideoStreamServer.openStream].
const Duration videoStreamSessionIdle = Duration(minutes: 10);

/// At most this many registered streams; the oldest idle one retires first.
const int videoStreamMaxSessions = 8;

/// Where a stream's bytes come from: a captured Host's artifact, or a local
/// fixture in tests.
abstract class VideoByteSource {
  /// File size in bytes. A source without a known size is refused up front:
  /// every response needs Content-Length and a range ceiling.
  Future<int> totalBytes();

  /// The bytes at [offset]…+[length], fewer only at the end of the file.
  Future<Uint8List> window(int offset, int length);

  /// Content-Type for responses (`video/mp4`).
  String get contentType;

  /// File name for the URL path (display only).
  String get displayName;
}

/// [VideoByteSource] over one artifact of a captured [ArtifactFiles].
class ArtifactVideoByteSource implements VideoByteSource {
  ArtifactVideoByteSource({
    required this.files,
    required this.sessionId,
    required this.artifact,
    this.mime,
  });

  final ArtifactFiles files;
  final String sessionId;
  final Artifact artifact;

  /// MIME override when the caller knows it better than the extension.
  final String? mime;

  int? _total;
  String? _version;

  @override
  String get contentType {
    final override = mime;
    if (override != null && override.startsWith('video/')) return override;
    return artifact.mimeType;
  }

  @override
  String get displayName => artifact.name;

  @override
  Future<int> totalBytes() async {
    final cached = _total;
    if (cached != null) return cached;
    final conn = files.connection;
    if (conn == null) throw const ArtifactError('offline');
    if (!conn.client.canReadFileBytes) throw const ArtifactError('unsupported');
    final stat = await conn.client.statFile(sessionId, artifact.path);
    final bytes = stat.bytes;
    if (bytes == null || bytes <= 0) throw const ArtifactError('missing');
    _total = bytes;
    _version = stat.version.isEmpty ? null : stat.version;
    return bytes;
  }

  @override
  Future<Uint8List> window(int offset, int length) async {
    final conn = files.connection;
    if (conn == null) throw const ArtifactError('offline');
    final answer = await conn.client.readWindow(sessionId, artifact.path, offset: offset, length: length);
    final version = answer.version;
    if (version != null && version.isNotEmpty) {
      final expected = _version;
      if (expected != null && version != expected) {
        throw DshRemoteException('workspace-file/changed', '"${artifact.path}" changed while streaming', {
          'path': artifact.path,
        });
      }
      _version ??= version;
    }
    return answer.data;
  }
}

/// One registered stream: the URL the platform player plays, plus the close
/// that releases the session's cache. Creating one directly is for tests.
class VideoStreamSession {
  @visibleForTesting
  VideoStreamSession(this.server, this.url, {DateTime? now}) : lastAccess = now ?? DateTime.now();

  /// The URL for the platform player (`http://127.0.0.1:<port>/v/<token>/<name>`).
  final Uri url;

  /// The server this session belongs to; [close] unregisters there.
  final VideoStreamServer server;

  DateTime lastAccess;

  void touch() => lastAccess = DateTime.now();

  Future<void> close() => server.close(url);
}

/// The loopback stream server. Binds once per process, on demand, and stays
/// bound for the app's lifetime: loopback only, ephemeral port, paths carry
/// an unguessable token.
class VideoStreamServer {
  VideoStreamServer();

  static final VideoStreamServer instance = VideoStreamServer();

  HttpServer? _server;
  final Map<String, (VideoStreamSession, _StreamSession)> _sessions = {};

  /// Registers [source] and returns the session whose [VideoStreamSession.url]
  /// the platform player can play.
  Future<VideoStreamSession> openStream({required VideoByteSource source}) async {
    final server = _server ??= await _bind();
    final token = _token();
    final inner = _StreamSession(source);
    final public = VideoStreamSession(this, _urlOf(server, token, source.displayName));
    _sessions[token] = (public, inner);
    _sweep();
    return public;
  }

  /// Releases a session's cached windows and unregisters its URL.
  Future<void> close(Uri url) async {
    final token = _tokenOf(url);
    if (token == null) return;
    final (_, inner) = _sessions.remove(token) ?? (null, null);
    inner?.dispose();
  }

  /// How far this stream's bytes have been fetched: `(frontier, total)`, or
  /// null when the session is gone or its size is not known yet. The viewer
  /// maps the byte frontier onto the timeline for the 缓冲条 (a linear
  /// approximation — good enough for "下到哪了", not for frame seeking).
  (int, int)? bufferedSnapshot(Uri url) {
    final entry = _sessions[_tokenOf(url)];
    if (entry == null) return null;
    return entry.$2.bufferSnapshot();
  }

  /// Closes the socket and every session. Tests only.
  @visibleForTesting
  Future<void> shutdown() async {
    for (final (_, inner) in _sessions.values) {
      inner.dispose();
    }
    _sessions.clear();
    await _server?.close(force: true);
    _server = null;
  }

  Future<HttpServer> _bind() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(_route, onError: (Object _) {});
    return server;
  }

  void _route(HttpRequest request) {
    final entry = _sessions[_tokenOf(request.uri)];
    if (entry == null) {
      request.response.statusCode = HttpStatus.notFound;
      unawaited(request.response.close().catchError((Object _) {}));
      return;
    }
    final (public, inner) = entry;
    public.touch();
    unawaited(_serve(request, public, inner));
  }

  Future<void> _serve(HttpRequest request, VideoStreamSession public, _StreamSession inner) async {
    final response = request.response;
    try {
      final total = await inner.source.totalBytes();
      inner.noteTotal(total);
      final range = _parseRange(request.headers.value(HttpHeaders.rangeHeader), total);
      if (range == null) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total');
        await response.close();
        return;
      }
      final (start, requestedEnd) = range;
      // Open-ended ranges (the player's usual first request) declare the
      // full remainder and stream it for as long as the player keeps
      // reading: MediaPlayer does not always re-request after a short 206,
      // so a long-lived response is what keeps playback alive. Explicit
      // ranges are served exactly as asked.
      final end = requestedEnd ?? total - 1;
      response.statusCode = HttpStatus.partialContent;
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$total');
      response.headers.set(HttpHeaders.contentLengthHeader, end - start + 1);
      response.headers.contentType = ContentType.parse(inner.source.contentType);
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      var cursor = start;
      while (cursor <= end) {
        if (inner.disposed) break; // 会话已释放:收线,客户端按半截响应处理。
        final index = cursor ~/ videoStreamWindowBytes;
        final data = await inner.windowData(index);
        if (data.isEmpty) break;
        final offset = cursor - index * videoStreamWindowBytes;
        final take = min(data.length - offset, end - cursor + 1);
        if (take <= 0) break;
        response.add(Uint8List.sublistView(data, offset, offset + take));
        cursor += take;
        // Keep the fetch pipeline ahead of the playhead while the response
        // is open; flush gives backpressure so memory stays bounded.
        unawaited(inner.prefetchThrough(cursor + videoStreamPrefetchBytes, total));
        if (cursor ~/ videoStreamWindowBytes != index) await response.flush();
      }
      await response.close();
      unawaited(inner.prefetchThrough(end + videoStreamPrefetchBytes, total));
    } on Object {
      // A departed player or a failed window: answer nothing further. The
      // player surfaces its own playback error, and the viewer falls back to
      // downloading the file whole.
      try {
        await response.close();
      } on Object {
        // The socket may already be gone; nothing to answer.
      }
    }
  }

  /// `bytes=start-end`, `bytes=start-`, `bytes=-suffix`, or no header (the
  /// whole file from zero). Returns null for unsatisfiable or foreign ranges.
  (int, int?)? _parseRange(String? header, int total) {
    if (header == null) return (0, null);
    if (!header.startsWith('bytes=')) return null;
    final spec = header.substring('bytes='.length);
    final dash = spec.indexOf('-');
    if (dash < 0) return null;
    final first = spec.substring(0, dash).trim();
    final last = spec.substring(dash + 1).trim();
    int start;
    int? end;
    if (first.isEmpty) {
      final suffix = int.tryParse(last);
      if (suffix == null || suffix <= 0) return null;
      start = max(0, total - suffix);
      end = total - 1;
    } else {
      final parsed = int.tryParse(first);
      if (parsed == null) return null;
      start = parsed;
      if (last.isNotEmpty) end = int.tryParse(last);
    }
    if (start >= total) return null;
    if (end != null) {
      end = min(end, total - 1);
      if (end < start) return null;
    }
    return (start, end);
  }

  Uri _urlOf(HttpServer server, String token, String name) {
    final encoded = Uri.encodeComponent(name.isEmpty ? 'video' : name);
    return Uri(scheme: 'http', host: '127.0.0.1', port: server.port, path: '/v/$token/$encoded');
  }

  String? _tokenOf(Uri url) {
    final segments = url.pathSegments;
    if (segments.length < 3 || segments.first != 'v') return null;
    return segments[1];
  }

  void _sweep() {
    final idle = DateTime.now().subtract(videoStreamSessionIdle);
    for (final token in _sessions.keys.toList()) {
      final (public, _) = _sessions[token]!;
      if (public.lastAccess.isBefore(idle)) {
        final (_, inner) = _sessions.remove(token)!;
        inner.dispose();
      }
    }
    while (_sessions.length > videoStreamMaxSessions) {
      String? oldest;
      var stamp = DateTime.now();
      for (final MapEntry(key: token, value: (public, _)) in _sessions.entries) {
        if (public.lastAccess.isBefore(stamp)) {
          stamp = public.lastAccess;
          oldest = token;
        }
      }
      if (oldest == null) break;
      final (_, inner) = _sessions.remove(oldest)!;
      inner.dispose();
    }
  }

  String _token() {
    final random = Random.secure();
    return List.generate(16, (_) => random.nextInt(256)).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}

/// One registered video: window cache, in-flight dedupe, prefetch.
class _StreamSession {
  _StreamSession(this.source);

  final VideoByteSource source;
  final Map<int, Uint8List> _windows = {};
  final Map<int, Future<Uint8List>> _inflight = {};
  int _cachedBytes = 0;
  int _prefetchedTo = -1;

  /// Highest byte offset whose window has fully arrived, and the file size
  /// once known. Together they answer "缓冲到哪了" without asking the player.
  int _frontierBytes = 0;
  int? _totalBytes;
  bool _disposed = false;

  bool get disposed => _disposed;

  /// `(frontier, total)` or null before the size is known. The frontier never
  /// shrinks on eviction: it reports what has been downloaded, not what is
  /// still resident.
  (int, int)? bufferSnapshot() {
    final total = _totalBytes;
    if (total == null || total <= 0) return null;
    return (min(_frontierBytes, total), total);
  }

  void noteTotal(int total) => _totalBytes = total;

  void dispose() {
    _disposed = true;
    _inflight.clear();
    _windows.clear();
    _cachedBytes = 0;
    _frontierBytes = 0;
    _totalBytes = null;
  }

  Future<Uint8List> windowData(int index) {
    final cached = _windows[index];
    if (cached != null) return Future.value(cached);
    final inflight = _inflight[index];
    if (inflight != null) return inflight;
    final future = _fetch(index);
    _inflight[index] = future;
    return future;
  }

  Future<Uint8List> _fetch(int index) async {
    try {
      final data = await source.window(index * videoStreamWindowBytes, videoStreamWindowBytes);
      if (!_disposed && data.isNotEmpty) {
        _windows[index] = data;
        _cachedBytes += data.length;
        _frontierBytes = max(_frontierBytes, index * videoStreamWindowBytes + data.length);
        _evict();
      }
      return data;
    } finally {
      _inflight.remove(index);
    }
  }

  void _evict() {
    // Keep the two windows the cursor sits between; drop the oldest others.
    while (_cachedBytes > videoStreamCacheBytes && _windows.length > 2) {
      final oldest = _windows.keys.first;
      _cachedBytes -= _windows[oldest]!.length;
      _windows.remove(oldest);
    }
  }

  /// Pulls windows covering [absoluteEnd] ahead of the served range so the
  /// next response is warm. Failures are quiet: the serving path retries the
  /// window when the player's next range reaches for it.
  Future<void> prefetchThrough(int absoluteEnd, int total) async {
    if (_disposed) return;
    final last = min(absoluteEnd, total - 1);
    if (last < 0) return;
    final target = last ~/ videoStreamWindowBytes;
    for (var index = _prefetchedTo < 0 ? 0 : _prefetchedTo + 1; index <= target; index++) {
      if (_disposed) return;
      try {
        await windowData(index);
      } on Object {
        return;
      }
      _prefetchedTo = index;
    }
  }
}
