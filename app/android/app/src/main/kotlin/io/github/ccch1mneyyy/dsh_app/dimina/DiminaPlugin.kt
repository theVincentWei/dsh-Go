package io.github.ccch1mneyyy.dsh_app.dimina

import android.app.Activity
import android.content.Context
import android.content.pm.ApplicationInfo
import android.os.Handler
import android.os.Looper
import com.didi.dimina.Dimina
import com.didi.dimina.MiniProgramUpdateListener
import com.didi.dimina.bean.MiniProgram
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File

/**
 * Flutter bridge to the Dimina (星河) mini-program container: MethodChannel `dsh/dimina`
 * (Dart side: lib/ui/applet/dimina/dimina_host.dart). M0 POC on feat/apphub-dimina.
 *
 * The SDK is initialized once per engine, in onAttachedToEngine — before any Dart call
 * can reach the channel — with debug mode on so vConsole is available on the phone
 * while the POC is iterated. `setVirtualFilePrefix` is the Dimina docs' required
 * pairing between native path resolution and the logic layer.
 */
class DiminaPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {

    private lateinit var channel: MethodChannel
    private lateinit var appContext: Context
    private var activity: Activity? = null
    private val main = Handler(Looper.getMainLooper())
    private var lastDark: Boolean? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "dsh/dimina").also { it.setMethodCallHandler(this) }
    }

    /**
     * 惰性初始化:首次 open 时才 init,以便按宿主当前亮度定胶囊配色
     * (config 初始化后不可变,运行中切主题不跟随——见 miniprogram-spec.md §8)。
     */
    private fun ensureInitialized(dark: Boolean) {
        if (initialized) return
        initialized = true
        lastDark = dark
        Dimina.init(
            appContext,
            Dimina.DiminaConfig.Builder()
                // vConsole 只跟 debug 包:release 用户不该看到调试悬浮窗。
                // 不用 BuildConfig(工程未开 buildFeatures.buildConfig),
                // 读实际安装包的 FLAG_DEBUGGABLE,flutter run 有、release 无。
                .setDebugMode((appContext.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0)
                // 多任务模式:小程序跑在独立 task 里。关着的时候,根页返回会走
                // exitMiniProgram 直接销毁整个小程序;开着才是「隐藏保栈、把宿主
                // 页面带回前台」,子页返回照旧一层一层弹(DiminaActivity 每页一个
                // Activity,back=finish)。
                .setEnableMultiTask(true)
                // 胶囊配色跟宿主亮度:深色=深底白图标,浅色=白底深图标。
                .setCapsuleBackgroundColor(if (dark) 0xFF2A2D34.toInt() else android.graphics.Color.WHITE)
                .setCapsuleIconColor(if (dark) android.graphics.Color.WHITE else 0xFF1F1F1F.toInt())
                .setVirtualFilePrefix("host-file://")
                .build(),
        )
        // 同步主题覆写:否则菜单面板读 isCapsuleThemeDark() 拿到 null→浅色,
        // 而胶囊(init 配置)已是深色——两处不一致。
        Dimina.getInstance().updateCapsuleTheme(dark)
        // 框架升级链路:升级的检测/下载/弹窗确认/换包全在容器侧,小程序不参与;
        // 这里只把升级里程碑转发给 Flutter(市场页按真实状态刷新,不再轮询猜)。
        Dimina.getInstance().setOnMiniProgramUpdateListener(object : MiniProgramUpdateListener {
            override fun onUpdateReady(appId: String, versionCode: Int, versionName: String) =
                forwardUpdateEvent("ready", appId, versionCode, versionName, null)

            override fun onUpdateDeclined(appId: String, versionCode: Int) =
                forwardUpdateEvent("declined", appId, versionCode, "", null)

            override fun onUpdateApplied(appId: String, versionCode: Int, versionName: String) =
                forwardUpdateEvent("applied", appId, versionCode, versionName, null)

            override fun onUpdateFailed(appId: String, message: String?) =
                forwardUpdateEvent("failed", appId, 0, "", message)

            override fun onInstalled(appId: String, versionCode: Int, versionName: String) =
                forwardUpdateEvent("installed", appId, versionCode, versionName, null)
        })
    }

    private fun forwardUpdateEvent(
        event: String,
        appId: String,
        versionCode: Int,
        versionName: String,
        message: String?,
    ) {
        main.post {
            try {
                channel.invokeMethod(
                    "onUpdateEvent",
                    mapOf(
                        "event" to event,
                        "appId" to appId,
                        "versionCode" to versionCode,
                        "versionName" to versionName,
                        "message" to message,
                    ),
                )
            } catch (_: Throwable) {
                // Dart 侧没挂 handler 或引擎正在销毁:静默,只丢这一次。
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "open" -> {
                val appId = call.argument<String>("appId")
                if (appId.isNullOrBlank()) {
                    result.error("BAD_ARGS", "appId is required", null)
                    return
                }
                val host = activity
                if (host == null) {
                    result.error("NO_ACTIVITY", "Flutter activity is not attached", null)
                    return
                }
                // 首次打开按宿主亮度初始化(胶囊配色跟主题);
                // 已初始化但亮度变化 → 运行时更新(源码版 updateCapsuleTheme)。
                val dark = call.argument<Boolean>("dark") ?: false
                if (!initialized) {
                    ensureInitialized(dark)
                    lastDark = dark
                } else if (lastDark != dark) {
                    Dimina.getInstance().updateCapsuleTheme(dark)
                    lastDark = dark
                }
                val miniProgram = MiniProgram(
                    appId = appId,
                    name = call.argument<String>("name") ?: appId,
                    path = call.argument<String>("path"),
                    versionCode = call.argument<Number>("versionCode")?.toInt() ?: 0,
                    versionName = call.argument<String>("versionName") ?: "",
                    updateManifestUrl = call.argument<String>("updateManifestUrl") ?: "",
                    // 宿主栅格化的应用图标(桌面/市场同款字形);null=弹层回落首字母瓦片
                    iconPng = call.argument<ByteArray>("iconPng"),
                )
                try {
                    // SDK manages its own activity stack; must be called on the main thread.
                    Dimina.getInstance().startMiniProgram(host, miniProgram)
                    result.success(true)
                } catch (error: Throwable) {
                    result.error("OPEN_FAILED", error.message, null)
                }
            }
            "close" -> {
                val appId = call.argument<String>("appId") ?: run {
                    result.error("BAD_ARGS", "appId is required", null)
                    return
                }
                // closeMiniProgram must run on the main thread (Dimina docs).
                main.post { result.success(Dimina.getInstance().closeMiniProgram(appId)) }
            }
            "uninstall" -> {
                val appId = call.argument<String>("appId") ?: run {
                    result.error("BAD_ARGS", "appId is required", null)
                    return
                }
                val clearUserData = call.argument<Boolean>("clearUserData") ?: false
                Dimina.getInstance().uninstallMiniProgram(appId, clearUserData) { outcome ->
                    outcome.onFailure { error ->
                        main.post { result.error("UNINSTALL_FAILED", error.message, null) }
                    }
                    outcome.onSuccess {
                        main.post { result.success(true) }
                    }
                }
            }
            "installed" -> {
                val appId = call.argument<String>("appId") ?: run {
                    result.error("BAD_ARGS", "appId is required", null)
                    return
                }
                // Dimina 沙盒配置:${filesDir}/jsapp/<appId>/config.json(更新机制文档)。
                main.post {
                    try {
                        val file = File(appContext.filesDir, "jsapp/$appId/config.json")
                        if (!file.isFile) {
                            result.success(mapOf("installed" to false))
                            return@post
                        }
                        val cfg = JSONObject(file.readText())
                        result.success(
                            mapOf(
                                "installed" to true,
                                "versionCode" to cfg.optInt("versionCode", 0),
                                "versionName" to cfg.optString("versionName", ""),
                            ),
                        )
                    } catch (error: Throwable) {
                        result.error("QUERY_FAILED", error.message, null)
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    companion object {
        @Volatile
        private var initialized = false
    }
}
