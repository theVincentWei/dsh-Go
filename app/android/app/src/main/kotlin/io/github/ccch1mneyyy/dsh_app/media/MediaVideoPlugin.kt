package io.github.ccch1mneyyy.dsh_app.media

import android.app.Activity
import android.app.Application
import android.content.Context
import android.graphics.Bitmap
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaMetadataRetriever
import android.media.MediaPlayer
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.WindowManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** Local materialized videos and loopback stream URLs; separate from launch playback. */
class MediaVideoPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {
    private lateinit var methods: MethodChannel
    private lateinit var textures: TextureRegistry
    private lateinit var app: Application
    private lateinit var audio: AudioManager
    private val main = Handler(Looper.getMainLooper())
    private val clips = HashMap<Long, Clip>()
    private val posterWorker = Executors.newSingleThreadExecutor { r -> Thread(r, "dsh-video-poster").apply { isDaemon = true } }
    private val probing = AtomicBoolean(false)
    private var activity: Activity? = null
    private var foreground = false
    private var attached = false
    private var keepScreenOn = false
    private var focusListener: AudioManager.OnAudioFocusChangeListener? = null
    /** 纯音频(没有视频轨)也走这个播放器:画面交给 App 侧的音频形态渲染。 */
    private class Clip(val producer: TextureRegistry.SurfaceProducer, val player: MediaPlayer) {
        var prepared = false
        var audioOnly = false
        var pending: MethodChannel.Result? = null
        var timeout: Runnable? = null
        var buffering = false
    }
    private val lifecycle = object : Application.ActivityLifecycleCallbacks {
        override fun onActivityResumed(a: Activity) { if (a === activity) foreground = true }
        override fun onActivityPaused(a: Activity) { if (a === activity) { foreground = false; pauseAll() } }
        override fun onActivityCreated(a: Activity, state: Bundle?) {}
        override fun onActivityStarted(a: Activity) {}
        override fun onActivityStopped(a: Activity) {}
        override fun onActivitySaveInstanceState(a: Activity, state: Bundle) {}
        override fun onActivityDestroyed(a: Activity) { if (a === activity) closeAll() }
    }
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        app = binding.applicationContext as Application
        audio = app.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        textures = binding.textureRegistry
        methods = MethodChannel(binding.binaryMessenger, "dsh/media_video").also { it.setMethodCallHandler(this) }
        attached = true
        app.registerActivityLifecycleCallbacks(lifecycle)
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        attached = false
        methods.setMethodCallHandler(null)
        app.unregisterActivityLifecycleCallbacks(lifecycle)
        closeAll()
        posterWorker.shutdownNow()
    }
    override fun onAttachedToActivity(binding: ActivityPluginBinding) { activity = binding.activity }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    override fun onDetachedFromActivityForConfigChanges() { foreground = false; closeAll(); activity = null }
    override fun onDetachedFromActivity() = onDetachedFromActivityForConfigChanges()

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "open" -> openFile(call.argument<String>("path"), result)
            "openUrl" -> openUrl(call.argument<String>("url"), result)
            "poster" -> poster(call.argument<String>("path"), result)
            "posterUrl" -> posterUrl(call.argument<String>("url"), result)
            "frame" -> frame(call.argument<String>("path"), call.argument<Number>("timeMs")?.toLong() ?: 0L, result)
            "frameUrl" -> frameUrl(call.argument<String>("url"), call.argument<Number>("timeMs")?.toLong() ?: 0L, result)
            else -> {
                val id = call.argument<Number>("texture")?.toLong() ?: -1L
                if (call.method == "close") { close(id); result.success(null); return }
                val clip = clips[id]
                if (clip == null || !clip.prepared) { result.error("closed", "video is closed", null); return }
                try {
                    when (call.method) {
                        "play" -> {
                            if (!foreground) { result.error("background", "app is not in foreground", null); return }
                            if (!requestFocus()) { result.error("audio_focus", "audio focus unavailable", null); return }
                            clips.values.filter { it !== clip && it.prepared }.forEach { runCatching { it.player.pause() } }
                            clip.player.start()
                            updateKeepScreenOn()
                            result.success(null)
                        }
                        "pause" -> { clip.player.pause(); abandonFocus(); updateKeepScreenOn(); result.success(null) }
                        "seek" -> {
                            val position = MediaVideos.seek(call.argument<Number>("positionMs")?.toLong() ?: 0, clip.player.duration)
                            if (Build.VERSION.SDK_INT >= 26) clip.player.seekTo(position.toLong(), MediaPlayer.SEEK_CLOSEST_SYNC) else clip.player.seekTo(position)
                            result.success(null)
                        }
                        "speed" -> {
                            val rate = call.argument<Number>("rate")?.toFloat() ?: 1f
                            if (Build.VERSION.SDK_INT >= 23) {
                                clip.player.playbackParams = clip.player.playbackParams.setSpeed(rate)
                            }
                            result.success(null)
                        }
                        "state" -> result.success(mapOf("positionMs" to clip.player.currentPosition, "durationMs" to clip.player.duration, "playing" to clip.player.isPlaying, "buffering" to clip.buffering))
                        else -> result.notImplemented()
                    }
                } catch (_: Exception) { close(id); result.error("playback", "video playback failed", null) }
            }
        }
    }

    private fun openFile(path: String?, result: MethodChannel.Result) {
        if (!MediaVideos.localFile(path)) { result.error("invalid", "a local video file is required", null); return }
        startSession({ player -> FileInputStream(path!!).use { player.setDataSource(it.fd) } }, result)
    }

    private fun openUrl(url: String?, result: MethodChannel.Result) {
        if (!MediaVideos.loopbackUrl(url)) { result.error("invalid", "a loopback stream url is required", null); return }
        startSession({ player -> player.setDataSource(url) }, result)
    }

    private fun startSession(setSource: (MediaPlayer) -> Unit, result: MethodChannel.Result) {
        closeAll()
        var producer: TextureRegistry.SurfaceProducer? = null
        var player: MediaPlayer? = null
        try {
            producer = textures.createSurfaceProducer()
            player = MediaPlayer()
            val p = player
            val surface = producer
            val id = surface.id()
            val clip = Clip(surface, p).also { it.pending = result }
            clips[id] = clip
            val timeout = Runnable { if (clip.pending != null) close(id, "timeout") }
            clip.timeout = timeout
            main.postDelayed(timeout, 20_000)
            surface.setCallback(object : TextureRegistry.SurfaceProducer.Callback {
                override fun onSurfaceAvailable() { if (clips[id] === clip) runCatching { p.setSurface(surface.surface) } }
                override fun onSurfaceCleanup() {
                    if (clips[id] === clip) { pauseAll(); runCatching { p.setSurface(null) } }
                }
            })
            p.setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_MOVIE).build())
            p.setOnVideoSizeChangedListener { _, w, h -> if (clips[id] === clip && w > 0 && h > 0) surface.setSize(w, h) }
            p.setOnCompletionListener { if (clips[id] === clip) { abandonFocus(); updateKeepScreenOn() } }
            p.setOnInfoListener { _, what, _ ->
                if (clips[id] !== clip) return@setOnInfoListener false
                when (what) {
                    MediaPlayer.MEDIA_INFO_BUFFERING_START -> clip.buffering = true
                    MediaPlayer.MEDIA_INFO_BUFFERING_END -> clip.buffering = false
                }
                false
            }
            p.setOnErrorListener { _, _, _ -> close(id, "playback"); true }
            p.setOnPreparedListener {
                if (clips[id] !== clip) return@setOnPreparedListener
                // 没有视频轨=纯音频:照常 prepared,宽高报 0,App 侧走音频形态;
                // 纹理不会来帧,也不再据此拒播。
                val audioOnly = it.videoWidth <= 0 || it.videoHeight <= 0
                if (audioOnly && it.duration <= 0) { close(id, "unsupported"); return@setOnPreparedListener }
                clip.prepared = true
                clip.audioOnly = audioOnly
                if (!audioOnly) surface.setSize(it.videoWidth, it.videoHeight)
                clip.timeout?.let(main::removeCallbacks)
                val pending = clip.pending
                clip.pending = null
                pending?.success(
                    mapOf(
                        "texture" to id,
                        "width" to it.videoWidth,
                        "height" to it.videoHeight,
                        "durationMs" to it.duration,
                        "audioOnly" to audioOnly,
                    )
                )
            }
            setSource(p)
            p.setSurface(surface.surface)
            p.prepareAsync()
        } catch (_: Exception) {
            val id = producer?.id()
            if (id != null && clips.containsKey(id)) close(id, "unsupported") else {
                runCatching { player?.release() }
                runCatching { producer?.release() }
                result.error("unsupported", "cannot open video", null)
            }
        }
    }

    private fun requestFocus(): Boolean {
        if (focusListener != null) return true
        val listener = object : AudioManager.OnAudioFocusChangeListener {
            override fun onAudioFocusChange(change: Int) {
                if (change <= 0) main.post {
                    // A queued loss must not pause a later request; cleanup here is best effort.
                    if (focusListener === this) runCatching { pauseAll() }
                }
            }
        }
        focusListener = listener
        var granted = false
        try {
            granted = audio.requestAudioFocus(listener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
            return granted
        } finally {
            if (!granted) abandonFocus()
        }
    }
    private fun abandonFocus() {
        val listener = focusListener ?: return
        focusListener = null
        audio.abandonAudioFocus(listener)
    }
    private fun pauseAll() {
        clips.values.filter { it.prepared }.forEach { runCatching { it.player.pause() } }
        abandonFocus()
        updateKeepScreenOn()
    }
    private fun closeAll() { clips.keys.toList().forEach { close(it) }; abandonFocus() }

    /** 播放中屏幕常亮:窗口级 FLAG_KEEP_SCREEN_ON,前台有效、暂停即灭,不需要任何权限。纯音频不锁屏。 */
    private fun updateKeepScreenOn() {
        val on = clips.values.any { clip ->
            !clip.audioOnly && clip.prepared && runCatching { clip.player.isPlaying }.getOrDefault(false)
        }
        if (on == keepScreenOn) return
        keepScreenOn = on
        val window = activity?.window ?: return
        if (on) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }
    private fun close(id: Long, code: String = "closed") {
        val clip = clips.remove(id) ?: return
        clip.timeout?.let(main::removeCallbacks)
        clip.pending?.error(code, "video unavailable", null)
        clip.pending = null
        runCatching { clip.player.release() }
        runCatching { clip.producer.release() }
        if (clips.isEmpty()) abandonFocus()
        updateKeepScreenOn()
    }

    private fun poster(path: String?, result: MethodChannel.Result) {
        if (!MediaVideos.localFile(path)) { result.error("invalid", "a local video file is required", null); return }
        extractFrame({ retriever -> FileInputStream(path!!).use { retriever.setDataSource(it.fd) } }, 0L, MediaVideos.POSTER_MAX_DIM, 80, result)
    }

    private fun posterUrl(url: String?, result: MethodChannel.Result) {
        if (!MediaVideos.loopbackUrl(url)) { result.error("invalid", "a loopback stream url is required", null); return }
        extractFrame({ retriever -> retriever.setDataSource(url, HashMap<String, String>()) }, 0L, MediaVideos.POSTER_MAX_DIM, 80, result)
    }

    /// 拖动进度条的画面预览:同海报一路的抽帧,任意时刻、更小的图。
    private fun frame(path: String?, timeMs: Long, result: MethodChannel.Result) {
        if (!MediaVideos.localFile(path)) { result.error("invalid", "a local video file is required", null); return }
        extractFrame({ retriever -> FileInputStream(path!!).use { retriever.setDataSource(it.fd) } }, timeMs * 1000, MediaVideos.PREVIEW_MAX_DIM, 75, result)
    }

    private fun frameUrl(url: String?, timeMs: Long, result: MethodChannel.Result) {
        if (!MediaVideos.loopbackUrl(url)) { result.error("invalid", "a loopback stream url is required", null); return }
        extractFrame({ retriever -> retriever.setDataSource(url, HashMap<String, String>()) }, timeMs * 1000, MediaVideos.PREVIEW_MAX_DIM, 75, result)
    }

    private fun extractFrame(setSource: (MediaMetadataRetriever) -> Unit, timeUs: Long, maxDim: Int, quality: Int, result: MethodChannel.Result) {
        // A broken platform decoder must not accumulate workers when cards scroll.
        if (!probing.compareAndSet(false, true)) { result.success(null); return }
        var answered = false
        val timeout = Runnable { if (!answered) { answered = true; result.error("timeout", "frame extraction timed out", null) } }
        main.postDelayed(timeout, 10_000)
        posterWorker.execute {
            val bytes = runCatching {
                val retriever = MediaMetadataRetriever()
                try {
                    setSource(retriever)
                    val w = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
                    val h = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
                    if (w <= 0 || h <= 0) return@runCatching null
                    // API 26 cannot request a scaled frame: avoid a large full-resolution
                    // bitmap just for a scrolling card or a drag preview. Playback is still available.
                    if (Build.VERSION.SDK_INT < 27 && w.toLong() * h > 4_000_000L) return@runCatching null
                    val (pw, ph) = MediaVideos.scaledSize(w, h, maxDim)
                    val frame = if (Build.VERSION.SDK_INT >= 27) retriever.getScaledFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, pw, ph) else retriever.getFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                    if (frame == null) return@runCatching null
                    try {
                        val (sw, sh) = MediaVideos.scaledSize(frame.width, frame.height, maxDim)
                        val scaled = if (sw == frame.width && sh == frame.height) frame else Bitmap.createScaledBitmap(frame, sw, sh, true)
                        try { ByteArrayOutputStream().use { scaled.compress(Bitmap.CompressFormat.JPEG, quality, it); it.toByteArray() } }
                        finally { if (scaled !== frame) scaled.recycle() }
                    } finally { frame.recycle() }
                } finally { runCatching { retriever.release() } }
            }.getOrNull()
            probing.set(false)
            main.post {
                main.removeCallbacks(timeout)
                if (!answered) { answered = true; if (attached) result.success(bytes) }
            }
        }
    }
}

internal object MediaVideos {
    fun localFile(path: String?): Boolean = path != null && File(path).isAbsolute && File(path).isFile

    /** Only the app's own loopback stream server may be handed to the player. */
    private val LOOPBACK_HOSTS = setOf("localhost", "127.0.0.1", "[::1]", "::1", "[0:0:0:0:0:0:0:1]")
    fun loopbackUrl(url: String?): Boolean {
        if (url.isNullOrEmpty()) return false
        val uri = runCatching { Uri.parse(url) }.getOrNull() ?: return false
        if ((uri.scheme ?: "").lowercase() != "http") return false
        val host = (uri.host ?: return false).lowercase()
        return host in LOOPBACK_HOSTS
    }

    fun seek(position: Long, duration: Int): Int = position.coerceIn(0L, maxOf(0, duration).toLong()).toInt()

    /// 卡片海报 / 拖动预览各自的最长边(像素)。预览小一档:屏幕上一闪而过。
    const val POSTER_MAX_DIM = 512
    const val PREVIEW_MAX_DIM = 320

    fun scaledSize(width: Int, height: Int, maxDim: Int): Pair<Int, Int> {
        val scale = minOf(1.0, maxDim.toDouble() / maxOf(1, width, height))
        return maxOf(1, (width * scale).toInt()) to maxOf(1, (height * scale).toInt())
    }
}
