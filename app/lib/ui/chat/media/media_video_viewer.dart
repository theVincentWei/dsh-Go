import 'dart:async';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../media/gallery.dart';
import '../../../media/media_playback.dart';
import '../../../media/video.dart' show MediaVideoChannel, mediaVideoChannelProvider, mediaVideoTime;
import '../../../media/video_progress.dart';
import '../../../media/video_stream_server.dart';
import '../../../state/artifact_files.dart';
import '../../../state/artifacts.dart';
import '../../common/brief_notice.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';

/// Capture the Host before navigation; a later active-host switch cannot move
/// this viewer's download, retry, save or external playback to another Host.
/// 音频与视频共用这一个应用内播放器:纯音频(无视频轨)走音频形态。
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

class _MediaVideoViewerPageState extends State<MediaVideoViewerPage> {
  late final MediaPlayback _playback;

  bool _controlsVisible = true;
  Timer? _tapTimer;

  /// 横滑快进快退的一次手势:起点横坐标、基准播放位置、当前预览目标。
  int get _seekSpanMs => 120 * 1000; // 一个屏宽 ≈ 2 分钟,B 站量级。

  _DragSeek? _drag;

  @override
  void initState() {
    super.initState();
    _playback = MediaPlayback(
      files: widget.files,
      video: widget.video,
      sessionId: widget.sessionId,
      path: widget.item.path,
      name: widget.item.name,
      mime: widget.item.mime,
      streamServer: widget.streamServer,
      progressStore: widget.progressStore,
    )..open();
  }

  @override
  void dispose() {
    _tapTimer?.cancel();
    _playback.dispose();
    super.dispose();
  }

  Artifact get _artifact => Artifact(path: widget.item.path, origin: ArtifactOrigin.linked, turn: 0);

  /// 单击:切控制层显隐。双击(B 站语义):撤销单击的控制层开关、控制层
  /// 保持显示、播放/暂停。自数双击而不用 onDoubleTap:单击零延迟,300ms 内
  /// 的第二下不会被误判成"切两次控制层"。
  void _handleTap() {
    final pending = _tapTimer;
    if (pending != null) {
      pending.cancel();
      _tapTimer = null;
      setState(() => _controlsVisible = true);
      _playback.togglePlay();
      return;
    }
    setState(() => _controlsVisible = !_controlsVisible);
    _tapTimer = Timer(const Duration(milliseconds: 300), () => _tapTimer = null);
  }

  void _dragStart(DragStartDetails details) {
    final state = _playback.state;
    if (_playback.handle == null || state == null || state.durationMs <= 0 || _drag != null) return;
    setState(() {
      _drag = _DragSeek(startDx: details.globalPosition.dx, baseMs: state.positionMs, targetMs: state.positionMs);
    });
    _playback.dragTo(state.positionMs);
  }

  void _dragUpdate(DragUpdateDetails details) {
    final drag = _drag;
    final state = _playback.state;
    if (drag == null || state == null) return;
    final width = MediaQuery.sizeOf(context).width;
    final dx = details.globalPosition.dx - drag.startDx;
    final target = (drag.baseMs + dx / (width > 1 ? width : 1) * _seekSpanMs).round().clamp(0, state.durationMs);
    if (target == drag.targetMs) return;
    setState(() {
      _drag = _DragSeek(startDx: drag.startDx, baseMs: drag.baseMs, targetMs: target);
    });
    _playback.dragTo(target);
  }

  void _dragEnd(DragEndDetails details) {
    final drag = _drag;
    if (drag == null) return;
    setState(() => _drag = null);
    _playback.dragEnd(drag.targetMs);
  }

  /// 系统分享面板把文件发出去(和卡片上的分享同一入口):整文件先落地,
  /// 是和保存到相册同级的显式下载。
  Future<void> _share() async {
    final playback = _playback;
    if (playback.sharing) return;
    playback.sharing = true;
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (playback.handle case final handle?) {
        try {
          await widget.video.pause(handle.texture);
        } catch (_) {
          /* Sharing must still work when the player is gone. */
        }
      }
      await widget.files.share(widget.sessionId, _artifact);
    } catch (error) {
      if (mounted) messenger.showSnackBar(SnackBar(content: Text(artifactErrorText(error))));
    } finally {
      playback.sharing = false;
    }
  }

  /// 视频存进相册;音频存进「下载」。都是显式下载:整文件先落地。
  Future<void> _save() async {
    final playback = _playback;
    if (playback.saving) return;
    playback.saving = true;
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.l10n;
    try {
      if (playback.audioOnly) {
        final where = await widget.files.saveToDownloads(widget.sessionId, _artifact);
        if (mounted) {
          messenger.showBriefNotice(
            l10n.viewArtifactSaved(where.replaceFirst(RegExp(r'^Download/'), l10n.viewDownloadFolder)),
          );
        }
        return;
      }
      var file = playback.localCopy;
      if (file == null) {
        // The one explicit download: whole file, shown in the global task
        // bar, cancellable. Streaming playback never materializes on its own.
        file = await widget.files.materialize(widget.sessionId, _artifact, taskLabel: widget.item.name);
        playback.localCopy = file;
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
      playback.saving = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(brightness: Brightness.dark, colorScheme: const ColorScheme.dark()),
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          // B 站式:画面/音频艺术铺满整个可用区域,控制层作为浮层叠在上面,不占布局空间。
          child: ListenableBuilder(
            listenable: _playback,
            builder: (context, _) {
              final l10n = context.l10n;
              final playback = _playback;
              final handle = playback.handle;
              final state = playback.state;
              final duration = (state?.durationMs ?? 0).clamp(0, 1 << 53).toDouble();
              final position = playback.displayMs.toDouble().clamp(0.0, duration);
              final buffered = playback.bufferedFraction;
              // 拖动中的画面预览:横滑或拖进度条都出;帧没到先显示时间。
              final previewMs = _drag?.targetMs ?? playback.dragMs;
              final previewBucket = previewMs == null ? null : previewMs ~/ 1000;
              final previewBytes = playback.previewFrame(previewBucket);
              final audioOnly = playback.audioOnly;
              return Stack(
                children: [
                  Positioned.fill(
                    child: Center(
                      child: playback.loading
                          ? Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                CircularProgressIndicator(value: playback.downloadProgress),
                                const SizedBox(height: 16),
                                Text(l10n.mediaVideoLoading),
                              ],
                            )
                          : playback.error != null
                          ? Padding(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    playback.localCopy == null && !audioOnly
                                        ? artifactErrorText(playback.error!)
                                        : l10n.mediaVideoCannotPlay,
                                    textAlign: TextAlign.center,
                                  ),
                                  const SizedBox(height: 16),
                                  FilledButton(
                                    onPressed: playback.reopen,
                                    child: Text(l10n.commonRetry),
                                  ),
                                ],
                              ),
                            )
                          : handle == null
                          ? const SizedBox.shrink()
                          : GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: _handleTap,
                              onLongPressStart: playback.commanding ? null : (_) => unawaited(_playback.setSpeed(2.0)),
                              onLongPressEnd: (_) => unawaited(_playback.setSpeed(1.0)),
                              onLongPressCancel: () => unawaited(_playback.setSpeed(1.0)),
                              onHorizontalDragStart: _dragStart,
                              onHorizontalDragUpdate: _dragUpdate,
                              onHorizontalDragEnd: _dragEnd,
                              child: SizedBox.expand(
                                child: Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    if (audioOnly)
                                      const _AudioArt()
                                    else
                                      AspectRatio(aspectRatio: handle.aspectRatio, child: Texture(textureId: handle.texture)),
                                    // 缓冲中:停住不动时能看出是在等数据,不是坏了。
                                    if (state?.buffering == true)
                                      const SizedBox.square(
                                        dimension: 28,
                                        child: CircularProgressIndicator(strokeWidth: 3),
                                      ),
                                    if (playback.speedBoosted) const _ViewerBadge(text: '»» 2×'),
                                    if (playback.resumeMs > 0 && _drag == null && playback.dragMs == null)
                                      _ViewerBadge(text: l10n.mediaVideoResumed(mediaVideoTime(playback.resumeMs))),
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
                                tooltip: l10n.commonShare,
                                onPressed: playback.sharing || playback.loading ? null : _share,
                                icon: playback.sharing
                                    ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                                    : const Icon(AppIcons.share),
                                color: Colors.white,
                              ),
                              IconButton(
                                tooltip: audioOnly ? l10n.chatSaveToDownloads : l10n.chatSaveToPhotos,
                                onPressed: playback.saving || playback.loading ? null : _save,
                                icon: playback.saving
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
                                  onPressed: playback.commanding
                                      ? null
                                      : () => _playback.togglePlay(),
                                  icon: Icon(state.playing ? AppIcons.mediaPause : AppIcons.mediaPlay),
                                  color: Colors.white,
                                ),
                                Text(mediaVideoTime(position.toInt()), style: const TextStyle(color: Colors.white)),
                                Expanded(
                                  child: SliderTheme(
                                    // 小而白的播放点:默认的紫大头钳太重。
                                    data: SliderTheme.of(context).copyWith(
                                      // 缓冲段画在轨道里:看得见下到哪了。
                                      trackShape: _BufferedSeekTrackShape(buffered: buffered ?? 0),
                                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6, elevation: 0),
                                      thumbColor: Colors.white,
                                      overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                                      overlayColor: Colors.white.withValues(alpha: 0.12),
                                    ),
                                    child: Slider(
                                      value: position,
                                      max: duration > 0 ? duration : 1,
                                      onChanged: playback.commanding
                                          ? null
                                          : (value) => _playback.dragTo(value.toInt()),
                                      onChangeEnd: (value) => _playback.dragEnd(value.toInt()),
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
              );
            },
          ),
        ),
      ),
    );
  }

}

/// 音频形态的画面层:没有纹理,给一个安静的「音符」艺术位。
class _AudioArt extends StatelessWidget {
  const _AudioArt();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 128,
          height: 128,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withValues(alpha: 0.08),
          ),
          child: const Icon(AppIcons.audio, size: 56, color: Colors.white70),
        ),
      ],
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
