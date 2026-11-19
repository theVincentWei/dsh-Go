import 'dart:async';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../media/gallery.dart';
import '../../../media/video.dart';
import '../../../media/video_progress.dart';
import '../../../media/video_stream_server.dart';
import '../../../state/artifact_files.dart';
import '../../../state/artifacts.dart';
import '../../common/brief_notice.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';

/// Capture the Host before navigation; a later active-host switch cannot move
/// this viewer's download, retry, save or external playback to another Host.
Future<void> openMediaVideoViewer(
  BuildContext context,
  WidgetRef ref,
  String sessionId,
  MediaItem item, {
  ArtifactFiles? sourceFiles,
  VideoStreamServer? streamServer,
  VideoProgressStore? progressStore,
}) {
  final files = sourceFiles ?? ref.read<ArtifactFiles>(artifactFilesProvider);
  final video = ref.read(mediaVideoChannelProvider);
  final gallery = ref.read(mediaChannelProvider);
  return Navigator.of(context).push<void>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => MediaVideoViewerPage(
        sessionId: sessionId,
        item: item,
        files: files,
        video: video,
        gallery: gallery,
        streamServer: streamServer,
        progressStore: progressStore,
      ),
    ),
  );
}

class MediaVideoViewerPage extends StatefulWidget {
  const MediaVideoViewerPage({
    super.key,
    required this.sessionId,
    required this.item,
    required this.files,
    required this.video,
    required this.gallery,
    this.streamServer,
    this.progressStore,
  });
  final String sessionId;
  final MediaItem item;
  final ArtifactFiles files;
  final MediaVideoChannel video;
  final MediaChannel gallery;

  /// The loopback stream source; [VideoStreamServer.instance] unless a test
  /// injects its own.
  final VideoStreamServer? streamServer;

  /// 上次播放到哪的存档;测试可注入自己的实例。
  final VideoProgressStore? progressStore;

  @override
  State<MediaVideoViewerPage> createState() => _MediaVideoViewerPageState();
}

class _MediaVideoViewerPageState extends State<MediaVideoViewerPage> with WidgetsBindingObserver {
  MediaVideoHandle? _handle;
  MediaVideoState? _state;
  File? _file;
  VideoStreamSession? _stream;
  Object? _error;
  Timer? _poller;
  double? _progress;
  double? _seeking;
  bool _loading = true;
  bool _polling = false;
  bool _saving = false;
  bool _external = false;
  bool _commanding = false;
  bool _streamExhausted = false;
  bool _streamedOpen = false;
  bool _controlsVisible = true;
  bool _speedBoosted = false;
  _DragSeek? _drag;
  Timer? _tapTimer;
  int _generation = 0;

  // 上次播放到哪:键按 主机+会话+路径,打开时读,关掉/暂停/后台时存。
  late final VideoProgressStore _progressStore = widget.progressStore ?? VideoProgressStore();
  String? _progressKey;
  int? _lastSavedPositionMs;
  DateTime _lastSaveAt = DateTime.now();

  // 拖动进度条:目标毫秒与画面预览。预览帧按"秒"缓存,拖回去直接命中。
  int? _barDragMs;
  final Map<int, Uint8List> _frames = {};
  int? _previewBucket;
  int _previewSeq = 0;
  Timer? _previewTimer;
  bool _previewDead = false;

  // 续播徽标:定位后亮 3 秒。
  int _resumeMs = 0;
  Timer? _badgeTimer;

  /// 横滑快进快退的一次手势:起点横坐标、基准播放位置、当前预览目标。
  int get _seekSpanMs => 120 * 1000; // 一个屏宽 ≈ 2 分钟,B 站量级。

  Artifact get _artifact => Artifact(path: widget.item.path, origin: ArtifactOrigin.linked, turn: 0);

  /// Streaming plays the video while its bytes arrive; a download first is
  /// the fallback, never the default. Local files are already on the phone.
  bool get _canStream =>
      !_streamExhausted &&
      !widget.files.isLocal &&
      widget.files.canFetch &&
      widget.video.supportsUrlSource;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final conn = widget.files.connection;
    _progressKey = VideoProgressStore.keyFor(
      hostId: conn?.hostId ?? conn?.label,
      sessionId: widget.sessionId,
      path: widget.item.path,
    );
    unawaited(_load());
  }

  Future<void> _close(MediaVideoHandle? handle) async {
    if (handle != null) {
      try {
        await widget.video.close(handle.texture);
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

  Future<void> _load() async {
    final generation = ++_generation;
    _poller?.cancel();
    final previous = _handle;
    setState(() {
      _handle = null;
      _state = null;
      _error = null;
      _loading = true;
      _progress = null;
    });
    await _close(previous);
    if (!mounted || generation != _generation) return;
    try {
      final handle = await _open(generation);
      if (!mounted || generation != _generation) {
        await _close(handle);
        return;
      }
      setState(() {
        _handle = handle;
        _state = MediaVideoState(positionMs: 0, durationMs: handle.durationMs, playing: false);
        _loading = false;
      });
      // 上次看到哪:接着看;基本看完的从头。平台不支持就当没存过。
      final resumeMs = await _resumePosition(handle);
      if (!mounted || generation != _generation || !identical(_handle, handle)) return;
      if (resumeMs > 0) {
        await widget.video.seek(handle.texture, resumeMs);
        if (!mounted || generation != _generation || !identical(_handle, handle)) return;
        setState(() {
          _state = MediaVideoState(positionMs: resumeMs, durationMs: handle.durationMs, playing: false);
          _resumeMs = resumeMs;
        });
        _badgeTimer?.cancel();
        _badgeTimer = Timer(const Duration(seconds: 3), () {
          if (mounted) setState(() => _resumeMs = 0);
        });
      }
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) await widget.video.play(handle.texture);
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
    var file = _file;
    if (file == null && _canStream) {
      file = await widget.files.cachedRemote(widget.sessionId, _artifact);
      if (file != null) _file = file;
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
    unawaited(
      cacheMediaVideoThumbnail(widget.files, widget.video, widget.sessionId, widget.item, materialized: file),
    );
    return widget.video.open(file.path);
  }

  Future<MediaVideoHandle> _openStream() async {
    await _closeStream();
    final server = widget.streamServer ?? VideoStreamServer.instance;
    final source = ArtifactVideoByteSource(
      files: widget.files,
      sessionId: widget.sessionId,
      artifact: _artifact,
      mime: widget.item.mime,
    );
    final session = await server.openStream(source: source);
    _stream = session;
    try {
      final handle = await widget.video.openUrl(session.url.toString());
      _streamedOpen = true;
      unawaited(_seedStreamPoster(session.url.toString()));
      return handle;
    } on Object {
      await _closeStream();
      rethrow;
    }
  }

  Future<void> _seedStreamPoster(String url) async {
    // The card reads the seeded poster when the viewer closes; failures stay
    // silent, a missing poster never blocks anything.
    await cacheStreamedVideoPoster(widget.files, widget.video, widget.sessionId, widget.item, url);
  }

  Future<MediaVideoHandle> _openDownloaded(int generation) async {
    final file =
        _file ??
        await widget.files.materialize(
          widget.sessionId,
          _artifact,
          onProgress: (value) {
            if (mounted && generation == _generation) setState(() => _progress = value);
          },
        );
    _file = file;
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
      setState(() {
        _handle = null;
        _state = null;
      });
      unawaited(_close(handle));
      unawaited(_closeStream());
      unawaited(_load());
      return;
    }
    setState(() {
      _error = error;
      _loading = false;
      _handle = null;
    });
    unawaited(_close(handle));
  }

  void _startPolling() {
    _poller?.cancel();
    _poller = Timer.periodic(const Duration(milliseconds: 400), (_) => unawaited(_poll()));
  }

  Future<void> _poll() async {
    final handle = _handle;
    if (handle == null || _polling) return;
    _polling = true;
    try {
      final state = await widget.video.state(handle.texture);
      if (mounted && identical(_handle, handle)) {
        setState(() => _state = state);
        unawaited(_saveProgress());
      }
    } catch (error) {
      if (mounted && identical(_handle, handle)) _fail(error, playback: true);
    } finally {
      _polling = false;
    }
  }

  Future<void> _command(Future<void> Function(int texture) command) async {
    final handle = _handle;
    if (handle == null || _commanding) return;
    setState(() => _commanding = true);
    try {
      await command(handle.texture);
      await _poll();
    } catch (error) {
      if (mounted && identical(_handle, handle)) _fail(error, playback: true);
    } finally {
      if (mounted) setState(() => _commanding = false);
    }
    unawaited(_saveProgress(force: true));
  }

  /// 上次看到哪:文件换了一版(时长对不上)或基本看完的不续,其余接着播。
  Future<int> _resumePosition(MediaVideoHandle handle) async {
    final key = _progressKey;
    if (key == null || handle.durationMs <= 0) return 0;
    final VideoProgressEntry? entry;
    try {
      entry = await _progressStore.load(key);
    } on Object {
      return 0;
    }
    if (entry == null) return 0;
    if ((entry.durationMs - handle.durationMs).abs() > handle.durationMs ~/ 10) return 0;
    if (entry.positionMs < 1000 || entry.positionMs >= handle.durationMs - 1500) return 0;
    return entry.positionMs;
  }

  /// 记住当前位置:播放中每 5 秒一笔,命令/暂停/后台/关页时立刻一笔。
  /// 看完(或拖到结尾附近)就清掉,下次从头。
  Future<void> _saveProgress({bool force = false, int? atMs}) async {
    final key = _progressKey;
    final state = _state;
    if (key == null || state == null || state.durationMs <= 0) return;
    final position = (atMs ?? state.positionMs).clamp(0, state.durationMs);
    if (position <= 0) return;
    if (position >= state.durationMs - 250) {
      _lastSavedPositionMs = null;
      try {
        await _progressStore.clear(key);
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
      await _progressStore.save(key, positionMs: position, durationMs: state.durationMs);
    } on Object {
      /* 存档是增强,失败不打扰播放。 */
    }
  }

  /// 缓冲到哪了:本地/已下载的整段都在;流式时映射代理的已取前沿
  /// (字节→时间线性近似,够"下到哪了"用)。null 就不画缓冲段。
  double? get _bufferedFraction {
    final state = _state;
    if (state == null || state.durationMs <= 0) return null;
    if (_file != null) return 1.0;
    final stream = _stream;
    if (stream == null) return null;
    final snapshot = stream.server.bufferedSnapshot(stream.url);
    if (snapshot == null) return null;
    final (frontier, total) = snapshot;
    if (total <= 0) return null;
    return (frontier / total).clamp(0.0, 1.0);
  }

  /// 拖动中的画面预览:120ms 去抖,只取一帧;缓存按秒桶,拖回去免费。
  void _queuePreview(int ms) {
    if (_previewDead || !widget.video.supportsFrameExtraction) return;
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
      setState(() => _previewBucket = bucket);
      return;
    }
    final seq = ++_previewSeq;
    final streamUrl = _streamedOpen ? _stream?.url.toString() : null;
    final path = _file?.path;
    final Uint8List? bytes;
    try {
      if (streamUrl != null) {
        bytes = await widget.video.frameUrl(streamUrl, ms);
      } else if (path != null) {
        bytes = await widget.video.frame(path, ms);
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
    setState(() {
      while (_frames.length >= 24) {
        _frames.remove(_frames.keys.first);
      }
      _frames[bucket] = frame;
      _previewBucket = bucket;
    });
  }

  void _clearPreview() {
    _previewTimer?.cancel();
    _previewTimer = null;
    _previewSeq++;
    if (_previewBucket == null) return;
    setState(() => _previewBucket = null);
  }

  /// 长按倍速:按住 2×,松手回 1×。MediaPlayer 的 setPlaybackParams 在非零
  /// 倍速时会隐式起播,所以:回 1× 后若原本是暂停态,要再停回去;暂停中
  /// 长按直接不加速(更不起播)。普通单击也会触发 LongPress 的 cancel——
  /// 只有 [_speedBoosted] 真的在倍速中,回 1× 才有意义。
  Future<void> _setSpeed(double rate) async {
    final handle = _handle;
    if (handle == null) return;
    if (rate <= 1) {
      if (!_speedBoosted) return;
      final playing = _state?.playing ?? false;
      try {
        await widget.video.speed(handle.texture, 1.0);
        if (!playing) await widget.video.pause(handle.texture);
      } on Object {
        // 播放器已死就交给状态轮询兜底。
      }
      if (mounted) setState(() => _speedBoosted = false);
      return;
    }
    if (_state?.playing != true) return;
    await _command((texture) => widget.video.speed(texture, rate));
    if (mounted) setState(() => _speedBoosted = rate > 1);
  }

  /// 单击:切控制层显隐。双击(B 站语义):撤销单击的控制层开关、控制层
  /// 保持显示、播放/暂停。自数双击而不用 onDoubleTap:单击零延迟,300ms 内
  /// 的第二下不会被误判成"切两次控制层"。
  void _handleTap() {
    final pending = _tapTimer;
    if (pending != null) {
      pending.cancel();
      _tapTimer = null;
      setState(() => _controlsVisible = true);
      _togglePlay();
      return;
    }
    setState(() => _controlsVisible = !_controlsVisible);
    _tapTimer = Timer(const Duration(milliseconds: 300), () => _tapTimer = null);
  }

  void _togglePlay() {
    unawaited(
      _command((texture) async {
        if ((_state?.playing ?? false)) {
          await widget.video.pause(texture);
        } else {
          if ((_state?.positionMs ?? 0) >= (_state?.durationMs ?? 0)) {
            await widget.video.seek(texture, 0);
          }
          await widget.video.play(texture);
        }
      }),
    );
  }

  void _dragStart(DragStartDetails details) {
    final state = _state;
    if (_handle == null || state == null || state.durationMs <= 0 || _drag != null) return;
    setState(() {
      _drag = _DragSeek(startDx: details.globalPosition.dx, baseMs: state.positionMs, targetMs: state.positionMs);
      // 进度条跟着手指预览走;松手才真正 seek。
      _seeking = state.positionMs.toDouble();
    });
    _queuePreview(state.positionMs);
  }

  void _dragUpdate(DragUpdateDetails details) {
    final drag = _drag;
    final state = _state;
    if (drag == null || state == null) return;
    final width = MediaQuery.sizeOf(context).width;
    final dx = details.globalPosition.dx - drag.startDx;
    final target = (drag.baseMs + dx / (width > 1 ? width : 1) * _seekSpanMs).round().clamp(0, state.durationMs);
    if (target == drag.targetMs) return;
    setState(() {
      _drag = _DragSeek(startDx: drag.startDx, baseMs: drag.baseMs, targetMs: target);
      // 进度条跟着手指预览走;松手才真正 seek。
      _seeking = target.toDouble();
    });
    _queuePreview(target);
  }

  void _dragEnd(DragEndDetails details) {
    final drag = _drag;
    if (drag == null) return;
    _clearPreview();
    setState(() {
      _drag = null;
      _seeking = null;
    });
    unawaited(_command((texture) => widget.video.seek(texture, drag.targetMs)));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _poller?.cancel();
      unawaited(_saveProgress(force: true));
      final handle = _handle;
      if (handle != null) {
        unawaited(widget.video.pause(handle.texture).catchError((Object _) {}));
        final previous = _state;
        if (previous != null) {
          setState(
            () => _state = MediaVideoState(
              positionMs: previous.positionMs,
              durationMs: previous.durationMs,
              playing: false,
              buffering: previous.buffering,
            ),
          );
        }
      }
    } else if (_handle != null) {
      unawaited(_poll());
      _startPolling();
    }
  }

  Future<void> _openExternal() async {
    if (_external) return;
    setState(() => _external = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (_handle case final handle?) {
        try {
          await widget.video.pause(handle.texture);
        } catch (_) {
          /* External fallback must still work. */
        }
      }
      await widget.files.open(widget.sessionId, _artifact);
    } catch (error) {
      if (mounted) messenger.showSnackBar(SnackBar(content: Text(artifactErrorText(error))));
    } finally {
      if (mounted) setState(() => _external = false);
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.l10n;
    try {
      var file = _file;
      if (file == null) {
        // The one explicit download: whole file, shown in the global task
        // bar, cancellable. Streaming playback never materializes on its own.
        file = await widget.files.materialize(widget.sessionId, _artifact, taskLabel: widget.item.name);
        if (!mounted) return;
        setState(() => _file = file);
        unawaited(
          cacheMediaVideoThumbnail(widget.files, widget.video, widget.sessionId, widget.item, materialized: file),
        );
      }
      await widget.gallery.saveVideoFile(file.path, name: widget.item.name);
      if (mounted) messenger.showBriefNotice(l10n.chatImageSavedToPhotos);
    } on ArtifactCancelled {
      /* A cancelled download is not a failed save. */
    } catch (error) {
      if (!mounted) return;
      final permission = error is PlatformException && error.code == 'permission';
      messenger.showSnackBar(
        SnackBar(
          content: Text(permission ? l10n.chatImageStorageDenied : l10n.mediaVideoSaveFailed),
          persist: false,
          action: permission
              ? SnackBarAction(label: l10n.chatGoToSettings, onPressed: widget.gallery.openSettings)
              : null,
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    ++_generation;
    _poller?.cancel();
    _tapTimer?.cancel();
    _previewTimer?.cancel();
    _badgeTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_saveProgress(force: true));
    unawaited(_close(_handle));
    unawaited(_closeStream());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final handle = _handle;
    final state = _state;
    final duration = (state?.durationMs ?? 0).clamp(0, 1 << 53).toDouble();
    final position = (_seeking ?? state?.positionMs.toDouble() ?? 0).clamp(0.0, duration);
    final buffered = _bufferedFraction;
    // 拖动中的画面预览:横滑或拖进度条都出;帧没到先显示时间。
    final previewMs = _drag?.targetMs ?? _barDragMs;
    final previewBucket = previewMs == null ? null : previewMs ~/ 1000;
    final Uint8List? previewBytes = previewBucket != null && _previewBucket == previewBucket
        ? _frames[previewBucket]
        : null;
    return Theme(
      data: Theme.of(context).copyWith(brightness: Brightness.dark, colorScheme: const ColorScheme.dark()),
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          // B 站式:画面铺满整个可用区域,控制层作为浮层叠在画面上,不占布局空间。
          child: Stack(
            children: [
              Positioned.fill(
                child: Center(
                  child: _loading
                      ? Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(value: _progress),
                            const SizedBox(height: 16),
                            Text(l10n.mediaVideoLoading),
                          ],
                        )
                      : _error != null
                      ? Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _file == null ? artifactErrorText(_error!) : l10n.mediaVideoCannotPlay,
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 16),
                              FilledButton(onPressed: _load, child: Text(l10n.commonRetry)),
                            ],
                          ),
                        )
                      : handle == null
                      ? const SizedBox.shrink()
                      : GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _handleTap,
                          onLongPressStart: _commanding ? null : (_) => unawaited(_setSpeed(2.0)),
                          onLongPressEnd: (_) => unawaited(_setSpeed(1.0)),
                          onLongPressCancel: () => unawaited(_setSpeed(1.0)),
                          onHorizontalDragStart: _dragStart,
                          onHorizontalDragUpdate: _dragUpdate,
                          onHorizontalDragEnd: _dragEnd,
                          child: SizedBox.expand(
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                AspectRatio(aspectRatio: handle.aspectRatio, child: Texture(textureId: handle.texture)),
                                // 缓冲中:停住不动时能看出是在等数据,不是坏了。
                                if (state?.buffering == true)
                                  const SizedBox.square(
                                    dimension: 28,
                                    child: CircularProgressIndicator(strokeWidth: 3),
                                  ),
                                if (_speedBoosted) const _ViewerBadge(text: '»» 2×'),
                                if (_resumeMs > 0 && _drag == null && _barDragMs == null)
                                  _ViewerBadge(text: l10n.mediaVideoResumed(mediaVideoTime(_resumeMs))),
                              ],
                            ),
                          ),
                        ),
                ),
              ),
              // 拖动预览卡:锚在目标进度对应的位置,悬在控制层上方。
              if (previewMs != null && duration > 0)
                Positioned(
                  left: 24,
                  right: 24,
                  bottom: 76,
                  child: Align(
                    alignment: Alignment(((position / duration) * 2 - 1).clamp(-1.0, 1.0), 0),
                    child: _SeekPreview(
                      ms: previewMs,
                      arrows: _drag != null,
                      backward: _drag != null && _drag!.targetMs < _drag!.baseMs,
                      bytes: previewBytes,
                    ),
                  ),
                ),
              if (_controlsVisible)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: GestureDetector(
                    // 控制层自己吃掉点击:点在条上不切换画面手势。
                    behavior: HitTestBehavior.opaque,
                    onTap: () {},
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.black.withValues(alpha: 0.6), Colors.transparent],
                        ),
                      ),
                      child: Row(
                        children: [
                          IconButton(
                            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                            icon: const Icon(AppIcons.close),
                            color: Colors.white,
                            onPressed: () => Navigator.maybePop(context),
                          ),
                          Expanded(
                            child: Text(
                              widget.item.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(
                                context,
                              ).textTheme.titleMedium?.copyWith(color: Colors.white),
                            ),
                          ),
                          IconButton(
                            tooltip: l10n.mediaOpenElsewhere,
                            onPressed: _external || _loading ? null : _openExternal,
                            icon: _external
                                ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                                : const Icon(AppIcons.openWith),
                            color: Colors.white,
                          ),
                          IconButton(
                            tooltip: l10n.chatSaveToPhotos,
                            onPressed: _saving ? null : _save,
                            icon: _saving
                                ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                                : const Icon(AppIcons.save),
                            color: Colors.white,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              if (_controlsVisible && handle != null && state != null)
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {},
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          colors: [Colors.black.withValues(alpha: 0.65), Colors.transparent],
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 16, 12, 4),
                        child: Row(
                          children: [
                            IconButton(
                              tooltip: state.playing ? l10n.mediaVideoPause : l10n.mediaVideoPlay,
                              onPressed: _commanding
                                  ? null
                                  : () => _command((texture) async {
                                      if (state.playing) {
                                        await widget.video.pause(texture);
                                      } else {
                                        if (state.positionMs >= state.durationMs) await widget.video.seek(texture, 0);
                                        await widget.video.play(texture);
                                      }
                                    }),
                              icon: Icon(state.playing ? AppIcons.mediaPause : AppIcons.mediaPlay),
                              color: Colors.white,
                            ),
                            Text(mediaVideoTime(position.toInt()), style: const TextStyle(color: Colors.white)),
                            Expanded(
                              child: SliderTheme(
                                // 缓冲段画在轨道里:看得见下到哪了。
                                data: SliderTheme.of(
                                  context,
                                ).copyWith(trackShape: _BufferedSeekTrackShape(buffered: buffered ?? 0)),
                                child: Slider(
                                  value: position,
                                  max: duration > 0 ? duration : 1,
                                  onChanged: _commanding
                                      ? null
                                      : (value) {
                                          setState(() {
                                            _seeking = value;
                                            _barDragMs = value.toInt();
                                          });
                                          _queuePreview(value.toInt());
                                        },
                                  onChangeEnd: (value) {
                                    _clearPreview();
                                    setState(() {
                                      _seeking = null;
                                      _barDragMs = null;
                                    });
                                    unawaited(_command((texture) => widget.video.seek(texture, value.toInt())));
                                  },
                                ),
                              ),
                            ),
                            Text(mediaVideoTime(duration.toInt()), style: const TextStyle(color: Colors.white)),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 一次横滑快进/快退的手势会话。
class _DragSeek {
  const _DragSeek({required this.startDx, required this.baseMs, required this.targetMs});
  final double startDx;
  final int baseMs;
  final int targetMs;
}

/// 手势反馈的居中胶囊(倍速/快进快退)。
class _ViewerBadge extends StatelessWidget {
  const _ViewerBadge({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: ShapeDecoration(color: Colors.black.withValues(alpha: 0.6), shape: Squircle.border(18)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Text(
          text,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            color: Colors.white,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}

/// 拖动时的画面预览卡:缩略图(抽到后)+时间,横滑时带 »»/«« 方向。
class _SeekPreview extends StatelessWidget {
  const _SeekPreview({required this.ms, required this.arrows, required this.backward, this.bytes});

  final int ms;
  final bool arrows;
  final bool backward;
  final Uint8List? bytes;

  @override
  Widget build(BuildContext context) {
    final bytes = this.bytes;
    return DecoratedBox(
      decoration: ShapeDecoration(color: Colors.black.withValues(alpha: 0.6), shape: Squircle.border(18)),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (bytes != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.memory(bytes, width: 144, fit: BoxFit.contain, gaplessPlayback: true),
                ),
              ),
            Text(
              '${arrows ? (backward ? '«« ' : '»» ') : ''}${mediaVideoTime(ms)}',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Colors.white,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 进度条轨道:底轨 + 已缓冲段 + 已播段。缓冲前沿来自流式代理的窗口缓存
/// (本地/整文件恒为满),让"下到哪了"看得见。
class _BufferedSeekTrackShape extends RoundedRectSliderTrackShape {
  const _BufferedSeekTrackShape({required this.buffered});

  final double buffered;

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 2,
  }) {
    assert(textDirection == TextDirection.ltr, '视频播放器只支持 LTR 布局');
    final trackRect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final radius = Radius.circular(trackRect.height / 2);
    final paint = Paint();
    paint.color = Colors.white.withValues(alpha: 0.24);
    context.canvas.drawRRect(RRect.fromRectAndRadius(trackRect, radius), paint);
    final bufferedRight = trackRect.left + trackRect.width * buffered.clamp(0.0, 1.0);
    if (bufferedRight - trackRect.left > 1) {
      paint.color = Colors.white.withValues(alpha: 0.45);
      context.canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTRB(trackRect.left, trackRect.top, bufferedRight, trackRect.bottom), radius),
        paint,
      );
    }
    final activeRight = thumbCenter.dx.clamp(trackRect.left, trackRect.right);
    paint.color = Colors.white;
    context.canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTRB(trackRect.left, trackRect.top, activeRight, trackRect.bottom), radius),
      paint,
    );
  }
}
