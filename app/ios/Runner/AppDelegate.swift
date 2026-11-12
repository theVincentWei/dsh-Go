// DSH Go — iOS native bridges (phase 1).
//
// Everything the Android side does with Kotlin plugins, the iOS side does
// here, in one file, against the same MethodChannel contracts the Dart side
// already speaks (absence is tolerated everywhere upstream, so a missing
// feature degrades quietly instead of crashing):
//
// - `dsh/notify` + `dsh/notify/taps` + `dsh/notify/actions`: chat
//   notifications over UNUserNotificationCenter, with the approval actions
//   the composer's tool calls need. No Android channels here — iOS has no
//   per-channel blocking, so `done` / `attention` always report open.
// - `dsh/media`: 「保存到相册」 into the DSH Go album (add-only permission).
// - `dsh/native-files`: the system file/photo picker with the chunked read
//   protocol (`capabilities` / `pick` / `read` / `cancel`).
//
// Deliberately absent: the live activity (`liveStatus` reports unsupported —
// it needs a widget-extension target of its own) and voice (`dsh/voice`,
// `dsh/native-media`) which comes in a later phase.
//
// ── Two lessons baked into this file ──
// 1. The `FlutterImplicitEngineDelegate` conformance below is LOAD-BEARING:
//    without it Flutter never calls `didInitializeImplicitFlutterEngine`,
//    plugins never register, and Dart dies at startup on a broken prefs
//    channel before the first frame (2026-11-07).
// 2. The iOS 18.2 simulator's usernoted daemon is broken on this machine —
//    ANY UNUserNotificationCenter use hangs there. Develop on the 26.3
//    runtime (iPhone 17 Pro).

import Flutter
import UIKit
import UserNotifications
import Photos
import PhotosUI
import UniformTypeIdentifiers
import ActivityKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let notifyBridge = DshNotifyBridge()
  private let mediaBridge = DshMediaBridge()
  private let filesBridge = DshNativeFilesBridge()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let ok = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    notifyBridge.installAsNotificationCenterDelegate()
    notifyBridge.registerCategories()
    return ok
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "DshNativeBridges") else { return }
    let messenger = registrar.messenger()
    notifyBridge.register(on: messenger)
    mediaBridge.register(on: messenger)
    filesBridge.register(on: messenger)

    // Trivial app-level channel: the schedule editor's timezone picker reads
    // the device zone; notification taps' bringToFront is a no-op (the app is
    // already frontmost — iOS opens it by tapping the banner).
    let appChannel = FlutterMethodChannel(name: "dsh/app", binaryMessenger: messenger)
    appChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "getTimeZoneId": result(TimeZone.current.identifier)
      case "bringToFront": result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }

    // `dshgo://…` links and opened files (SceneDelegate forwards the URLs).
    DshLinksBridge.shared.register(on: messenger)

    // Shares from the ShareExtension (saved into the shared container).
    DshShareBridge.shared.register(on: messenger)
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Deep links & opened files (dsh/links)
// ─────────────────────────────────────────────────────────────────────────────

/// Forwards `dshgo://…` links and opened `file://` documents to Dart over the
/// `dsh/links` channel, in the shape LinksPlugin.kt uses on Android: the Dart
/// side sets itself as the handler, calls `ready`, and the native side pushes
/// `link` calls with `{'uri': …}`. Links that arrive before Dart's `ready`
/// (the cold-start link) are held and flushed in order when it lands.
final class DshLinksBridge: NSObject {
  static let shared = DshLinksBridge()

  private var channel: FlutterMethodChannel?
  private var dartReady = false
  private var held: [URL] = []
  private var lastForwarded: String?
  private var lastForwardedAt = Date.distantPast

  func register(on messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "dsh/links", binaryMessenger: messenger)
    self.channel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self, call.method == "ready" else {
        result(FlutterMethodNotImplemented)
        return
      }
      dartReady = true
      let held = self.held
      self.held = []
      for url in held {
        self.forward(url)
      }
      result(true)
    }
  }

  /// One incoming URL (SceneDelegate is the only caller). `dshgo://` links
  /// and `file://` documents pass; identical repeats within two seconds are
  /// dropped (scene + legacy application delegate can both observe one open).
  func handleOpen(_ url: URL) {
    let scheme = url.scheme?.lowercased()
    guard scheme == "dshgo" || url.isFileURL else { return }
    // The ShareExtension opened the host app after writing its inbox: look
    // again for manifests (kept out of the dedupe window on purpose).
    if scheme == "dshgo", url.host?.lowercased() == "intake" {
      DshShareBridge.shared.rescan()
    }
    NSLog("DSHLinks open %@", url.absoluteString)
    let now = Date()
    if url.absoluteString == lastForwarded, now.timeIntervalSince(lastForwardedAt) < 2 {
      return
    }
    lastForwarded = url.absoluteString
    lastForwardedAt = now
    if dartReady {
      forward(url)
    } else {
      held.append(url)
    }
  }

  private func forward(_ url: URL) {
    lastForwarded = url.absoluteString
    lastForwardedAt = Date()
    channel?.invokeMethod("link", arguments: ["uri": url.absoluteString])
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Share intake (dsh/share)
// ─────────────────────────────────────────────────────────────────────────────

/// Picks up what the ShareExtension wrote into the shared container
/// (`share-inbox/<id>/manifest.json` + files) and forwards it to Dart over
/// `dsh/share`, in the same shape the Android SharePlugin uses. Forwarded
/// entries are kept (Dart may read the files lazily while composing) and
/// cleaned after a day.
final class DshShareBridge: NSObject {
  static let shared = DshShareBridge()
  private static let appGroup = "group.io.github.thevincentwei.wanqi"
  private static let inboxName = "share-inbox"
  private static let keepInterval: TimeInterval = 24 * 3600

  private var channel: FlutterMethodChannel?
  private var dartReady = false

  func register(on messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "dsh/share", binaryMessenger: messenger)
    channel?.setMethodCallHandler { [weak self] call, result in
      guard let self, call.method == "ready" else {
        result(FlutterMethodNotImplemented)
        return
      }
      dartReady = true
      DispatchQueue.global(qos: .userInitiated).async { self.scanAndForward() }
      result(true)
    }
  }

  /// The ShareExtension opened `dshgo://intake`: the app may have been up
  /// while the share was written, so look again.
  func rescan() {
    DispatchQueue.global(qos: .userInitiated).async { self.scanAndForward() }
  }

  private func scanAndForward() {
    guard let root = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: Self.appGroup
    )?.appendingPathComponent(Self.inboxName, isDirectory: true) else { return }
    let fm = FileManager.default
    cleanOldEntries(root: root, fm: fm)
    guard let entries = try? fm.contentsOfDirectory(
      at: root, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles
    ) else { return }
    let dirs = entries
      .filter { (url: URL) in url.hasDirectoryPath }
      .sorted(by: { (a: URL, b: URL) -> Bool in
        let ad = (try? a.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
        let bd = (try? b.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
        return ad < bd
      })
    for dir in dirs {
      let manifestURL = dir.appendingPathComponent("manifest.json")
      guard let data = try? Data(contentsOf: manifestURL),
        let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else {
        try? fm.removeItem(at: dir)
        continue
      }
      var payload = manifest
      if let names = manifest["files"] as? [[String: Any]] {
        payload["files"] = names.map { entry in
          var entry = entry
          if let name = entry["name"] as? String {
            entry["path"] = dir.appendingPathComponent(name).path
          }
          return entry
        }
      }
      DispatchQueue.main.async {
        self.channel?.invokeMethod("share", arguments: payload)
      }
    }
  }

  private func cleanOldEntries(root: URL, fm: FileManager) {
    guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else { return }
    let cutoff = Date().addingTimeInterval(-Self.keepInterval)
    for entry in entries where (try? entry.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast < cutoff {
      try? fm.removeItem(at: entry)
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Extracts a String from an argument map.
private func argString(_ args: [String: Any], _ key: String) -> String? {
  args[key] as? String
}

/// Presents a view controller over whatever the scene currently shows.
private func presentOverRoot(_ controller: UIViewController) {
  var top = UIApplication.shared.connectedScenes
    .compactMap({ $0 as? UIWindowScene })
    .first(where: { $0.activationState == .foregroundActive })?
    .keyWindow?.rootViewController
    ?? UIApplication.shared.connectedScenes
      .compactMap({ $0 as? UIWindowScene }).first?.keyWindow?.rootViewController
  while let presented = top?.presentedViewController { top = presented }
  top?.present(controller, animated: true)
}

// ─────────────────────────────────────────────────────────────────────────────
// Notifications (dsh/notify, dsh/notify/taps, dsh/notify/actions)
// ─────────────────────────────────────────────────────────────────────────────

/// A mutable sink holder for one event channel.
private final class EventSink: NSObject, FlutterStreamHandler {
  private var sink: FlutterEventSink?

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  func send(_ payload: [String: Any?]) {
    DispatchQueue.main.async { self.sink?(payload) }
  }
}

final class DshNotifyBridge: NSObject, UNUserNotificationCenterDelegate {
  private static let approveCategory = "dsh_approve"
  private static let allowAction = "allowed-once"
  private static let rejectAction = "rejected"

  private var methods: FlutterMethodChannel?
  private let taps = EventSink()
  private let actions = EventSink()

  func register(on messenger: FlutterBinaryMessenger) {
    methods = FlutterMethodChannel(name: "dsh/notify", binaryMessenger: messenger)
    methods?.setMethodCallHandler(handle)
    FlutterEventChannel(name: "dsh/notify/taps", binaryMessenger: messenger).setStreamHandler(taps)
    FlutterEventChannel(name: "dsh/notify/actions", binaryMessenger: messenger).setStreamHandler(actions)
  }

  func installAsNotificationCenterDelegate() {
    UNUserNotificationCenter.current().delegate = self
  }

  /// The approval category exists before any post needs it.
  func registerCategories() {
    let allow = UNNotificationAction(identifier: Self.allowAction, title: "允许", options: [.authenticationRequired])
    let reject = UNNotificationAction(identifier: Self.rejectAction, title: "拒绝", options: [.destructive])
    let category = UNNotificationCategory(
      identifier: Self.approveCategory, actions: [allow, reject], intentIdentifiers: [], options: [])
    UNUserNotificationCenter.current().setNotificationCategories([category])
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "status":
      UNUserNotificationCenter.current().getNotificationSettings { settings in
        let enabled: Bool
        switch settings.authorizationStatus {
        case .authorized, .provisional, .notDetermined: enabled = true
        default: enabled = false
        }
        DispatchQueue.main.async {
          result(["native": true, "enabled": enabled, "done": true, "attention": true])
        }
      }
    case "show": show(args, result)
    case "cancel": cancel(ids: [identifier(group: argString(args, "group") ?? "", key: argString(args, "key") ?? "")], result)
    case "cancelGroup": cancelGroup(argString(args, "group") ?? "", result)
    case "cancelAll":
      let center = UNUserNotificationCenter.current()
      center.removeAllPendingNotificationRequests()
      center.removeAllDeliveredNotifications()
      result(nil)
    case "openSettings":
      guard let url = URL(string: UIApplication.openSettingsURLString) else { result(false); return }
      UIApplication.shared.open(url) { opened in result(opened) }
    case "live":
      DshLiveActivityController.shared.handle(args, result)
    case "actionResult":
      // The Android side updates the notification text; iOS already left the
      // notification in place, so removal (handled / gone) is all that maps.
      if let name = argString(args, "result"), name != "failed" {
        cancel(ids: [identifier(group: argString(args, "group") ?? "", key: argString(args, "key") ?? "")], result)
      } else {
        result(nil)
      }
    case "liveStatus":
      if #available(iOS 16.2, *) {
        let allowed = ActivityAuthorizationInfo().areActivitiesEnabled
        result(["native": true, "supported": true, "allowed": allowed, "settings": false, "xiaomiFocus": false])
      } else {
        result(["native": true, "supported": false, "allowed": false, "settings": false, "xiaomiFocus": false])
      }
    case "openLiveSettings": result(false)
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func identifier(group: String, key: String) -> String { "\(group)|\(key)" }

  private func show(_ args: [String: Any], _ result: @escaping FlutterResult) {
    let group = argString(args, "group") ?? ""
    let key = argString(args, "key") ?? ""
    let content = UNMutableNotificationContent()
    content.title = argString(args, "title") ?? "DSH"
    content.body = argString(args, "text") ?? ""
    content.threadIdentifier = group
    content.userInfo = [
      "group": group,
      "key": key,
      "sessionId": argString(args, "sessionId") ?? "",
      "host": argString(args, "host") ?? "",
      "kind": argString(args, "kind") ?? "",
      "eventId": argString(args, "eventId") ?? "",
    ]
    if args["canApprove"] as? Bool == true {
      content.categoryIdentifier = Self.approveCategory
    }
    if content.body.isEmpty { content.body = content.title }

    let request = UNNotificationRequest(identifier: identifier(group: group, key: key), content: content, trigger: nil)
    let center = UNUserNotificationCenter.current()
    let post: (Bool) -> Void = { granted in
      guard granted else { result(nil); return }
      center.add(request) { error in
        DispatchQueue.main.async {
          if let error { result(FlutterError(code: "failed", message: error.localizedDescription, details: nil)) }
          else { result(nil) }
        }
      }
    }
    center.getNotificationSettings { settings in
      if settings.authorizationStatus == .notDetermined {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in post(granted) }
      } else {
        post(settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional)
      }
    }
  }

  private func cancel(ids: [String], _ result: @escaping FlutterResult) {
    let center = UNUserNotificationCenter.current()
    center.removePendingNotificationRequests(withIdentifiers: ids)
    center.removeDeliveredNotifications(withIdentifiers: ids)
    result(nil)
  }

  private func cancelGroup(_ group: String, _ result: @escaping FlutterResult) {
    let center = UNUserNotificationCenter.current()
    center.getDeliveredNotifications { notes in
      let ids = notes.filter({ $0.request.content.threadIdentifier == group }).map(\.request.identifier)
      center.removeDeliveredNotifications(withIdentifiers: ids)
      DispatchQueue.main.async { result(nil) }
    }
  }

  // UNUserNotificationCenterDelegate

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    // Android parity: a heads-up banner even with the app open.
    completionHandler([.banner, .list, .sound])
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let info = response.notification.request.content.userInfo
    switch response.actionIdentifier {
    case UNNotificationDefaultActionIdentifier:
      if let session = info["sessionId"] as? String, !session.isEmpty {
        taps.send([
          "sessionId": session,
          "host": info["host"] as? String,
          "kind": info["kind"] as? String,
          "eventId": info["eventId"] as? String,
        ])
      }
    case Self.allowAction, Self.rejectAction:
      if let group = info["group"] as? String, let key = info["key"] as? String,
        let eventId = info["eventId"] as? String, !eventId.isEmpty, let host = info["host"] as? String {
        actions.send([
          "host": host,
          "group": group,
          "key": key,
          "eventId": eventId,
          "decision": response.actionIdentifier,
        ])
      }
    default: break
    }
    completionHandler()
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Live activity / Dynamic Island (dsh/notify 'live')
// ─────────────────────────────────────────────────────────────────────────────

/// Keeps the one ongoing live activity in sync with the pet's state pushes
/// (`live` on dsh/notify, the same contract LiveActivity.kt serves on
/// Android): start/update through ActivityKit; a done/failed state updates
/// once and ends after a short moment. The UI lives in DshWidget.
final class DshLiveActivityController: NSObject {
  static let shared = DshLiveActivityController()

  /// `Activity<DshLiveActivityAttributes>` under iOS 16.2 (stored as Any so
  /// the class compiles against the 15.0 deployment target).
  private var activity: Any?

  func handle(_ push: [String: Any], _ result: @escaping FlutterResult) {
    guard #available(iOS 16.2, *) else {
      result(nil)
      return
    }
    let enabled = (push["enabled"] as? Bool) ?? false
    guard enabled, let activityMap = push["activity"] as? [String: Any] else {
      endCurrent(result)
      return
    }

    let kind = activityMap["kind"] as? String ?? "running"
    let host = activityMap["host"] as? String ?? ""
    let sessionId = activityMap["sessionId"] as? String ?? ""
    let state = DshLiveActivityAttributes.ContentState(
      kind: kind,
      title: activityMap["title"] as? String ?? "DSH",
      text: activityMap["text"] as? String ?? "",
      chip: activityMap["chip"] as? String ?? "",
      publicText: activityMap["publicText"] as? String ?? "",
      mood: activityMap["mood"] as? String ?? "thinking",
      startedAt: (activityMap["sinceMs"] as? NSNumber).map {
        Date(timeIntervalSince1970: $0.doubleValue / 1000)
      }
    )
    let key = "\(host)|\(sessionId)"

    Task { @MainActor in
      guard #available(iOS 16.2, *) else {
        result(nil)
        return
      }
      let current = self.activity as? Activity<DshLiveActivityAttributes>
      if let current {
        await current.update(ActivityContent(state: state, staleDate: nil))
        if kind == "done" || kind == "failed" {
          await Self.endAfterMoment(current)
          self.activity = nil
        }
        result(nil)
      } else {
        do {
          let attributes = DshLiveActivityAttributes(conversationKey: key)
          let started = try Activity.request(
            attributes: attributes, content: ActivityContent(state: state, staleDate: nil))
          self.activity = started
          if kind == "done" || kind == "failed" {
            await Self.endAfterMoment(started)
            self.activity = nil
          }
          result(nil)
        } catch {
          NSLog("DSHLive request failed: %@", error.localizedDescription)
          result(FlutterError(code: "failed", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  /// 「完成」/「出错」 keeps its moment on the island, then clears itself.
  @available(iOS 16.2, *)
  private static func endAfterMoment(_ activity: Activity<DshLiveActivityAttributes>) async {
    try? await Task.sleep(nanoseconds: 4_000_000_000)
    await activity.end(
      ActivityContent(state: activity.content.state, staleDate: nil),
      dismissalPolicy: .immediate)
  }

  private func endCurrent(_ result: @escaping FlutterResult) {
    guard #available(iOS 16.2, *) else {
      result(nil)
      return
    }
    let current = activity as? Activity<DshLiveActivityAttributes>
    activity = nil
    Task { @MainActor in
      guard #available(iOS 16.2, *) else {
        result(nil)
        return
      }
      if let current {
        await current.end(
          ActivityContent(state: current.content.state, staleDate: nil),
          dismissalPolicy: .immediate)
      }
      result(nil)
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Save to gallery (dsh/media)
// ─────────────────────────────────────────────────────────────────────────────

final class DshMediaBridge: NSObject {
  private static let albumTitle = "DSH Go"
  private var methods: FlutterMethodChannel?

  func register(on messenger: FlutterBinaryMessenger) {
    methods = FlutterMethodChannel(name: "dsh/media", binaryMessenger: messenger)
    methods?.setMethodCallHandler(handle)
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "saveImage": saveImage(call.arguments as? [String: Any] ?? [:], result)
    case "openSettings":
      guard let url = URL(string: UIApplication.openSettingsURLString) else { result(false); return }
      UIApplication.shared.open(url) { opened in result(opened) }
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func saveImage(_ args: [String: Any], _ result: @escaping FlutterResult) {
    guard let data = (args["bytes"] as? FlutterStandardTypedData)?.data, !data.isEmpty else {
      result(FlutterError(code: "failed", message: "no image bytes", details: nil))
      return
    }
    let name = argString(args, "name") ?? "image.png"

    Task {
      do {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
          await MainActor.run { result(FlutterError(code: "permission", message: "photo library denied", details: nil)) }
          return
        }
        try await ensureAlbum()
        var placeholderId: String?
        try await PHPhotoLibrary.shared().performChanges {
          let request = PHAssetCreationRequest.forAsset()
          request.addResource(with: .photo, data: data, options: nil)
          placeholderId = request.placeholderForCreatedAsset?.localIdentifier
        }
        await MainActor.run { result("Photos/\(Self.albumTitle)/\(name)") }
      } catch {
        await MainActor.run { result(FlutterError(code: "failed", message: error.localizedDescription, details: nil)) }
      }
    }
  }

  /// The 「DSH Go」 album, created once (when the create fails the asset still
  /// lands in the library).
  private func ensureAlbum() async throws {
    let options = PHFetchOptions()
    options.predicate = NSPredicate(format: "title == %@", Self.albumTitle)
    let fetch = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: options)
    if fetch.firstObject != nil { return }
    try await PHPhotoLibrary.shared().performChanges {
      PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: Self.albumTitle)
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// System file picker (dsh/native-files)
// ─────────────────────────────────────────────────────────────────────────────

private final class PickedFile {
  let url: URL
  let name: String
  let size: Int
  let mime: String
  var offset = 0

  init(url: URL, name: String, size: Int, mime: String) {
    self.url = url
    self.name = name
    self.size = size
    self.mime = mime
  }
}

final class DshNativeFilesBridge: NSObject, PHPickerViewControllerDelegate, UIDocumentPickerDelegate {
  private var methods: FlutterMethodChannel?

  /// owner → handle → file. Only one pick is in flight at a time (the
  /// composer serializes them), and only its files stay held.
  private var owners: [String: [String: PickedFile]] = [:]
  private var pendingPick: FlutterResult?
  private var pendingOwner: String?

  func register(on messenger: FlutterBinaryMessenger) {
    methods = FlutterMethodChannel(name: "dsh/native-files", binaryMessenger: messenger)
    methods?.setMethodCallHandler(handle)
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "capabilities": result(["files": true])
    case "pick": pick(args, result)
    case "read": read(args, result)
    case "cancel":
      if let owner = argString(args, "owner") { drop(owner: owner) }
      result(nil)
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func pick(_ args: [String: Any], _ result: @escaping FlutterResult) {
    guard pendingPick == nil else { result([]); return }
    guard let owner = argString(args, "owner") else {
      result(FlutterError(code: "failed", message: "missing owner", details: nil))
      return
    }
    drop(owner: owner)
    pendingPick = result
    pendingOwner = owner
    let maxFiles = (args["maxFiles"] as? Int) ?? 1
    let images = args["images"] as? Bool == true
    let visual = args["visual"] as? Bool == true

    if images || visual {
      var config = PHPickerConfiguration(photoLibrary: .shared())
      config.filter = visual ? PHPickerFilter.any(of: [.images, .videos]) : .images
      config.selectionLimit = max(1, min(maxFiles, 20))
      let picker = PHPickerViewController(configuration: config)
      picker.delegate = self
      presentOverRoot(picker)
    } else {
      let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
      picker.allowsMultipleSelection = maxFiles != 1
      picker.delegate = self
      presentOverRoot(picker)
    }
  }

  private func finishPick(_ files: [PickedFile], owner: String) {
    guard let result = pendingPick else { return }
    pendingPick = nil
    drop(owner: owner)
    var held: [String: PickedFile] = [:]
    let payload: [[String: Any]] = files.map { file in
      let handle = UUID().uuidString
      held[handle] = file
      return ["handle": handle, "name": file.name, "bytes": file.size, "mediaType": file.mime]
    }
    owners[owner] = held
    result(payload)
  }

  private func cancelPick(owner: String) {
    guard let result = pendingPick else { return }
    pendingPick = nil
    drop(owner: owner)
    result([])
  }

  private func drop(owner: String) {
    if let held = owners.removeValue(forKey: owner) {
      for file in held.values {
        try? FileManager.default.removeItem(at: file.url)
      }
    }
  }

  /// Copies a picked item into the app's cache; PHPicker representations are
  /// deleted as soon as their callback returns, so the copy happens inline.
  private func hold(provider: NSItemProvider, owner: String, index: Int) async -> PickedFile? {
    let typeId = provider.registeredTypeIdentifiers.first { id in
      guard let type = UTType(id) else { return false }
      return type.conforms(to: .image) || type.conforms(to: .movie) || type.conforms(to: .data)
    }
    guard let typeId = typeId, let type = UTType(typeId) else { return nil }
    var name = provider.suggestedName ?? "file-\(index)"
    if !name.contains(".") {
      name += ".\(type.preferredFilenameExtension ?? "dat")"
    }
    return await withCheckedContinuation { continuation in
      _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
        guard let url else {
          continuation.resume(returning: nil)
          return
        }
        let destination = Self.cacheDirectory(owner: owner)
          .appendingPathComponent("\(UUID().uuidString)-\(name)")
        do {
          try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
          try FileManager.default.copyItem(at: url, to: destination)
          let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? 0
          let mime = type.preferredMIMEType ?? "application/octet-stream"
          continuation.resume(returning: PickedFile(url: destination, name: name, size: size, mime: mime))
        } catch {
          continuation.resume(returning: nil)
        }
      }
    }
  }

  private static func cacheDirectory(owner: String) -> URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("picked", isDirectory: true)
      .appendingPathComponent(owner, isDirectory: true)
  }

  // PHPickerViewControllerDelegate

  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    guard let owner = pendingOwner else { picker.dismiss(animated: true); return }
    picker.dismiss(animated: true)
    if results.isEmpty {
      cancelPick(owner: owner)
      return
    }
    Task {
      var files: [PickedFile] = []
      for (index, provider) in results.map(\.itemProvider).enumerated() {
        if let file = await hold(provider: provider, owner: owner, index: index) {
          files.append(file)
        }
      }
      DispatchQueue.main.async { self.finishPick(files, owner: owner) }
    }
  }

  // UIDocumentPickerDelegate

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let owner = pendingOwner else { controller.dismiss(animated: true); return }
    controller.dismiss(animated: true)
    var files: [PickedFile] = []
    for url in urls {
      do {
        let destination = Self.cacheDirectory(owner: owner)
          .appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: destination)
        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? 0
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        files.append(PickedFile(url: destination, name: url.lastPathComponent, size: size, mime: mime))
      } catch {
        continue
      }
    }
    finishPick(files, owner: owner)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    if let owner = pendingOwner { cancelPick(owner: owner) }
  }

  /// The chunked read: at most 64 KiB per call, nil closes the stream.
  private func read(_ args: [String: Any], _ result: @escaping FlutterResult) {
    guard let owner = argString(args, "owner"), let handle = argString(args, "handle"),
      let file = owners[owner]?[handle], let fileHandle = try? FileHandle(forReadingFrom: file.url)
    else {
      result(nil)
      return
    }
    defer { try? fileHandle.close() }
    do {
      try fileHandle.seek(toOffset: UInt64(file.offset))
      guard let chunk = try fileHandle.read(upToCount: 64 * 1024), !chunk.isEmpty else {
        result(nil)
        return
      }
      file.offset += chunk.count
      result(FlutterStandardTypedData(bytes: chunk))
    } catch {
      result(nil)
    }
  }
}
