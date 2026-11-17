import Flutter
import UIKit
import Dimina

/// Flutter bridge to the Dimina (星河) mini-program container: MethodChannel
/// `dsh/dimina` (Dart side: lib/ui/applet/dimina/dimina_host.dart). iOS port of
/// android/.../dimina/DiminaPlugin.kt — the Android SDK contract mapped onto the
/// DiminaKit Swift API (DMPAppManager / DMPApp / DMPNavigator).
///
/// Channel surface (parity with the Android plugin):
/// - open / close / uninstall / installed: on DiminaKit. open now reports
///   OPEN_FAILED when the container did not end up with a page stack (Android
///   startMiniProgram 同语义) instead of a blind `true`.
/// - float: real float via the public `DMPApp.hideMiniProgram()` primitive
///   (整栈收起 + 运行时保留,保活由 DMPRetentionPolicy 30 分钟兜底),followed
///   by a `floated` event carrying the icon captured at open time.
/// - install: autoSync 静默安装的落地点。kit 没有 syncMiniProgram 静默原语
///   (DMPRemoteUpdateManager module-internal),所以「清单拉取/下载/包处理」在
///   Dart 侧完成(archive/crypto 解包注入 config.json 后重打包,对齐 kit
///   preparePackage 语义),这里只吃本地 zip 走公开
///   installMiniProgram(appId:packagePath:)(自动关掉在跑的旧版再换包)。
///   outcome(installed/updated)由 Dart 按 baseline 判;里程碑经 onUpdateEvent
///   广播,市场页照常刷新。
/// - getPermissionState / setPermission: host-side UserDefaults store (per-appId
///   scope→bool table), same JSON shape as Android PermissionStoreGateway's
///   stateMap; supported=true.
/// - dsh-notify / dsh-permissions ext modules: registered on DMPAppManager via
///   registerExtModule (contract §5.2/§5.3 + 平台权限契约 v1 §6).
/// - onUpdateEvent: no host-side update callback exists in DiminaKit (kit's
///   notifyUpdateStatus only reaches the container JS layer), so open() with an
///   updateManifestUrl starts a bounded versionCode poll as a fallback
///   (installed/applied); ready/declined/failed are unobservable and never
///   fabricated. 完整里程碑需要 kit 暴露宿主钩子(Android listener 同形状)。
/// - onDiminaEvent: floated / foregrounded / destroyed. Host-driven paths (no
///   kit hook): floated on float, foregrounded when open() hits a retained
///   background app, destroyed on close/uninstall of a tracked app. The
///   container's own ⋯-menu float tile is a second floated source: kit posts
///   `dimina.miniProgramFloated` after a successful hide and the host realigns
///   the foreground/floated slots before forwarding the event.
/// - onAskAi: the container's Ask-AI floating ball posts
///   `dimina.miniProgramAskAiInvoked` on tap; the host forwards it verbatim to
///   Dart as {appId, appName, pageTitle?, pagePath?} — the ask_ai_entry.dart
///   chain subscribes onDiminaHost.askAiEvents and takes it from there.
///
/// Mini programs render inside a host-presented UINavigationController
/// ([navController]); the container pushes its pages onto it (DMPNavigator).
/// The whole plugin is @MainActor: DiminaKit requires main-thread calls and
/// Flutter platform handlers already arrive there. Ext-module handlers are
/// produced by nonisolated static factories because the container invokes them
/// on its dedicated JS engine thread.
@MainActor
final class DiminaPlugin: NSObject {
  private static var instance: DiminaPlugin?
  private let channel: FlutterMethodChannel
  private var initialized = false
  private var lastDark: Bool?
  private var navController: UINavigationController?
  /// 容器自治入口的系统通知观察者 token:NotificationCenter 对 block 观察者
  /// 按 token 存活期回收,必须挂在实例上;插件是进程级单例(见 register(with:)),
  /// 观察者与它同生命周期,不做反注册。
  private var containerObservers: [NSObjectProtocol] = []

  // 前台/浮窗归属记账(单球语义、单导航栈:Dart 驱动的真实流是 float/close
  // 之后才 open 下一个)。floated 槽保留最近一次收后台的应用,供 resume 判定
  // 与回收后的 destroyed 补发。图标按 appId 记账:宿主 float() 与容器菜单
  // 瓦片自行收栈(dimina.miniProgramFloated)两条路都取得到;离开前台不清
  // (浮窗态还要用),应用销毁时随手清。
  private var foregroundApp: DMPApp?
  private var foregroundAppName: String?
  private var iconPngs: [String: Data] = [:]
  private var floatedApp: DMPApp?

  /// 升级里程碑兜底轮询(见 startUpdatePolling)。
  private var updatePollers: [String: Task<Void, Never>] = [:]

  /// 与 Dimina 小程序侧 `module` 参数一致(契约 §5.3 / 平台权限契约 v1 §6)。
  private static let notifyExtModule = "dsh-notify"
  private static let permissionsExtModule = "dsh-permissions"

  /// 容器自治入口(⋯菜单「浮窗」瓦片/问AI悬浮球)成功后 POST 的系统通知;
  /// 名字与 userInfo key 与容器侧 kit 一字不差,容器不经宿主通道自己发。
  private static let miniProgramFloatedNotification =
    Notification.Name("dimina.miniProgramFloated")
  private static let miniProgramAskAiInvokedNotification =
    Notification.Name("dimina.miniProgramAskAiInvoked")

  /// **订阅总闸(照 Android NotifyExtModule.AUTO_ACCEPT_WITHOUT_PANEL,2026-11-11
  /// 拍板:整套权限系统尚无设计,先全关、接口保留)**。true = 面板短路:不弹框、
  /// 不写 prefs、不上报 consent,所有模板直接回 accept;与服务端
  /// `notify_logic.dart` 的 kCurrentNotifyPolicy 同拍板,统一设计时一起改回。
  private static let autoAcceptWithoutPanel = false

  nonisolated static func register(with registrar: FlutterPluginRegistrar) {
    MainActor.assumeIsolated {
      let channel = FlutterMethodChannel(name: "dsh/dimina", binaryMessenger: registrar.messenger())
      let plugin = DiminaPlugin(channel: channel)
      instance = plugin
      channel.setMethodCallHandler { call, result in
        // Platform-channel handlers already run on the main thread.
        MainActor.assumeIsolated {
          plugin.handle(call: call, result: result)
        }
      }
    }
  }

  private init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
    observeContainerEvents()
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "open": open(call: call, result: result)
    case "close": close(call: call, result: result)
    case "float": float(result: result)
    case "uninstall": uninstall(call: call, result: result)
    case "installed": installed(call: call, result: result)
    case "getPermissionState": getPermissionState(call: call, result: result)
    case "setPermission": setPermission(call: call, result: result)
    case "install":
      // autoSync 静默安装落地点:Dart 已备好本地 zip(见文件头 install 注释),
      // 这里公开原语安装即可。
      install(call: call, result: result)
    default: result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - open

  private func open(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any] else {
      result(FlutterError(code: "BAD_ARGS", message: "args required", details: nil))
      return
    }
    guard let appId = args["appId"] as? String, !appId.isEmpty else {
      result(FlutterError(code: "BAD_ARGS", message: "appId is required", details: nil))
      return
    }
    let dark = args["dark"] as? Bool ?? false
    ensureInitialized(dark: dark)

    var config = DMPAppConfig(appName: (args["name"] as? String) ?? appId, appId: appId)
    config.path = args["path"] as? String
    config.versionCode = (args["versionCode"] as? NSNumber)?.intValue
    config.versionName = args["versionName"] as? String
    config.updateManifestUrl = args["updateManifestUrl"] as? String
    // release 包不开 vConsole(与 Android 读 FLAG_DEBUGGABLE 同语义);排查
    // 容器内 JS 问题时临时置 true,屏幕上会出现 vConsole 悬浮按钮。
    config.isDebugMode = false
    let appName = (args["name"] as? String) ?? appId
    // 宿主侧图标(bundle 图标/栅格 PNG):float 收后台时随 floated 事件回 Dart
    // 画浮窗球(Android onFloated 的 iconPng 同源),按 appId 记账(容器菜单
    // 瓦片自行收栈的通知路径也取得到)。同时落沙盒稳定路径交给 config.icon,
    // 容器菜单头部按文件路径加载真图标。
    let iconPng = (args["iconPng"] as? FlutterStandardTypedData)?.data
    if let iconPng {
      // 写盘在 appWithConfig 前;失败返回 nil = config.icon 不动(容器按无
      // 图标兜底),浮窗事件的内存记账不受影响。
      config.icon = storeIconFile(appId: appId, png: iconPng)
    }

    let manager = DMPAppManager.sharedInstance()
    let app = manager.appWithConfig(appConfig: config)

    // 命中后台保留应用:浮窗收栈后 pageRecords 保留,webViewId 仍 >0;排除
    // 「本来就是前台、重复 open」后,本次 open 是 resume,完成后发 foregrounded
    // 让 Dart 收浮窗球(float_ball 的 restore 链路依赖这条事件)。
    let navPresented = navController?.presentingViewController != nil
    let resuming = app.getCurrentWebViewId() > 0
      && !(appId == foregroundApp?.getAppId() && navPresented)
    if !resuming, floatedApp?.getAppId() == appId {
      // 浮窗应用已被运行时回收/销毁(kit 无回收钩子,宿主只能在下次 open 时
      // 事后察觉):补一条 destroyed 让 Dart 收球,再走全新启动。
      clearFloatedState(appId: appId)
      iconPngs[appId] = nil
      sendDiminaEvent(type: "destroyed", appId: appId, appName: nil, iconPng: nil)
    }

    // 宿主导航栈:容器把小程序页 push 到这条栈上。挂一次,跨启动复用;浮窗
    // dismiss 后保引用,resumeRetainedMiniProgram 还要靠它 re-present。
    let nav: UINavigationController
    if let existing = navController {
      nav = existing
    } else {
      let fresh = UINavigationController()
      fresh.setNavigationBarHidden(true, animated: false)
      // 全屏语义(对齐 Android 独立任务):默认 pageSheet 卡片式会露出宿主
      // 边缘;fullScreen 同时禁掉下滑关闭,小程序只能经容器胶囊退出。
      fresh.modalPresentationStyle = .fullScreen
      nav = fresh
      navController = fresh
    }
    app.getNavigator()?.setup(navigationController: nav)
    if nav.presentingViewController == nil {
      if !resuming {
        // 胶囊 ✕ / 容器内退出走 kit 内部销毁,宿主收不到通知,未呈现的栈里
        // 可能残留已销毁的页面壳:全新启动前清空,避免新页转场露出残页。
        // resume 路径不清——栈上是活的保留页,呈现即所见。
        nav.setViewControllers([], animated: false)
      }
      // 无底包首装期间先露出容器启动画面;resume 路径闪一帧空栈可忽略
      // (本地秒切,下载不在这条路径上)。
      presentOverFlutter(nav)
    }

    // Android startMiniProgram 同步启动 + result(true);iOS 的 launch 返回
    // Void(结果被吞),以「页栈已 push」判成败:失败回 OPEN_FAILED(Android
    // 同码),不再盲 true。
    Task { @MainActor in
      var launchConfig = DMPLaunchConfig()
      if let path = config.path { launchConfig.appEntryPath = path }
      await app.launch(launchConfig: launchConfig)
      guard app.getCurrentWebViewId() > 0 else {
        result(FlutterError(code: "OPEN_FAILED", message: "mini program \(appId) failed to launch", details: nil))
        return
      }
      foregroundApp = app
      foregroundAppName = appName
      iconPngs[appId] = iconPng
      if resuming {
        clearFloatedState(appId: appId)
        sendDiminaEvent(type: "foregrounded", appId: appId, appName: nil, iconPng: nil)
      }
      if let manifestUrl = config.updateManifestUrl, !manifestUrl.isEmpty {
        startUpdatePolling(appId: appId)
      }
      result(true)
    }
  }

  // MARK: - close / float

  private func close(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let appId = args["appId"] as? String, !appId.isEmpty
    else {
      result(FlutterError(code: "BAD_ARGS", message: "appId is required", details: nil))
      return
    }
    let manager = DMPAppManager.sharedInstance()
    // 本会话打开过的应用走 DMPApp.closeMiniProgram(exitMiniProgram 语义):
    // 前台=关栈+销毁运行时,浮窗保留态=直接销毁——两条路都对应 Android 的
    // destroyed;manager 版本只关页不销毁,且对浮窗应用(栈 owner 已 detach)
    // 会静默跳过。没跟踪过的 appId 走 manager 版本兜底。
    let tracked: DMPApp?
    if foregroundApp?.getAppId() == appId {
      tracked = foregroundApp
    } else if floatedApp?.getAppId() == appId {
      tracked = floatedApp
    } else {
      tracked = nil
    }
    Task { @MainActor in
      var ok: Bool
      if let tracked {
        do {
          try await tracked.closeMiniProgram()
          ok = true
        } catch {
          // 容器操作互斥(operationInProgress)等:退回 manager 公共关闭口。
          ok = await manager.closeMiniProgram(appId: appId)
        }
      } else {
        ok = await manager.closeMiniProgram(appId: appId)
      }
      if ok {
        teardownHostNavIfIdle()
        if foregroundApp?.getAppId() == appId { clearForegroundState() }
        clearFloatedState(appId: appId)
        iconPngs[appId] = nil
        sendDiminaEvent(type: "destroyed", appId: appId, appName: nil, iconPng: nil)
      }
      result(ok)
    }
  }

  /// 问AI/宿主驱动的「浮窗」:把当前前台小程序收后台保留运行时(Android
  /// floatCurrentMiniProgram → hideMiniProgram 同一原语)。kit 的 hide 会自己
  /// dismiss 宿主导航栈(宿主段为空时)并 detach 栈 owner,保留策略 30 分钟
  /// 兜底;无前台小程序/容器互斥/没有可保留页面时回 false,Dart 侧忽略。
  private func float(result: @escaping FlutterResult) {
    guard let app = foregroundApp else {
      result(false)
      return
    }
    let appId = app.getAppId()
    let nav = navController
    Task { @MainActor in
      do {
        try await app.hideMiniProgram()
      } catch {
        result(false)
        return
      }
      // kit 在没有可保留页面的宿主拓扑下不动 UI:栈仍 presented = 没收成,
      // 照 Android 返回 false。
      if let nav, nav.presentingViewController != nil {
        result(false)
        return
      }
      let name = foregroundAppName ?? appId
      let icon = iconPngs[appId]
      floatedApp = app
      clearForegroundState()
      sendDiminaEvent(type: "floated", appId: appId, appName: name, iconPng: icon)
      result(true)
    }
  }

  // MARK: - uninstall / installed

  private func uninstall(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let appId = args["appId"] as? String, !appId.isEmpty
    else {
      result(FlutterError(code: "BAD_ARGS", message: "appId is required", details: nil))
      return
    }
    let clearUserData = args["clearUserData"] as? Bool ?? false
    Task { @MainActor in
      do {
        try await DMPAppManager.sharedInstance().uninstallMiniProgram(appId: appId, clearUserData: clearUserData)
        // 卸载命中本会话跟踪的应用时补 destroyed(Android 容器销毁实例时同样
        // 会发 onRuntimeDestroyed,Dart 侧借此收浮窗球)并清导航栈残留。
        if foregroundApp?.getAppId() == appId || floatedApp?.getAppId() == appId {
          teardownHostNavIfIdle()
          clearForegroundState()
          clearFloatedState(appId: appId)
          iconPngs[appId] = nil
          sendDiminaEvent(type: "destroyed", appId: appId, appName: nil, iconPng: nil)
        }
        result(true)
      } catch {
        result(FlutterError(code: "UNINSTALL_FAILED", message: error.localizedDescription, details: nil))
      }
    }
  }

  private func installed(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let appId = args["appId"] as? String, !appId.isEmpty
    else {
      result(FlutterError(code: "BAD_ARGS", message: "appId is required", details: nil))
      return
    }
    do {
      // Dimina 沙盒 config.json(<sandbox>/jsapp/<appId>/config.json 的 iOS
      // 对应物);nil = 未装,有值 = 已装(带 versionCode/versionName)。
      if let info = try DMPAppManager.sharedInstance().getAppVersionInfo(appId: appId) {
        result([
          "installed": true,
          "versionCode": (info["versionCode"] as? NSNumber) ?? 0,
          "versionName": (info["versionName"] as? String) ?? "",
        ])
      } else {
        result(["installed": false])
      }
    } catch {
      result(FlutterError(code: "QUERY_FAILED", message: error.localizedDescription, details: nil))
    }
  }

  // MARK: - install(autoSync 静默安装落地点)

  /// Dart 侧已把清单/下载/包处理做完(config.json 注入见 dimina_host 的
  /// _syncViaPreparedPackage),这里只负责公开原语安装+里程碑广播。
  private func install(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let appId = args["appId"] as? String, !appId.isEmpty,
      let packagePath = args["packagePath"] as? String, !packagePath.isEmpty
    else {
      result(FlutterError(
        code: "BAD_ARGS", message: "appId/packagePath are required", details: nil))
      return
    }
    let manager = DMPAppManager.sharedInstance()
    let baseline = (try? manager.getAppVersionInfo(appId: appId)) ?? nil
    let baselineCode = (baseline?["versionCode"] as? NSNumber)?.intValue ?? -1
    Task { @MainActor in
      do {
        let config = try await manager.installMiniProgram(appId: appId, packagePath: packagePath)
        let code = (config["versionCode"] as? NSNumber)?.intValue ?? 0
        let vname = (config["versionName"] as? String) ?? ""
        let outcome = baselineCode >= 0 ? "updated" : "installed"
        sendUpdateEvent(
          event: outcome == "installed" ? "installed" : "applied",
          appId: appId, versionCode: code, versionName: vname, message: nil)
        result(["outcome": outcome, "versionCode": code, "versionName": vname])
      } catch {
        result(FlutterError(
          code: "INSTALL_FAILED", message: error.localizedDescription, details: nil))
      }
    }
  }

  // MARK: - 宿主权限读写(平台权限契约 v1 §6/§7)

  private func getPermissionState(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let appId = args["appId"] as? String, !appId.isEmpty
    else {
      result(FlutterError(code: "BAD_ARGS", message: "appId is required", details: nil))
      return
    }
    // 数据源 = 宿主 UserDefaults 授权表(iOS 容器没有 Android 反射网关背后的
    // MiniProgramPermissionStore,今晚不做容器权限闸),supported 恒 true。
    result([
      "supported": true,
      "scopes": DiminaPermissionStore.state(appId: appId) as [String: Any],
    ])
  }

  private func setPermission(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let appId = args["appId"] as? String, !appId.isEmpty,
      let scope = args["scope"] as? String, !scope.isEmpty,
      let granted = args["granted"] as? Bool
    else {
      result(FlutterError(code: "BAD_ARGS", message: "appId/scope/granted are required", details: nil))
      return
    }
    result(DiminaPermissionStore.set(appId: appId, scope: scope, granted: granted))
  }

  // MARK: - 升级里程碑转发(Android MiniProgramUpdateListener 的 iOS 兜底)

  /// DiminaKit iOS 没有宿主侧升级回调(Android 的 MiniProgramUpdateListener 无
  /// 对应物;kit 的 notifyUpdateStatus 只发容器 JS 层),只能盯沙盒 config.json
  /// 的 versionCode 变化:
  ///   - 基线未装 → 出现包 = installed(首装完成);
  ///   - 基线已装 → versionCode 变大 = applied(容器确认升级并激活新包)。
  /// ready/declined/failed 发生在容器 JS 层,宿主不可观测,不伪造。
  /// **这是兜底:完整里程碑需要 kit 暴露宿主钩子(Android listener 同形状)。**
  private func startUpdatePolling(appId: String) {
    updatePollers[appId]?.cancel()
    let manager = DMPAppManager.sharedInstance()
    let baselineInfo = (try? manager.getAppVersionInfo(appId: appId)) ?? nil
    let baselineInstalled = baselineInfo != nil
    let baselineCode = (baselineInfo?["versionCode"] as? NSNumber)?.intValue ?? 0
    updatePollers[appId] = Task { @MainActor in
      // 2s × 45 ≈ 90s:覆盖局域网下载 + 容器内确认/激活的常规时窗。
      for _ in 0..<45 {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if Task.isCancelled { return }
        guard let info = (try? manager.getAppVersionInfo(appId: appId)) ?? nil else { continue }
        let code = (info["versionCode"] as? NSNumber)?.intValue ?? 0
        let milestone: String
        if !baselineInstalled {
          milestone = "installed"
        } else if code > baselineCode {
          milestone = "applied"
        } else {
          continue
        }
        sendUpdateEvent(
          event: milestone, appId: appId, versionCode: code,
          versionName: (info["versionName"] as? String) ?? "", message: nil)
        break
      }
      updatePollers[appId] = nil
    }
  }

  /// 事件形状照 Android forwardUpdateEvent:{event, appId, versionCode,
  /// versionName, message}。Dart 没挂 handler/引擎销毁时静默(丢这一次)。
  private func sendUpdateEvent(
    event: String, appId: String, versionCode: Int, versionName: String, message: String?
  ) {
    var payload: [String: Any] = [
      "event": event,
      "appId": appId,
      "versionCode": versionCode,
      "versionName": versionName,
    ]
    if let message { payload["message"] = message }
    channel.invokeMethod("onUpdateEvent", arguments: payload)
  }

  /// 浮窗单球事件:{type, appId, appName, iconPng}(形状照 Android
  /// MiniProgramLifecycleListener 的 forward)。invokeMethod 失败静默——球状态
  /// 由下一次事件校正。
  private func sendDiminaEvent(type: String, appId: String, appName: String?, iconPng: Data?) {
    var payload: [String: Any] = [
      "type": type,
      "appId": appId,
      "appName": appName ?? appId,
    ]
    if let iconPng { payload["iconPng"] = iconPng }
    channel.invokeMethod("onDiminaEvent", arguments: payload)
  }

  private func clearForegroundState() {
    foregroundApp = nil
    foregroundAppName = nil
    // 图标不在这里清:per-appId 记账要跨前台→浮窗存活,销毁路径单独清。
  }

  private func clearFloatedState(appId: String) {
    guard floatedApp?.getAppId() == appId else { return }
    floatedApp = nil
  }

  // MARK: - 容器自治入口事件(⋯菜单瓦片/问AI悬浮球 → NotificationCenter 转发)

  /// 容器 ⋯ 菜单「浮窗」瓦片收栈成功(kit 自 hide,不经宿主 float 通道):
  /// 对齐宿主浮窗记账(语义照 float() 成功分支——前台归属让位给浮窗槽)后
  /// 回 floated 事件让 Dart 挂球。宿主前台槽不指向该应用时不脏写槽位(单栈
  /// 语义下只可能是记账漂移,下次 open/close 会校正),事件照发。
  private func handleContainerFloated(appId: String, appName: String?) {
    guard !appId.isEmpty else { return }
    if let foreground = foregroundApp, foreground.getAppId() == appId {
      floatedApp = foreground
      clearForegroundState()
    }
    sendDiminaEvent(type: "floated", appId: appId, appName: appName, iconPng: iconPngs[appId])
  }

  /// 容器问AI悬浮球点击 → onAskAi 原样透传(app_ai 进场链路在 Dart
  /// ask_ai_entry.dart)。appName 用前台记账的名字,拿不到落 appId;
  /// pageTitle/pagePath 可缺省,缺省键不上报(Dart 侧按 null 容错)。
  private func forwardAskAi(appId: String, pageTitle: String?, pagePath: String?) {
    guard !appId.isEmpty else { return }
    var payload: [String: Any] = [
      "appId": appId,
      "appName": foregroundAppName ?? appId,
    ]
    if let pageTitle { payload["pageTitle"] = pageTitle }
    if let pagePath { payload["pagePath"] = pagePath }
    channel.invokeMethod("onAskAi", arguments: payload)
  }

  /// 观察者与插件单例同生命周期(不做反注册);kit 可能在任意线程 POST,
  /// 统一跳主线程再碰 UI/channel(与 ext-module 回调同一跳法)。
  private func observeContainerEvents() {
    let center = NotificationCenter.default
    containerObservers.append(center.addObserver(
      forName: Self.miniProgramFloatedNotification, object: nil, queue: nil
    ) { [weak self] notification in
      guard let self else { return }
      let userInfo = notification.userInfo ?? [:]
      let appId = userInfo["appId"] as? String ?? ""
      let appName = userInfo["appName"] as? String
      Task { @MainActor in
        self.handleContainerFloated(appId: appId, appName: appName)
      }
    })
    containerObservers.append(center.addObserver(
      forName: Self.miniProgramAskAiInvokedNotification, object: nil, queue: nil
    ) { [weak self] notification in
      guard let self else { return }
      let userInfo = notification.userInfo ?? [:]
      let appId = userInfo["appId"] as? String ?? ""
      let pageTitle = userInfo["pageTitle"] as? String
      let pagePath = userInfo["pagePath"] as? String
      Task { @MainActor in
        self.forwardAskAi(appId: appId, pageTitle: pageTitle, pagePath: pagePath)
      }
    })
  }

  /// open 带来的图标 png 落 app 沙盒稳定路径,返回给 DMPAppConfig.icon 的
  /// 绝对路径(kit 按文件路径加载 png);目录不存在则创建,写盘失败返回 nil,
  /// 调用方不设 config.icon。
  private func storeIconFile(appId: String, png: Data) -> String? {
    guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
      return nil
    }
    let url = documents
      .appendingPathComponent("Dimina", isDirectory: true)
      .appendingPathComponent(".icons", isDirectory: true)
      .appendingPathComponent("\(appId).png")
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try png.write(to: url, options: .atomic)
      return url.path
    } catch {
      return nil
    }
  }

  /// 关闭/卸载成功后清理宿主导航栈:仍呈现 → 收模态并弃用(回到 Flutter 界面);
  /// 未呈现(浮窗/后台路径)→ 清掉可能残留的已销毁页面壳,下次 open 复用空栈。
  private func teardownHostNavIfIdle() {
    guard let nav = navController else { return }
    if nav.presentingViewController != nil {
      nav.dismiss(animated: false)
      navController = nil
    } else {
      nav.setViewControllers([], animated: false)
    }
  }

  // MARK: - dsh-notify / dsh-permissions 宿主扩展模块

  /// 注册在 setup 之后:kit 会缓存 pendingExtModules 并自动注入之后新建的
  /// DMPApp(与 Android Dimina.init 之后 registerExtModule 同位)。
  private func registerHostExtModules(_ manager: DMPAppManager) {
    manager.registerExtModule(Self.notifyExtModule, handler: Self.notifyExtModuleHandler(self))
    manager.registerExtModule(Self.permissionsExtModule, handler: Self.permissionsExtModuleHandler(self))
  }

  /// 容器在专用 JS 引擎线程(com.dimina.jsengine.thread)上调用 ext 模块,
  /// handler 必须以 nonisolated 上下文产出(否则闭包字面量会继承 @MainActor,
  /// 容器跨线程调用时触发动态隔离断言);回调统一跳回主线程处理——kit 侧的
  /// DMPExtCallback → containerToService 内部也是这么跳的。
  nonisolated private static func notifyExtModuleHandler(
    _ plugin: DiminaPlugin
  ) -> DMPExtModuleHandler {
    { event, data, callback in
      Task { @MainActor in
        plugin.handleNotifyExtEvent(event: event, data: data, callback: callback)
      }
      // 一次性调用:extBridge 不需要取消函数(同 Android NotifyExtModule)。
      return nil
    }
  }

  nonisolated private static func permissionsExtModuleHandler(
    _ plugin: DiminaPlugin
  ) -> DMPExtModuleHandler {
    { event, data, callback in
      Task { @MainActor in
        plugin.handlePermissionExtEvent(event: event, data: data, callback: callback)
      }
      return nil
    }
  }

  /// 「dsh-notify」事件集(照 Android NotifyExtModule):
  ///  - showSubscribePanel:{appId, tmplIds:[...]} → 原生面板 → success
  ///    `{results:{tplId:'accept'|'reject'}}`;结果同时经 dsh/dimina 的
  ///    notifyConsent 回 Dart 逐条上报 AppHub(契约 §3.4)。
  ///  - getSubscribeState:{mainSwitch:bool, itemSettings:{tplId:'accept'|'reject'}}。
  private func handleNotifyExtEvent(event: String, data: DMPMap, callback: DMPExtCallback) {
    switch event {
    case "showSubscribePanel": presentSubscribePanel(data: data, callback: callback)
    case "getSubscribeState": sendSubscribeState(callback: callback)
    default: callback.onFail(DMPMap(["errMsg": "unknown event: \(event)"]))
    }
  }

  private func sendSubscribeState(callback: DMPExtCallback) {
    // 总闸短路时对外口径统一为「总开关开、无历史表态」:不让旧的
    // reject/mainSwitch=false 残留把存量小程序误导成「不能订阅」(Android
    // subscribeState 同款)。
    if Self.autoAcceptWithoutPanel {
      callback.onSuccess(DMPMap(["mainSwitch": true, "itemSettings": [String: String]() as [String: Any]]))
      return
    }
    callback.onSuccess(DMPMap([
      "mainSwitch": DiminaNotifyPreferences.mainSwitch,
      "itemSettings": DiminaNotifyPreferences.itemSettings as [String: Any],
    ]))
  }

  private func presentSubscribePanel(data: DMPMap, callback: DMPExtCallback) {
    let appId = data["appId"] as? String ?? ""
    var tmplIds: [String] = []
    for id in (data["tmplIds"] as? [Any])?.compactMap({ $0 as? String }) ?? [] {
      if !id.isEmpty && !tmplIds.contains(id) { tmplIds.append(id) }
    }
    if appId.isEmpty || tmplIds.isEmpty {
      callback.onFail(DMPMap(["errMsg": "showSubscribePanel:fail bad appId/tmplIds"]))
      return
    }
    if Self.autoAcceptWithoutPanel {
      // 总闸开着(2026-11-11 临时):不弹面板、不写 prefs、不上报 consent,
      // 所有模板直接回 accept。小程序代码一行不动(照旧调
      // requestSubscribeMessage 并拿到 accept);统一权限系统落地时与 Android/
      // server 一起把总闸改回 false,面板自然恢复。
      let results = Dictionary(uniqueKeysWithValues: tmplIds.map { ($0, "accept") })
      callback.onSuccess(DMPMap(["results": results as [String: Any]]))
      return
    }
    // 模板名经 Dart 通道拿(只有 Dart 知道当下 appHubBase/隧道端口);拿不到
    // 就显示「通知 N」兜底,绝不把 tpl_xxx 内部 id 摆给用户看。
    requestTemplateNames(appId: appId) { [weak self] appName, names in
      self?.presentSubscribeAlert(
        appId: appId, tmplIds: tmplIds, appName: appName, names: names, callback: callback)
    }
  }

  /// 模板名向 Dart 要(带 app 名);错误/未实现/坏形状一律空表,面板落「通知 N」。
  private func requestTemplateNames(
    appId: String, done: @escaping (String?, [String: String]) -> Void
  ) {
    channel.invokeMethod("notifyTemplates", arguments: ["appId": appId]) { response in
      if response is FlutterError { done(nil, [:]); return }
      guard let payload = response as? [String: Any] else {
        done(nil, [:])
        return
      }
      var names: [String: String] = [:]
      for (key, value) in payload["templates"] as? [String: Any] ?? [:] {
        names[key] = value as? String ?? key
      }
      done(payload["appName"] as? String, names)
    }
  }

  /// 原生订阅面板(契约 §5.3)。UIAlertController 没有 Android 版的主开关+
  /// 勾选列表:v1 收敛成「允许(全 accept)/拒绝(全 reject)」两键,模板名列在
  /// 正文;main_switch 存储语义保留(允许写 true、拒绝不动),逐模板历史照旧
  /// 记账,getSubscribeState 回读一致。v2 换 Flutter 玻璃 sheet 时再恢复逐模板
  /// 勾选(Android 同款 UI)。
  private func presentSubscribeAlert(
    appId: String, tmplIds: [String], appName: String?, names: [String: String],
    callback: DMPExtCallback
  ) {
    let displayName = appName?.isEmpty == false ? appName! : appId
    let lines = tmplIds.enumerated().map { index, id -> String in
      let name = names[id].flatMap { $0.isEmpty ? nil : $0 }
        ?? String(format: NSLocalizedString("Notification %lld", comment: ""), index + 1)
      return "• \(name)"
    }
    let body =
      String(
        format: NSLocalizedString(
          "“%@” would like to send you notifications after you act. Each subscription covers one message.",
          comment: "Subscribe panel body; parameter is the mini-program name."),
        displayName) + "\n\n" + lines.joined(separator: "\n")
    let alert = UIAlertController(
      title: String(localized: "Subscribe to notifications"),
      message: body,
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(
      title: String(localized: "Allow"), style: .default
    ) { [weak self] _ in
      // 主开关关着 = 全部 reject;允许 = 主开关开 + 全部 accept。
      self?.settleSubscribe(
        appId: appId, tmplIds: tmplIds, mainSwitch: true, accept: { _ in true }, callback: callback)
    })
    alert.addAction(UIAlertAction(
      title: String(localized: "Reject"), style: .cancel
    ) { [weak self] _ in
      // 拒绝保留既有主开关(Android 负按钮同语义)。
      self?.settleSubscribe(
        appId: appId, tmplIds: tmplIds, mainSwitch: DiminaNotifyPreferences.mainSwitch,
        accept: { _ in false }, callback: callback)
    })
    // 面板盖在最顶层 presented(小程序导航栈)上;alert 样式只能经两个按钮
    // 关闭,不存在「没走按钮就消失」的路径,JS 回调不会悬着。
    presentOverFlutter(alert)
  }

  /// 一次性结果:JSON 给 JS(onSuccess 由 kit 自动补 errMsg),Map 回 Dart 上报
  /// consent;主开关状态与逐模板选择都落盘,getSubscribeState 回读用(Android
  /// computeResults 同语义)。
  private func settleSubscribe(
    appId: String, tmplIds: [String], mainSwitch: Bool,
    accept: (String) -> Bool, callback: DMPExtCallback
  ) {
    var results: [String: String] = [:]
    for id in tmplIds {
      results[id] = accept(id) ? "accept" : "reject"
    }
    DiminaNotifyPreferences.record(results: results, mainSwitch: mainSwitch)
    callback.onSuccess(DMPMap(["results": results as [String: Any]]))
    channel.invokeMethod("notifyConsent", arguments: ["appId": appId, "results": results])
  }

  /// 「dsh-permissions」事件集(照 Android PermissionsExtModule):
  ///  - getPermissionState:{appId} → success 平面授权表 {scope: granted};
  ///    无记录 = 空表(诚实口径:未授权任何 scope)。
  ///  - setPermission:{appId, scope, granted} → 写宿主授权表,成功回写后的
  ///    平面授权表;坏参数 → fail errMsg,绝不抛异常崩容器。
  private func handlePermissionExtEvent(event: String, data: DMPMap, callback: DMPExtCallback) {
    switch event {
    case "getPermissionState":
      let appId = data["appId"] as? String ?? ""
      if appId.isEmpty {
        callback.onFail(DMPMap(["errMsg": "getPermissionState:fail bad appId"]))
        return
      }
      callback.onSuccess(DMPMap(DiminaPermissionStore.state(appId: appId) as [String: Any]))
    case "setPermission":
      let appId = data["appId"] as? String ?? ""
      let scope = data["scope"] as? String ?? ""
      let granted = (data["granted"] as? Bool) ?? false
      if appId.isEmpty || scope.isEmpty {
        callback.onFail(DMPMap(["errMsg": "setPermission:fail bad appId/scope"]))
        return
      }
      guard DiminaPermissionStore.set(appId: appId, scope: scope, granted: granted) else {
        callback.onFail(DMPMap(["errMsg": "setPermission:fail permission store unavailable"]))
        return
      }
      callback.onSuccess(DMPMap(DiminaPermissionStore.state(appId: appId) as [String: Any]))
    default:
      callback.onFail(DMPMap(["errMsg": "unknown event: \(event)"]))
    }
  }

  // MARK: - init / theme / presentation

  /// Android ensureInitialized 的对应物:setup 一次 + 胶囊配色跟宿主主题
  /// (iOS 胶囊是单套色,运行中切主题在下一次 open 前重设)。
  private func ensureInitialized(dark: Bool) {
    if initialized {
      if lastDark != dark {
        applyCapsuleTheme(dark: dark)
        lastDark = dark
      }
      return
    }
    initialized = true
    lastDark = dark
    let manager = DMPAppManager.sharedInstance()
    _ = manager.setup(apiNamespaces: [], virtualFilePrefix: "host-file://")
    // 浮窗保活与 Android 同参:最多 3 个后台应用,30 分钟回收(冷启保 storage)。
    manager.configureRetention(
      DMPRetentionPolicy(maxBackgroundApps: 3, backgroundTimeoutMs: 30 * 60 * 1000)
    )
    applyCapsuleTheme(dark: dark)
    // 宿主扩展通道:小程序 requestSubscribeMessage → 原生订阅面板(契约
    // §5.2/§5.3);平台权限契约 v1 §6 的 dsh-permissions 同注册。
    registerHostExtModules(manager)
  }

  private func applyCapsuleTheme(dark: Bool) {
    let manager = DMPAppManager.sharedInstance()
    manager.showCapsule = true
    manager.capsuleBackgroundColor =
      dark ? UIColor(red: 42 / 255.0, green: 45 / 255.0, blue: 52 / 255.0, alpha: 1) : .white
    manager.capsuleIconColor =
      dark ? .white : UIColor(red: 31 / 255.0, green: 31 / 255.0, blue: 31 / 255.0, alpha: 1)
  }

  /// Finds the top-most view controller (key window root, walking presented
  /// chain) and presents over it — used both for the container's navigation
  /// controller and for the subscribe panel above the running mini program.
  private func presentOverFlutter(_ controller: UIViewController) {
    let keyWindow = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .first { $0.isKeyWindow }
    var top = keyWindow?.rootViewController
    while let presented = top?.presentedViewController { top = presented }
    top?.present(controller, animated: false)
  }
}

/// 订阅同意状态的宿主持久化:Android SharedPreferences("dsh_notify") 的 iOS
/// 同形状实现——`main_switch`(Boolean,缺省 true)+ `item_settings`(逐模板
/// 'accept'|'reject' 的 JSON 串),键名与 Android 完全一致(契约 §5.3)。
private enum DiminaNotifyPreferences {
  private static let mainSwitchKey = "main_switch"
  private static let itemSettingsKey = "item_settings"

  private static var store: UserDefaults {
    UserDefaults(suiteName: "dsh_notify") ?? .standard
  }

  static var mainSwitch: Bool {
    store.object(forKey: mainSwitchKey) as? Bool ?? true
  }

  static var itemSettings: [String: String] {
    guard let json = store.string(forKey: itemSettingsKey),
      let data = json.data(using: .utf8),
      let table = try? JSONSerialization.jsonObject(with: data) as? [String: String]
    else { return [:] }
    return table
  }

  /// 主开关状态与逐模板选择合并落盘(Android computeResults 同语义)。
  static func record(results: [String: String], mainSwitch: Bool) {
    var table = itemSettings
    for (id, action) in results {
      table[id] = action
    }
    guard let data = try? JSONSerialization.data(withJSONObject: table) else { return }
    store.set(mainSwitch, forKey: mainSwitchKey)
    store.set(String(decoding: data, as: UTF8.self), forKey: itemSettingsKey)
  }
}

/// 宿主侧 per-appId 授权表(平台权限契约 v1 §6)。iOS 容器没有 Android 反射
/// 网关背后的 MiniProgramPermissionStore(容器权限闸今晚不做),由宿主
/// UserDefaults 承担同一数据源:每 appId 一条 JSON 平面表 {scope: granted},
/// 与 Android PermissionStoreGateway.stateMap 的输出形状一致;容器侧
/// dsh-permissions 扩展模块与 dsh/dimina 通道的 getPermissionState/setPermission
/// 读写同一张表。
private enum DiminaPermissionStore {
  private static var store: UserDefaults {
    UserDefaults(suiteName: "dsh_permissions") ?? .standard
  }

  static func state(appId: String) -> [String: Bool] {
    guard let json = store.string(forKey: appId),
      let data = json.data(using: .utf8),
      let table = try? JSONSerialization.jsonObject(with: data) as? [String: Bool]
    else { return [:] }
    return table
  }

  @discardableResult
  static func set(appId: String, scope: String, granted: Bool) -> Bool {
    var table = state(appId: appId)
    table[scope] = granted
    guard let data = try? JSONSerialization.data(withJSONObject: table) else { return false }
    store.set(String(decoding: data, as: UTF8.self), forKey: appId)
    return true
  }
}
