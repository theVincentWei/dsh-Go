// 应用内音视频统一播放引擎:视频查看器与音频/视频产物预览共用同一套
// 打开(流式优先、下载兜底)、续播、轮询、进度存档、倍速与拖动 seek 逻辑,
// 音频(无视频轨)与视频在引擎层无差别;形态差异只在 UI 层。
//
// seek 加固(续播后拉回开头类问题的根治):seek 命令不再走会互斥丢弃的
// 命令通道;目标合并(后发覆盖先发);发出后 UI 钉在目标位置,轮询确认
// 真到位才放开(不到位自动重发一次);按目标位置(而非滞后读数)写存档,
// 目标为开头时清档,下次打开从 0 开始。

import 'dart:async';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'video.dart';
import 'video_progress.dart';
import 'video_stream_server.dart';
import '../state/artifact_files.dart';
import '../state/artifacts.dart';

/// One playback session for a single host file. The owner must call
/// [dispose] (the viewer page's State.dispose does).
class MediaPlayback extends ChangeNotifier with WidgetsBindingObserver {
  MediaPlayback({
    required this.files,
    required this.video,
    required this.sessionId,
    required this.path,
    required this.name,
    this.mime,
    this.streamServer,
    this.progressStore,
  });

  final ArtifactFiles files;
  final MediaVideoChannel video;
  final String sessionId;

  /// Absolute path on the Host (or on the phone, for local files).
  final String path;
  final String name;
  final String? mime;
  final VideoStreamServer? streamServer;
  final VideoProgressStore? progressStore;

  Artifact get _artifact => Artifact(path: path, origin: ArtifactOrigin.linked, turn: 0);

  bool _disposed = false;

  /// ChangeNotifier 没有这个属性;沿用 widgets 的习惯名。
  bool get mounted => !_disposed;

  void _notify() {
    if (mounted) notifyListeners();
  }

  // —— 显式下载/分享的互斥(UI 按钮态),由查看器设置。——
  bool _sharing = false;
  bool get sharing => _sharing;
  set sharing(bool value) {
    if (_sharing == value) return;
    _sharing = value;
    _notify();
  }

  bool _saving = false;
  bool get saving => _saving;
  set saving(bool value) {
    if (_saving == value) return;
    _saving = value;
    _notify();
  }

  /// 已落地的整文件(下载兜底/保存/错误文案共用,免二次下载)。
  File? localCopy;

  /// 打开失败后的重试(换一个会话从头再来)。
  void reopen() => unawaited(_load());

  MediaVideoHandle? _handle;
  MediaVideoState? _state;
  VideoStreamSession? _stream;
  Object? _error;
  Timer? _poller;
  double? _progress;
  bool _polling = false;
  bool _commanding = false;
  bool _streamExhausted = false;
  bool _streamedOpen = false;
  int _generation = 0;

  // —— 上次播放到哪:键按 主机+会话+路径,打开时读,关掉/暂停/后台时存。——
  late final VideoProgressStore progressStoreController =
      progressStore ?? VideoProgressStore();
  String? _progressKey;
  int? _lastSavedPositionMs;
  DateTime _lastSaveAt = DateTime.now();

  // —— 续播徽标:定位后亮 3 秒。——
  int _resumeMs = 0;
  Timer? _badgeTimer;

  // —— 拖动进度条/横滑:预览目标与画面预览。预览帧按"秒"缓存,拖回去免费。——
  int? _dragMs;
  int? _pendingSeekMs;
  final Map<int, Uint8List> _frames = {};
  int? _previewBucket;
  int _previewSeq = 0;
  Timer? _previewTimer;
  bool _previewDead = false;

  // —— seek 命令合并且不丢:目标落在最新一个,确认循环收敛到它。——
  int? _seekTargetMs;
  bool _seekBusy = false;

  bool _speedBoosted = false;

  // —— 只读状态(UI 直接读) ——

  /// 打开中:既没有可播的句柄,也没有报错。
  bool get loading => _handle == null && _error == null;
  double? get downloadProgress => _progress;
  Object? get error => _error;
  MediaVideoHandle? get handle => _handle;
  MediaVideoState? get state => _state;
  bool get commanding => _commanding;
  bool get speedBoosted => _speedBoosted;
  bool get audioOnly => _handle?.audioOnly ?? false;
  bool get streamed => _streamedOpen;
  int get resumeMs => _resumeMs;

  /// 拖动中的预览目标(进度条/横滑):UI 显示它,松手交给定住位。
  int? get dragMs => _dragMs;

  /// seek 已发出但播放器还没确认:UI 钉在目标位置,不回跳。
  int? get pendingSeekMs => _pendingSeekMs;

  /// UI 显示的播放位置:拖动目标 > 未确认的 seek 目标 > 轮询读数。
  int get displayMs {
    final duration = _state?.durationMs ?? 0;
    if (_dragMs != null) return _dragMs!.clamp(0, duration);
    if (_pendingSeekMs != null) return _pendingSeekMs!.clamp(0, duration);
    return _state?.positionMs.clamp(0, duration) ?? 0;
  }

  /// 缓冲到哪了:本地/已下载的整段都在;流式时映射代理的已取前沿
  /// (字节→时间线性近似,够"下到哪了"用)。null 就不画缓冲段。
  double? get bufferedFraction {
    final state = _state;
    if (state == null || state.durationMs <= 0) return null;
    if (localCopy != null) return 1.0;
    final stream = _stream;
    if (stream == null) return null;
    final snapshot = stream.server.bufferedSnapshot(stream.url);
    if (snapshot == null) return null;
    final (frontier, total) = snapshot;
    if (total <= 0) return null;
    return (frontier / total).clamp(0.0, 1.0);
  }

  /// Streaming plays while bytes arrive; a download first is the fallback,
  /// never the default. Local files are already on the phone.
  bool get _canStream =>
      !_streamExhausted && !files.isLocal && files.canFetch && video.supportsUrlSource;

  bool get _isAudio => mime?.startsWith('audio/') == true;

  // —— 生命周期 ——

  void open() {
    WidgetsBinding.instance.addObserver(this);
    final conn = files.connection;
    _progressKey = VideoProgressStore.keyFor(
      hostId: conn?.hostId ?? conn?.label,
      sessionId: sessionId,
      path: path,
    );
    unawaited(_load());
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    ++_generation;
    _poller?.cancel();
    _previewTimer?.cancel();
    _badgeTimer?.cancel();
    unawaited(_saveProgress(force: true));
    unawaited(_close(_handle));
    unawaited(_closeStream());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _poller?.cancel();
      unawaited(_saveProgress(force: true));
      final handle = _handle;
      if (handle != null) {
        unawaited(video.pause(handle.texture).catchError((Object _) {}));
        final previous = _state;
        if (previous != null) {
          _state = MediaVideoState(
            positionMs: previous.positionMs,
            durationMs: previous.durationMs,
            playing: false,
            buffering: previous.buffering,
          );
          _notify();
        }
      }
    } else if (_handle != null) {
      unawaited(_poll());
      _startPolling();
    }
  }

  // —— 打开/重试(流式优先,失败落下载;断流自动接续) ——

  Future<void> _load() async {
    final generation = ++_generation;
    _poller?.cancel();
    final previous = _handle;
    _handle = null;
    _state = null;
    _error = null;
    _progress = null;
    _notify();
    await _close(previous);
    if (!mounted || generation != _generation) return;
    try {
      final handle = await _open(generation);
      if (!mounted || generation != _generation) {
        await _close(handle);
        return;
      }
      _handle = handle;
      _state = MediaVideoState(positionMs: 0, durationMs: handle.durationMs, playing: false);
      _notify();
      // 上次看到哪:接着看;基本看完的从头。平台不支持就当没存过。
      final resumeMs = await _resumePosition(handle);
      if (!mounted || generation != _generation || !identical(_handle, handle)) return;
      if (resumeMs > 0) {
        await video.seek(handle.texture, resumeMs);
        if (!mounted || generation != _generation || !identical(_handle, handle)) return;
        _state = MediaVideoState(positionMs: resumeMs, durationMs: handle.durationMs, playing: false);
        _resumeMs = resumeMs;
        _badgeTimer?.cancel();
        _badgeTimer = Timer(const Duration(seconds: 3), () {
          if (mounted && _resumeMs != 0) {
            _resumeMs = 0;
            _notify();
          }
        });
        _notify();
      }
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        await video.play(handle.texture);
      }
      if (!mounted || generation != _generation) return;
      await _poll();
      if (!mounted || generation != _generation || !identical(_handle, handle)) return;
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) _startPolling();
    } catch (error) {
      if (mounted && generation == _generation) _fail(error);
    }
  }

  /// A previously downloaded copy wins outright; otherwise stream when this
  /// build can, and fall back to downloading on any stream failure. A player
  /// that refuses the source outright (codec) never tries streaming again.
  Future<MediaVideoHandle> _open(int generation) async {
    _streamedOpen = false;
    var file = localCopy;
    if (file == null && _canStream) {
      file = await files.cachedRemote(sessionId, _artifact);
      if (file != null) localCopy = file;
    }
    if (file != null) return _openFile(file);
    if (_canStream) {
      try {
        return await _openStream();
      } on MissingPluginException {
        _streamExhausted = true;
      } on PlatformException catch (error) {
        if (error.code == 'unsupported') _streamExhausted = true;
      } on Object {
        // Binding or serving failed; the download path is the answer.
      }
    }
    return _openDownloaded(generation);
  }

  Future<MediaVideoHandle> _openFile(File file) async {
    // 音频没有海报可抽,别让解码器白跑。
    if (!_isAudio) {
      unawaited(
        cacheMediaVideoThumbnail(files, video, sessionId, MediaItem(path: path, mime: mime), materialized: file),
      );
    }
    return video.open(file.path);
  }

  Future<MediaVideoHandle> _openStream() async {
    await _closeStream();
    final server = streamServer ?? VideoStreamServer.instance;
    final source = ArtifactVideoByteSource(files: files, sessionId: sessionId, artifact: _artifact, mime: mime);
    final session = await server.openStream(source: source);
    _stream = session;
    try {
      final handle = await video.openUrl(session.url.toString());
      _streamedOpen = true;
      if (!_isAudio) unawaited(_seedStreamPoster(session.url.toString()));
      return handle;
    } on Object {
      await _closeStream();
      rethrow;
    }
  }

  Future<void> _seedStreamPoster(String url) async {
    // The card reads the seeded poster when the viewer closes; failures stay
    // silent, a missing poster never blocks anything.
    await cacheStreamedVideoPoster(files, video, sessionId, MediaItem(path: path, mime: mime), url);
  }

  Future<MediaVideoHandle> _openDownloaded(int generation) async {
    final file =
        localCopy ??
        await files.materialize(
          sessionId,
          _artifact,
          onProgress: (value) {
            if (mounted && generation == _generation) {
              _progress = value;
              _notify();
            }
          },
        );
    localCopy = file;
    return _openFile(file);
  }

  void _fail(Object error, {bool playback = false}) {
    _poller?.cancel();
    final handle = _handle;
    // 流式播放中途断掉(代理跟不上播放器/网络抖动):不再走流式,自动落整
    // 文件从头续播。只兜一次,下载路径再失败就老实报错。
    if (playback && mounted && _streamedOpen && !_streamExhausted) {
      _streamExhausted = true;
      // 断点接续:先记下当前进度,下载重开后从这里接着播。
      unawaited(_saveProgress(force: true));
      _handle = null;
      _state = null;
      _notify();
      unawaited(_close(handle));
      unawaited(_closeStream());
      unawaited(_load());
      return;
    }
    _error = error;
    _handle = null;
    _notify();
    unawaited(_close(handle));
  }

  // —— 轮询与命令 ——

  void _startPolling() {
    _poller?.cancel();
    _poller = Timer.periodic(const Duration(milliseconds: 400), (_) => unawaited(_poll()));
  }

  Future<void> _poll() async {
    final handle = _handle;
    if (handle == null || _polling) return;
    _polling = true;
    try {
      final state = await video.state(handle.texture);
      if (mounted && identical(_handle, handle)) {
        _state = state;
        _notify();
        unawaited(_saveProgress());
      }
    } catch (error) {
      if (mounted && identical(_handle, handle)) _fail(error, playback: true);
    } finally {
      _polling = false;
    }
  }

  /// 播放/暂停/倍速这类短命令:仍互斥(双击去抖),seek 已改走 [seekTo],
  /// 不再从这里过,也就不再被互斥丢掉。
  Future<void> _command(Future<void> Function(int texture) command) async {
    final handle = _handle;
    if (handle == null || _commanding) return;
    _commanding = true;
    _notify();
    try {
      await command(handle.texture);
      await _poll();
    } catch (error) {
      if (mounted && identical(_handle, handle)) _fail(error, playback: true);
    } finally {
      _commanding = false;
      _notify();
    }
    unawaited(_saveProgress(force: true));
  }

  /// 单击控制层的播放/暂停;播完了再点从 0 重来。
  void togglePlay() {
    unawaited(
      _command((texture) async {
        if (_state?.playing ?? false) {
          await video.pause(texture);
        } else {
          if (_state != null && _state!.positionMs >= _state!.durationMs && _state!.durationMs > 0) {
            await video.seek(texture, 0);
          }
          await video.play(texture);
        }
      }),
    );
  }

  /// 长按倍速:按住 2×,松手回 1×。MediaPlayer 的 setPlaybackParams 在非零
  /// 倍速时会隐式起播,所以:回 1× 后若原本是暂停态,要再停回去;暂停中
  /// 长按直接不加速(更不起播)。普通单击也会触发 LongPress 的 cancel——
  /// 只有 [_speedBoosted] 真的在倍速中,回 1× 才有意义。
  Future<void> setSpeed(double rate) async {
    final handle = _handle;
    if (handle == null) return;
    if (rate <= 1) {
      if (!_speedBoosted) return;
      final playing = _state?.playing ?? false;
      try {
        await video.speed(handle.texture, 1.0);
        if (!playing) await video.pause(handle.texture);
      } on Object {
        // 播放器已死就交给状态轮询兜底。
      }
      _speedBoosted = false;
      _notify();
      return;
    }
    if (_state?.playing != true) return;
    await _command((texture) => video.speed(texture, rate));
    _speedBoosted = rate > 1;
    _notify();
  }

  // —— seek(加固版) ——

  /// 拖动中:进度条/预览跟手,不真正 seek。
  void dragTo(int ms) {
    final duration = _state?.durationMs ?? 0;
    if (duration <= 0) return;
    _dragMs = ms.clamp(0, duration);
    _notify();
    _queuePreview(_dragMs!);
  }

  /// 松手:清预览、交棒给定住位,真正 seek。
  void dragEnd(int ms) {
    _clearPreview();
    _dragMs = null;
    _notify();
    unawaited(seekTo(ms));
  }

  /// seek 加固:目标合并(后发覆盖先发,绝不丢);发出后 UI 钉在目标位置;
  /// 轮询确认位置真到位才放开,不到位自动重发一次;按目标(而非滞后读数)
  /// 写存档,目标为开头时清档。
  Future<void> seekTo(int ms) async {
    final state = _state;
    if (state == null || state.durationMs <= 0) return;
    final clamped = ms.clamp(0, state.durationMs);
    if (_seekBusy) {
      // 在确认上一发:记下最新目标,循环收敛到它。
      _seekTargetMs = clamped;
      return;
    }
    _seekBusy = true;
    try {
      _seekTargetMs = clamped;
      while (_seekTargetMs != null) {
        final target = _seekTargetMs!;
        _seekTargetMs = null;
        _pendingSeekMs = target;
        _notify();
        var confirmed = false;
        for (var attempt = 1; attempt <= 2 && !confirmed && mounted; attempt++) {
          final handle = _handle;
          if (handle == null) return;
          try {
            await video.seek(handle.texture, target);
          } catch (error) {
            _fail(error, playback: true);
            return;
          }
          confirmed = await _awaitSeek(target);
        }
        unawaited(_saveProgress(force: true, atMs: target));
      }
    } finally {
      _seekBusy = false;
      if (_pendingSeekMs != null) {
        _pendingSeekMs = null;
        _notify();
      }
    }
  }

  /// 轮询等 seek 落地:位置到达目标邻域即确认;播放中从目标附近起步也算;
  /// 约 1.4s 不到就报失败,由调用方重发一次。
  Future<bool> _awaitSeek(int target) async {
    const tolerance = 900;
    final deadline = DateTime.now().add(const Duration(milliseconds: 1400));
    while (mounted) {
      await Future<void>.delayed(const Duration(milliseconds: 160));
      if (!mounted) return true;
      final handle = _handle;
      if (handle == null) return true;
      try {
        final state = await video.state(handle.texture);
        if (!mounted || !identical(_handle, handle)) return true;
        _state = state;
        _notify();
        if ((state.positionMs - target).abs() <= tolerance) return true;
        if (state.playing && state.positionMs >= target && state.positionMs - target <= 2200) return true;
      } catch (error) {
        if (mounted && identical(_handle, handle)) _fail(error, playback: true);
        return true;
      }
      if (DateTime.now().isAfter(deadline)) return false;
    }
    return true;
  }

  // —— 拖动画面预览(纯音频没有帧,直接跳过) ——

  /// 拖动中的画面预览:120ms 去抖,只取一帧;缓存按秒桶,拖回去免费。
  void _queuePreview(int ms) {
    if (_previewDead || !video.supportsFrameExtraction || audioOnly) return;
    final duration = _state?.durationMs ?? 0;
    if (duration <= 0) return;
    final target = ms.clamp(0, duration);
    final bucket = target ~/ 1000;
    if (_previewBucket == bucket && _frames.containsKey(bucket)) return;
    _previewTimer?.cancel();
    _previewTimer = Timer(const Duration(milliseconds: 120), () => unawaited(_fetchPreview(target, bucket)));
  }

  Future<void> _fetchPreview(int ms, int bucket) async {
    if (!mounted || _previewDead) return;
    if (_frames[bucket] != null) {
      _previewBucket = bucket;
      _notify();
      return;
    }
    final seq = ++_previewSeq;
    final streamUrl = _streamedOpen ? _stream?.url.toString() : null;
    final filePath = localCopy?.path;
    final Uint8List? bytes;
    try {
      if (streamUrl != null) {
        bytes = await video.frameUrl(streamUrl, ms);
      } else if (filePath != null) {
        bytes = await video.frame(filePath, ms);
      } else {
        return;
      }
    } on MissingPluginException {
      _previewDead = true;
      return;
    } on Object {
      return; // 预览是装饰,失败就保持时间胶囊。
    }
    if (!mounted || seq != _previewSeq) return;
    if (bytes == null || bytes.isEmpty) return;
    final frame = bytes;
    while (_frames.length >= 24) {
      _frames.remove(_frames.keys.first);
    }
    _frames[bucket] = frame;
    _previewBucket = bucket;
    _notify();
  }

  void _clearPreview() {
    _previewTimer?.cancel();
    _previewTimer = null;
    _previewSeq++;
    if (_previewBucket == null) return;
    _previewBucket = null;
    _notify();
  }

  /// 拖动预览的帧(按秒桶);音频与不支持抽帧的平台永远 null。
  Uint8List? previewFrame(int? bucket) =>
      bucket == null || _previewBucket != bucket ? null : _frames[bucket];

  // —— 续播存档 ——

  /// 上次看到哪:文件换了一版(时长对不上)或基本看完的不续,其余接着播。
  Future<int> _resumePosition(MediaVideoHandle handle) async {
    final key = _progressKey;
    if (key == null || handle.durationMs <= 0) return 0;
    final VideoProgressEntry? entry;
    try {
      entry = await progressStoreController.load(key);
    } on Object {
      return 0;
    }
    if (entry == null) return 0;
    if ((entry.durationMs - handle.durationMs).abs() > handle.durationMs ~/ 10) return 0;
    if (entry.positionMs < 1000 || entry.positionMs >= handle.durationMs - 1500) return 0;
    return entry.positionMs;
  }

  /// 记住当前位置:播放中每 5 秒一笔,命令/暂停/后台/关页时立刻一笔,
  /// seek 按目标位置记([atMs])。看完(或拖到结尾附近)清档;显式 seek 到
  /// 开头也清档——「拉回开头」之后关掉,下次就该从头。
  Future<void> _saveProgress({bool force = false, int? atMs}) async {
    final key = _progressKey;
    final state = _state;
    if (key == null || state == null || state.durationMs <= 0) return;
    final position = (atMs ?? state.positionMs).clamp(0, state.durationMs);
    if (position <= 0) {
      if (atMs != null) {
        _lastSavedPositionMs = null;
        try {
          await progressStoreController.clear(key);
        } on Object {
          /* 存档是增强,失败不打扰播放。 */
        }
      }
      return;
    }
    if (position >= state.durationMs - 250) {
      _lastSavedPositionMs = null;
      try {
        await progressStoreController.clear(key);
      } on Object {
        /* 存档是增强,失败不打扰播放。 */
      }
      return;
    }
    if (!force && (position == _lastSavedPositionMs || DateTime.now().difference(_lastSaveAt) < const Duration(seconds: 5))) {
      return;
    }
    _lastSaveAt = DateTime.now();
    _lastSavedPositionMs = position;
    try {
      await progressStoreController.save(key, positionMs: position, durationMs: state.durationMs);
    } on Object {
      /* 存档是增强,失败不打扰播放。 */
    }
  }

  // —— 内部收尾 ——

  Future<void> _close(MediaVideoHandle? handle) async {
    if (handle != null) {
      try {
        await video.close(handle.texture);
      } catch (_) {
        /* Already released by Android. */
      }
    }
  }

  Future<void> _closeStream() async {
    final session = _stream;
    _stream = null;
    try {
      await session?.close();
    } catch (_) {
      /* The server may already be shutting down. */
    }
  }
}
