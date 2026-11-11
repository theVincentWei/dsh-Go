package io.github.ccch1mneyyy.dsh_app.dimina

import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.widget.CheckBox
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Switch
import android.widget.TextView
import com.didi.dimina.api.ext.ExtCallback
import com.didi.dimina.api.ext.ExtModuleHandler
import io.github.ccch1mneyyy.dsh_app.R
import io.github.ccch1mneyyy.dsh_app.i18n.AppStrings
import org.json.JSONArray
import org.json.JSONObject

/**
 * 宿主订阅面板（契约 §5.3，模块名 `dsh-notify`）：
 *
 *  - `showSubscribePanel`：data `{appId, tmplIds:[...]}` → 原生确认面板 → success
 *    `{results:{tplId:'accept'|'reject'}}`；面板结果同时经 `dsh/dimina` 的
 *    `notifyConsent` 回 Dart，由 Dart 逐条上报 AppHub `POST /api/v1/notices/consent`
 *    （单模板形状 `{appId, templateId, action}`，见 apphub/lib/notices.dart）。
 *  - `getSubscribeState`：→ success `{mainSwitch:bool, itemSettings:{tplId:'accept'|'reject'}}`。
 *
 * 模板名从 AppHub `GET /api/v1/apps/<id>/notify/templates` 拉（经 Dart 通道，
 * 因为只有 Dart 知道当前 appHubBase/隧道端口）；拉不到就显示「通知 N」，
 * 绝不把 `tpl_xxx` 内部 id 摆给用户看。v1 用原生 Dialog，v2 换 Flutter 玻璃 sheet。
 *
 * **权限总闸**：2026-11-11 拍板整套权限系统尚无设计，先全关、接口保留。
 * [AUTO_ACCEPT_WITHOUT_PANEL] 为 true 时本面板短路成全 accept（不弹框、不记账），
 * 小程序无需改动；与服务端 `kCurrentNotifyPolicy` 同拍板，统一设计时一起恢复。
 */
class NotifyExtModule(
    private val activityProvider: () -> Activity?,
    /** appId → (appName, templateId→name)；失败时给空表，面板落「通知 N」。 */
    private val fetchTemplates: (appId: String, done: (String?, Map<String, String>) -> Unit) -> Unit,
    /** 面板结果回 Dart（Dart 逐条上报 AppHub）。 */
    private val reportConsent: (appId: String, results: Map<String, String>) -> Unit,
) : ExtModuleHandler {

    private val main = Handler(Looper.getMainLooper())

    override fun handle(event: String, data: JSONObject, callback: ExtCallback): Runnable? {
        when (event) {
            "showSubscribePanel" -> showSubscribePanel(data, callback)
            "getSubscribeState" -> callback.onSuccess(subscribeState())
            else -> callback.onFail(JSONObject().apply { put("errMsg", "unknown event: $event") })
        }
        // 一次性调用：extBridge 不需要取消函数。
        return null
    }

    // ---------------------------------------------------------------------
    // showSubscribePanel
    // ---------------------------------------------------------------------

    private fun showSubscribePanel(data: JSONObject, callback: ExtCallback) {
        val appId = data.optString("appId", "")
        val rawIds = data.optJSONArray("tmplIds") ?: JSONArray()
        val tmplIds = ArrayList<String>(rawIds.length())
        for (i in 0 until rawIds.length()) {
            val id = rawIds.optString(i, "")
            if (id.isNotEmpty() && !tmplIds.contains(id)) tmplIds.add(id)
        }
        if (appId.isEmpty() || tmplIds.isEmpty()) {
            callback.onFail(JSONObject().apply { put("errMsg", "showSubscribePanel:fail bad appId/tmplIds") })
            return
        }
        // 权限总闸关着（2026-11-11 临时）：不弹面板、不写 prefs、不上报 consent，
        // 所有模板直接回 accept。小程序代码一行不动（照旧调 requestSubscribeMessage
        // 并拿到 accept）；统一权限系统落地时把常量改回 false，面板自然恢复。
        if (AUTO_ACCEPT_WITHOUT_PANEL) {
            val results = LinkedHashMap<String, String>()
            for (id in tmplIds) results[id] = "accept"
            callback.onSuccess(JSONObject().apply { put("results", ConsentResults(results).toJson()) })
            return
        }
        fetchTemplates(appId) { appName, names ->
            main.post { presentPanel(appId, tmplIds, appName, names, callback) }
        }
    }

    private fun presentPanel(
        appId: String,
        tmplIds: List<String>,
        appName: String?,
        names: Map<String, String>,
        callback: ExtCallback,
    ) {
        val activity = activityProvider() ?: run {
            callback.onFail(JSONObject().apply { put("errMsg", "showSubscribePanel:fail no activity") })
            return
        }
        val ctx: Context = AppStrings.context(activity)
        val switch = Switch(ctx).apply {
            // 主开关默认开；关掉时全部 reject（相当于 mainSwitch 关闭）。
            isChecked = mainSwitch()
            text = AppStrings.get(ctx, R.string.dsh_notify_main_switch)
            setPadding(0, dp(ctx, 8), 0, dp(ctx, 8))
        }
        val boxes = LinkedHashMap<String, CheckBox>()
        val rows = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(ctx, 20), dp(ctx, 4), dp(ctx, 20), dp(ctx, 4))
            addView(switch)
        }
        tmplIds.forEachIndexed { index, id ->
            val label = names[id]?.takeIf { it.isNotBlank() }
                ?: AppStrings.get(ctx, R.string.dsh_notify_template_fallback, index + 1)
            val box = CheckBox(ctx).apply {
                text = label
                // 微信同款：默认不勾选，勾了才是 accept。
                isChecked = false
                isEnabled = switch.isChecked
            }
            boxes[id] = box
            rows.addView(box)
        }
        switch.setOnCheckedChangeListener { _, checked -> boxes.values.forEach { it.isEnabled = checked } }
        val body = TextView(ctx).apply {
            text = AppStrings.get(
                ctx,
                R.string.dsh_notify_panel_body,
                appName?.takeIf { it.isNotBlank() } ?: appId,
            )
            setPadding(dp(ctx, 20), dp(ctx, 4), dp(ctx, 20), dp(ctx, 4))
        }
        val content = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            addView(body)
            addView(ScrollView(ctx).apply { addView(rows) })
        }
        var settled = false
        val dialog = AlertDialog.Builder(activity)
            .setTitle(AppStrings.get(ctx, R.string.dsh_notify_panel_title))
            .setView(content)
            .setCancelable(false)
            .setPositiveButton(AppStrings.get(ctx, R.string.dsh_notify_allow)) { _, _ ->
                settled = true
                // 主开关关着 = 全部 reject；勾选 = accept，未勾选 = reject。
                val enabled = switch.isChecked
                val results = computeResults(appId, tmplIds, mainSwitch = enabled) { id ->
                    enabled && boxes[id]?.isChecked == true
                }
                callback.onSuccess(JSONObject().apply { put("results", results.toJson()) })
                reportConsent(appId, results.toMap())
            }
            .setNegativeButton(AppStrings.get(ctx, R.string.dsh_notify_reject)) { _, _ ->
                settled = true
                val results = computeResults(appId, tmplIds, mainSwitch = mainSwitch()) { _ -> false }
                callback.onSuccess(JSONObject().apply { put("results", results) })
                reportConsent(appId, results.toMap())
            }
            .setOnDismissListener {
                // 系统返回键/外部点击在 setCancelable(false) 下不会发生，防御一次：
                // 没走按钮就按拒绝处理，绝不悬着 JS 回调。
                if (!settled) {
                    settled = true
                    val results = computeResults(appId, tmplIds, mainSwitch = mainSwitch()) { _ -> false }
                    callback.onSuccess(JSONObject().apply { put("results", results) })
                    reportConsent(appId, results.toMap())
                }
            }
            .create()
        dialog.show()
    }

    // ---------------------------------------------------------------------
    // 状态与持久化
    // ---------------------------------------------------------------------

    private fun prefs() = activityProvider()?.applicationContext
        ?.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun mainSwitch(): Boolean = prefs()?.getBoolean(KEY_MAIN_SWITCH, true) ?: true

    private fun itemSettings(): JSONObject = try {
        JSONObject(prefs()?.getString(KEY_ITEM_SETTINGS, null) ?: "{}")
    } catch (_: Throwable) {
        JSONObject()
    }

    private fun subscribeState(): JSONObject = JSONObject().apply {
        // 权限总闸关着时对外口径统一为「总开关开、无历史表态」：不让旧的
        // reject/mainSwitch=false 残留把存量小程序误导成「不能订阅」。
        if (AUTO_ACCEPT_WITHOUT_PANEL) {
            put("mainSwitch", true)
            put("itemSettings", JSONObject())
            return@apply
        }
        put("mainSwitch", mainSwitch())
        put("itemSettings", itemSettings())
    }

    private fun computeResults(
        appId: String,
        tmplIds: List<String>,
        mainSwitch: Boolean,
        accept: (String) -> Boolean,
    ): ConsentResults {
        val results = LinkedHashMap<String, String>()
        for (id in tmplIds) results[id] = if (accept(id)) "accept" else "reject"
        // 主开关状态与逐模板选择都留下，getSubscribeState 回读用。
        val stored = itemSettings()
        for ((id, action) in results) stored.put(id, action)
        prefs()?.edit()
            ?.putBoolean(KEY_MAIN_SWITCH, mainSwitch)
            ?.putString(KEY_ITEM_SETTINGS, stored.toString())
            ?.apply()
        return ConsentResults(results)
    }

    /** 一次性结果：JSON 给 JS，Map 给 Dart 上报。 */
    private class ConsentResults(private val map: Map<String, String>) {
        fun toMap(): Map<String, String> = map
        fun toJson(): JSONObject = JSONObject().apply { for ((id, action) in map) put(id, action) }
    }

    private fun dp(ctx: Context, value: Int): Int =
        (value * ctx.resources.displayMetrics.density).toInt()

    companion object {
        /**
         * **权限总闸（2026-11-11 拍板：整套权限系统尚无设计，先全关、接口保留）**。
         *
         * true = 订阅面板短路：不弹框、不写 prefs、不上报 consent，所有模板直接回
         * `accept`。小程序照旧调 `wx.requestSubscribeMessage` 并成功返回，代码无需
         * 改动；统一权限系统落地时**与 server 总闸一起**改回 false（服务端对应
         * `notify_logic.dart` 的 `kCurrentNotifyPolicy`）。
         */
        const val AUTO_ACCEPT_WITHOUT_PANEL = true
        private const val PREFS = "dsh_notify"
        private const val KEY_MAIN_SWITCH = "main_switch"
        private const val KEY_ITEM_SETTINGS = "item_settings"
    }
}
