package io.github.ccch1mneyyy.dsh_app.dimina

import android.app.Activity
import android.content.Context
import android.content.pm.ApplicationInfo
import android.os.Handler
import android.os.Looper
import com.didi.dimina.Dimina
import com.didi.dimina.MiniProgramUpdateListener
import com.didi.dimina.bean.MiniProgram
import com.didi.dimina.core.MiniApp
import com.didi.dimina.core.MiniProgramLifecycleListener
import com.didi.dimina.core.RetentionPolicy
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
     * 惰性初始化:首次 open 时才 init。胶囊配色传浅/深两套(见 miniprogram-spec.md §8),
     * 容器运行时按当前主题选一套,不再依赖「init 那一刻的亮度」。
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
                // 胶囊配色跟宿主色板:浅色=白底深图标,深色=深底白图标。传浅/深两套,
                // 容器按当前主题运行时选一套 —— 旧单色 API 的 config 初始化后不可变,
                // 运行中切主题胶囊会凝固在 init 那一刻,两个方向都「时对时不对」。
                .setCapsuleThemeColors(
                    lightBackgroundColor = android.graphics.Color.WHITE,
                    lightIconColor = 0xFF1F1F1F.toInt(),
                    darkBackgroundColor = 0xFF2A2D34.toInt(),
                    darkIconColor = android.graphics.Color.WHITE,
                )
                .setVirtualFilePrefix("host-file://")
                .build(),
        )
        // 同步主题覆写:否则菜单面板读 isCapsuleThemeDark() 拿到 null→浅色,
        // 而胶囊(init 配置)已是深色——两处不一致。
        Dimina.getInstance().updateCapsuleTheme(dark)
        // 浮窗保活(2026-11-12 拍板 30 分钟):✕/根页返回改真退出后,后台活着的
        // 只剩浮窗应用;最多 3 个,超 30 分钟运行时回收(下次冷启动,storage 不丢)。
        MiniApp.getInstance().configureRetention(
            RetentionPolicy(maxBackgroundApps = 3, backgroundTimeoutMs = 30L * 60 * 1000),
        )
        // 宿主扩展通道:小程序 requestSubscribeMessage → 原生订阅面板(契约 §5.2/§5.3)。
        // 注册发生在 Dimina.init 之后(框架的扩展模块表此时才可用)。
        registerNotifyExtModule()
        // 平台权限契约 v1 §6:第二扩展模块 dsh-permissions——容器侧 consent 的
        // 宿主读写口(容器 JS 查/置 per-appid 授权态)。注册时机同 dsh-notify。
        registerPermissionsExtModule()
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
        // 浮窗链路(2026-11-12 单球拍板):⋯菜单「浮窗」收后台/回前台/运行时销毁
        // 三个事件转发给 Dart 画浮窗球。回调已在主线程(MiniApp.notify* 内部 post
        // main),这里再套 main.post 兜底;invokeMethod 失败(Dart 没挂 handler/
        // 引擎销毁)静默——球状态由下一次事件校正。
        Dimina.getInstance().setOnMiniProgramLifecycleListener(object : MiniProgramLifecycleListener {
            private fun forward(type: String, appId: String, appName: String? = null, iconPng: ByteArray? = null) {
                main.post {
                    try {
                        channel.invokeMethod(
                            "onDiminaEvent",
                            mapOf(
                                "type" to type,
                                "appId" to appId,
                                "appName" to (appName ?: appId),
                                "iconPng" to iconPng,
                            ),
                        )
                    } catch (_: Throwable) {
                        // Dart 侧未挂 handler 或引擎正在销毁:忽略。
                    }
                }
            }

            override fun onFloated(appId: String, appName: String, iconPng: ByteArray?) =
                forward("floated", appId, appName, iconPng)

            override fun onForegrounded(appId: String) = forward("foregrounded", appId)

            override fun onRuntimeDestroyed(appId: String) = forward("destroyed", appId)
        })
    }

    /**
     * 「dsh-notify」宿主扩展模块:订阅面板 + 订阅状态。面板结果的模板名来自
     * AppHub GET /api/v1/apps/<id>/notify/templates——只有 Dart 侧知道当下的
     * appHubBase(SSH 隧道端口会变),所以经同一个 dsh/dimina 通道问 Dart
     * (`notifyTemplates`),结果回 Dart 上报 consent(`notifyConsent`)。
     */
    private fun registerNotifyExtModule() {
        val module = NotifyExtModule(
            activityProvider = { activity },
            fetchTemplates = { appId, done -> requestTemplateNames(appId, done) },
            reportConsent = { appId, results ->
                main.post {
                    try {
                        channel.invokeMethod(
                            "notifyConsent",
                            mapOf("appId" to appId, "results" to results),
                        )
                    } catch (_: Throwable) {
                        // Dart 没挂 handler 或引擎正在销毁:consent 的本地状态还在,
                        // 下次拉 getSubscribeState 仍一致。
                    }
                }
            },
        )
        Dimina.getInstance().registerExtModule(NOTIFY_EXT_MODULE, module)
    }

    /**
     * 「dsh-permissions」宿主扩展模块(平台权限契约 v1 §6):容器侧 consent 的
     * 宿主读写口。容器旧版没有 MiniProgramPermissionStore 时整个模块优雅
     * no-op(反射能力探测见 [PermissionStoreGateway]);详情页开关不走这个
     * 模块实例,而是经 dsh/dimina 通道的 getPermissionState/setPermission
     * 直达同一网关(数据源同源)。
     */
    private fun registerPermissionsExtModule() {
        Dimina.getInstance().registerExtModule(PERMISSIONS_EXT_MODULE, PermissionsExtModule())
    }

    /** 模板名向 Dart 要(带 app 名);拿不到就给空表,面板显示「通知 N」兜底。 */
    private fun requestTemplateNames(appId: String, done: (String?, Map<String, String>) -> Unit) {
        main.post {
            try {
                channel.invokeMethod(
                    "notifyTemplates",
                    mapOf("appId" to appId),
                    object : MethodChannel.Result {
                        override fun success(result: Any?) {
                            val payload = result as? Map<*, *>
                            val appName = payload?.get("appName") as? String
                            val templates = payload?.get("templates") as? Map<*, *>
                            val names = LinkedHashMap<String, String>()
                            templates?.forEach { (key, value) ->
                                val id = key as? String ?: return@forEach
                                names[id] = value as? String ?: id
                            }
                            done(appName, names)
                        }

                        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) =
                            done(null, emptyMap())

                        override fun notImplemented() = done(null, emptyMap())
                    },
                )
            } catch (_: Throwable) {
                done(null, emptyMap())
            }
        }
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
                    // autoSync 静默同步(autoSync 扩展):升级跳过确认弹窗直接激活
                    autoUpdate = call.argument<Boolean>("autoUpdate") ?: false,
                )
                try {
                    // SDK manages its own activity stack; must be called on the main thread.
                    Dimina.getInstance().startMiniProgram(host, miniProgram)
                    result.success(true)
                } catch (error: Throwable) {
                    result.error("OPEN_FAILED", error.message, null)
                }
            }
            "sync" -> {
                // autoSync 静默同步(autoSync 扩展):不拉任何界面,后台装/升。
                // 需要 Activity 的只有 open;这里用 applicationContext 即可。
                val appId = call.argument<String>("appId")
                if (appId.isNullOrBlank()) {
                    result.error("BAD_ARGS", "appId is required", null)
                    return
                }
                // 容器未初始化时按默认浅色初始化(首次 open 仍会按宿主亮度校正,
                // updateCapsuleTheme 走运行时更新,见 ensureInitialized 注释)。
                ensureInitialized(call.argument<Boolean>("dark") ?: false)
                val miniProgram = MiniProgram(
                    appId = appId,
                    name = call.argument<String>("name") ?: appId,
                    path = null,
                    versionCode = call.argument<Number>("versionCode")?.toInt() ?: 0,
                    versionName = call.argument<String>("versionName") ?: "",
                    updateManifestUrl = call.argument<String>("updateManifestUrl") ?: "",
                )
                try {
                    Dimina.getInstance().syncMiniProgram(appContext, miniProgram) { outcome, versionCode, versionName ->
                        main.post {
                            result.success(
                                mapOf(
                                    "outcome" to outcome,
                                    "versionCode" to versionCode,
                                    "versionName" to versionName,
                                ),
                            )
                        }
                    }
                } catch (error: Throwable) {
                    result.error("SYNC_FAILED", error.message, null)
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
            // 平台权限契约 v1 §6/§7:容器 consent 的宿主读写口。数据源=容器
            // MiniProgramPermissionStore(反射网关),不是市场数据;store 不可用
            // (旧 dimina 依赖)时 supported=false、写回 false,Dart 侧降级只读。
            // store 的 appContext 挂在 Dimina.init(SDK ctor)上,详情页可能先于
            // 首次 open 到达——这里按 sync 分支同款先 ensureInitialized。
            "getPermissionState" -> {
                val appId = call.argument<String>("appId")
                if (appId.isNullOrBlank()) {
                    result.error("BAD_ARGS", "appId is required", null)
                    return
                }
                ensureInitialized(call.argument<Boolean>("dark") ?: false)
                result.success(
                    mapOf(
                        "supported" to PermissionStoreGateway.supported,
                        "scopes" to PermissionStoreGateway.stateMap(appId),
                    ),
                )
            }
            "setPermission" -> {
                val appId = call.argument<String>("appId")
                val scope = call.argument<String>("scope")
                val granted = call.argument<Boolean>("granted")
                if (appId.isNullOrBlank() || scope.isNullOrBlank() || granted == null) {
                    result.error("BAD_ARGS", "appId/scope/granted are required", null)
                    return
                }
                ensureInitialized(call.argument<Boolean>("dark") ?: false)
                result.success(PermissionStoreGateway.setPermission(appId, scope, granted))
            }
            // 通知入口相关分支(pushNotifyUnread/openNotificationCenter/fetchUnread)
            // 已随 2026-11-11 拍板「星河容器里不放通知按钮」拆除:入口收在宿主
            // 的会话列表与「小程序」桌面页头,容器只保留升级/订阅两类通道。
            else -> result.notImplemented()
        }
    }

    companion object {
        @Volatile
        private var initialized = false

        /** 与 Dimina 小程序侧 `module` 参数一致(契约 §5.3)。 */
        private const val NOTIFY_EXT_MODULE = "dsh-notify"

        /** 与 Dimina 小程序侧 `module` 参数一致(平台权限契约 v1 §6)。 */
        private const val PERMISSIONS_EXT_MODULE = "dsh-permissions"
    }
}
