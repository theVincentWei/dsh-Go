package io.github.ccch1mneyyy.dsh_app.dimina

import android.app.Activity
import android.content.Context
import android.os.Handler
import android.os.Looper
import com.didi.dimina.Dimina
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

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        if (!initialized) {
            initialized = true
            Dimina.init(
                appContext,
                Dimina.DiminaConfig.Builder()
                    .setDebugMode(true)
                    .setVirtualFilePrefix("host-file://")
                    .build(),
            )
        }
        channel = MethodChannel(binding.binaryMessenger, "dsh/dimina").also { it.setMethodCallHandler(this) }
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
                val miniProgram = MiniProgram(
                    appId = appId,
                    name = call.argument<String>("name") ?: appId,
                    path = call.argument<String>("path"),
                    versionCode = call.argument<Number>("versionCode")?.toInt() ?: 0,
                    versionName = call.argument<String>("versionName") ?: "",
                    updateManifestUrl = call.argument<String>("updateManifestUrl") ?: "",
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
