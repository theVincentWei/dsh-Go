package io.github.ccch1mneyyy.dsh_app.dimina

import com.didi.dimina.api.ext.ExtCallback
import com.didi.dimina.api.ext.ExtModuleHandler
import org.json.JSONObject

/**
 * 宿主权限扩展模块(平台权限契约 v1 §6,模块名 `dsh-permissions`),
 * 依 dsh-notify 样例注册(见 [DiminaPlugin]):
 *
 *  - `getPermissionState`:data `{appId}` → success `{scope: granted, ...}`
 *    平面授权表;store 不可用=空表(诚实口径:未授权任何 scope)。
 *  - `setPermission`:data `{appId, scope, granted}` → 写容器侧
 *    MiniProgramPermissionStore;成功回写后的平面授权表,store 不可用 →
 *    fail `errMsg`,绝不抛异常崩容器。
 *
 * 读写全部经 [PermissionStoreGateway] 反射网关:容器旧版没有 store 时
 * 整个模块优雅 no-op(能力探测见网关注释)。
 */
class PermissionsExtModule : ExtModuleHandler {

    override fun handle(event: String, data: JSONObject, callback: ExtCallback): Runnable? {
        when (event) {
            "getPermissionState" -> {
                val appId = data.optString("appId", "")
                if (appId.isEmpty()) {
                    callback.onFail(errMsg("getPermissionState:fail bad appId"))
                    return null
                }
                callback.onSuccess(stateJson(appId))
            }
            "setPermission" -> {
                val appId = data.optString("appId", "")
                val scope = data.optString("scope", "")
                if (appId.isEmpty() || scope.isEmpty()) {
                    callback.onFail(errMsg("setPermission:fail bad appId/scope"))
                    return null
                }
                val granted = data.optBoolean("granted", false)
                if (!PermissionStoreGateway.setPermission(appId, scope, granted)) {
                    callback.onFail(errMsg("setPermission:fail permission store unavailable"))
                    return null
                }
                callback.onSuccess(stateJson(appId))
            }
            else -> callback.onFail(errMsg("unknown event: $event"))
        }
        // 一次性调用:extBridge 不需要取消函数(同 NotifyExtModule)。
        return null
    }

    private fun stateJson(appId: String): JSONObject = JSONObject().apply {
        for ((scope, granted) in PermissionStoreGateway.stateMap(appId)) put(scope, granted)
    }

    private fun errMsg(msg: String): JSONObject = JSONObject().apply { put("errMsg", msg) }
}
