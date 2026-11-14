package io.github.ccch1mneyyy.dsh_app.dimina

import android.util.Log
import java.lang.reflect.Method
import org.json.JSONObject

/**
 * 容器侧 MiniProgramPermissionStore 的反射网关(平台权限契约 v1 §3/§6)。
 *
 * 宿主 APK 编译期只依赖 JitPack 的 dimina(当前 1.8.1,尚无该类);store 由
 * dimina 新 SDK 提供,冻结方法面:`state(appId)` / `set(appId, scope, granted)`。
 * 这里全部走反射:类/方法找不到 → [supported]=false,读写一律 no-op,绝不崩
 * 宿主或容器;依赖升到含 store 的版本后无需改代码自动生效(候选类名清单见
 * dsh-permissions 交付报告,dimina 落库后若包名不同只需改 [CANDIDATE_CLASSES])。
 */
object PermissionStoreGateway {

    private const val TAG = "dsh-permissions"

    /** 候选 FQCN:首位为 dimina-guard 2026-11-14 定稿(api.permission 子包,Kotlin object 单例);其余为防再漂移的兜底。 */
    private val CANDIDATE_CLASSES = listOf(
        "com.didi.dimina.api.permission.MiniProgramPermissionStore",
        "com.didi.dimina.storage.MiniProgramPermissionStore",
        "com.didi.dimina.common.MiniProgramPermissionStore",
        "com.didi.dimina.utils.MiniProgramPermissionStore",
        "com.didi.dimina.api.MiniProgramPermissionStore",
        "com.didi.dimina.MiniProgramPermissionStore",
    )

    @Volatile
    private var resolved: Resolved? = null

    /** 容器侧 store 是否可用(类+冻结方法面都能反射到)。 */
    val supported: Boolean
        get() = resolve() != null

    /** 平面授权表 `{scope: granted}`;store 不可用/无记录/调用失败=空表。 */
    fun stateMap(appId: String): Map<String, Boolean> {
        val r = resolve() ?: return emptyMap()
        return try {
            flattenState(r.state.invoke(r.target, appId))
        } catch (t: Throwable) {
            Log.w(TAG, "state($appId) failed", t)
            emptyMap()
        }
    }

    /** 写容器 consent;store 不可用/调用失败=false(调用方回滚 UI)。 */
    fun setPermission(appId: String, scope: String, granted: Boolean): Boolean {
        val r = resolve() ?: return false
        return try {
            r.set.invoke(r.target, appId, scope, granted)
            true
        } catch (t: Throwable) {
            Log.w(TAG, "set($appId, $scope, $granted) failed", t)
            false
        }
    }

    /** 容器 consent → 平面 {scope: granted};值兼容 Boolean 与 {granted:bool}。 */
    private fun flattenState(raw: Any?): Map<String, Boolean> {
        val out = LinkedHashMap<String, Boolean>()
        when (raw) {
            is JSONObject -> raw.keys().forEach { scope -> out[scope] = grantedOf(raw.opt(scope)) }
            is Map<*, *> -> raw.forEach { (scope, value) -> out["$scope"] = grantedOf(value) }
        }
        return out
    }

    private fun grantedOf(value: Any?): Boolean = when (value) {
        is Boolean -> value
        is JSONObject -> value.optBoolean("granted", false)
        is Map<*, *> -> (value["granted"] as? Boolean) == true
        else -> false
    }

    private fun resolve(): Resolved? {
        resolved?.let { return it }
        synchronized(this) {
            resolved?.let { return it }
            for (name in CANDIDATE_CLASSES) {
                val klass = try {
                    Class.forName(name)
                } catch (_: Throwable) {
                    continue
                }
                val state = klass.methods.firstOrNull {
                    it.name == "state" &&
                        it.parameterCount == 1 &&
                        it.parameterTypes[0] == String::class.java
                } ?: continue
                val set = klass.methods.firstOrNull {
                    it.name == "set" &&
                        it.parameterCount == 3 &&
                        it.parameterTypes[0] == String::class.java &&
                        it.parameterTypes[1] == String::class.java
                } ?: continue
                val r = Resolved(klass, state, set)
                resolved = r
                Log.i(TAG, "MiniProgramPermissionStore resolved: $name")
                return r
            }
            Log.i(TAG, "MiniProgramPermissionStore not available (old container): ext module stays no-op")
            return null
        }
    }

    /** 已解析的冻结方法面;[target] 为单例实例,静态方法面时为 null。 */
    private class Resolved(val klass: Class<*>, val state: Method, val set: Method) {
        val target: Any? by lazy {
            runCatching {
                klass.getDeclaredField("INSTANCE").apply { isAccessible = true }.get(null)
            }.getOrNull()
                ?: runCatching {
                    klass.methods
                        .firstOrNull { it.name == "getInstance" && it.parameterCount == 0 }
                        ?.invoke(null)
                }.getOrNull()
        }
    }
}
