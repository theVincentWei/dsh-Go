import Flutter
import UIKit
import Dimina

/// Flutter bridge to the Dimina (星河) mini-program container: MethodChannel
/// `dsh/dimina` (Dart side: lib/ui/applet/dimina/dimina_host.dart). iOS port of
/// android/.../dimina/DiminaPlugin.kt — the Android SDK contract mapped onto the
/// DiminaKit Swift API (DMPAppManager / DMPApp / DMPRemoteUpdateManager).
///
/// v1 scope notes (2026-11-16):
/// - open / installed / uninstall / close are implemented on DiminaKit.
/// - float has no iOS primitive yet → returns false (Dart ignores).
/// - sync (silent background install) → UNSUPPORTED for now; apps install via
///   market open (updateManifestUrl-driven download happens in-container).
/// - dsh-notify / dsh-permissions ext modules and update/lifecycle event
///   forwarding land with the iOS ext-module port; the market refreshes
///   installed state via its own re-query, so v1 stays functional without
///   events.
///
/// Mini programs render inside a host-presented UINavigationController
/// ([navController]); the container pushes its pages onto it (DMPNavigator).
/// The whole plugin is @MainActor: DiminaKit requires main-thread calls and
/// Flutter platform handlers already arrive there.
@MainActor
final class DiminaPlugin: NSObject {
  private static var instance: DiminaPlugin?
  private let channel: FlutterMethodChannel
  private var initialized = false
  private var lastDark: Bool?
  private var navController: UINavigationController?

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
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "open": open(call: call, result: result)
    case "close": close(call: call, result: result)
    case "float":
      // 问AI浮窗链路:iOS 容器暂无 float 原语,Dart 侧对 false 忽略。
      result(false)
    case "uninstall": uninstall(call: call, result: result)
    case "installed": installed(call: call, result: result)
    case "getPermissionState":
      // dsh-permissions 扩展模块 iOS 未接线:supported=false,Dart 侧降级只读
      // (与 Android 旧 dimina 依赖的降级语义一致)。
      result(["supported": false, "scopes": [String: Any]()])
    case "setPermission": result(false)
    case "sync":
      // autoSync 静默同步:iOS 走 updateManifestUrl 的容器内更新链路,独立
      // 后台静默装 v1 未接;市场页 open 路径不受影响。
      result(FlutterError(code: "UNSUPPORTED", message: "silent sync lands with the iOS ext-module port; use market open", details: nil))
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

    let manager = DMPAppManager.sharedInstance()
    let app = manager.appWithConfig(appConfig: config)

    // 宿主导航栈:容器把小程序页 push 到这条栈上。挂一次,跨启动复用。
    if navController == nil {
      let nav = UINavigationController()
      nav.setNavigationBarHidden(true, animated: false)
      // 全屏语义(对齐 Android 独立任务):默认 pageSheet 卡片式会露出宿主
      // 边缘;fullScreen 同时禁掉下滑关闭,小程序只能经容器胶囊退出。
      nav.modalPresentationStyle = .fullScreen
      navController = nav
      presentOverFlutter(nav)
    }
    if let nav = navController {
      app.getNavigator()?.setup(navigationController: nav)
    }

    // Android startMiniProgram 是同步启动 + result(true);这里调度后即回,
    // 下载/渲染由容器内部继续(失败走 onUpdateEvent/onDiminaEvent,后续接)。
    Task { @MainActor in
      var launchConfig = DMPLaunchConfig()
      if let path = config.path { launchConfig.appEntryPath = path }
      await app.launch(launchConfig: launchConfig)
    }
    result(true)
  }

  // MARK: - close / uninstall / installed

  private func close(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let appId = args["appId"] as? String, !appId.isEmpty
    else {
      result(FlutterError(code: "BAD_ARGS", message: "appId is required", details: nil))
      return
    }
    Task { @MainActor in
      let ok = await DMPAppManager.sharedInstance().closeMiniProgram(appId: appId)
      if ok, let nav = navController, nav.presentingViewController != nil {
        // 容器栈已空:把宿主呈现的全屏模态收掉,回到 Flutter 界面。
        nav.dismiss(animated: false)
        navController = nil
      }
      result(ok)
    }
  }

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
  }

  private func applyCapsuleTheme(dark: Bool) {
    let manager = DMPAppManager.sharedInstance()
    manager.showCapsule = true
    manager.capsuleBackgroundColor =
      dark ? UIColor(red: 42 / 255.0, green: 45 / 255.0, blue: 52 / 255.0, alpha: 1) : .white
    manager.capsuleIconColor =
      dark ? .white : UIColor(red: 31 / 255.0, green: 31 / 255.0, blue: 31 / 255.0, alpha: 1)
  }

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
