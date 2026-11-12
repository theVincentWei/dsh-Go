import UIKit
import UniformTypeIdentifiers

/// The share sheet's working end: collects text / URLs / files from the
/// extension context, writes them into the shared App Group container
/// (`share-inbox/<id>/manifest.json` + files), then opens the host app with
/// `dshgo://intake` — the app's share bridge (AppDelegate `DshShareBridge`)
/// forwards the manifest over `dsh/share` and the router sends it on
/// (system_entry_host.dart). The intake link itself is swallowed by a
/// handler registered there.
class ShareViewController: UIViewController {
  private static let appGroup = "group.io.github.thevincentwei.wanqi"
  private static let maxFiles = 20

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    Task { await collect() }
  }

  private func collect() async {
    let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
    var textParts: [String] = []
    var subject: String?
    var files: [(name: String, url: URL, mime: String?, size: Int?)] = []
    var skipped: [(reason: String, name: String?)] = []

    for item in items {
      if let content = item.attributedContentText?.string, !content.isEmpty {
        // A page title next to a shared URL, a mail subject.
        subject = content
      }
      for provider in item.attachments ?? [] {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
          if files.count < Self.maxFiles, let file = await loadFile(provider) {
            files.append(file)
          } else if files.count >= Self.maxFiles {
            skipped.append(("too_many", provider.suggestedName))
          } else {
            skipped.append(("unreadable", provider.suggestedName))
          }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
          if let s = await loadURL(provider) { textParts.append(s) }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
          if let s = await loadText(provider) { textParts.append(s) }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.data.identifier) {
          if files.count < Self.maxFiles, let file = await loadFile(provider) {
            files.append(file)
          } else if files.count >= Self.maxFiles {
            skipped.append(("too_many", provider.suggestedName))
          } else {
            skipped.append(("unreadable", provider.suggestedName))
          }
        }
      }
    }

    writeInbox(
      text: textParts.isEmpty ? nil : textParts.joined(separator: "\n\n"),
      subject: subject,
      files: files,
      skipped: skipped)

    // Bring the host app forward; the manifest is picked up on `ready`.
    if let url = URL(string: "dshgo://intake") {
      extensionContext?.open(url) { _ in
        self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
      }
    } else {
      extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
  }

  // ── Attachment loading ──

  private func loadText(_ provider: NSItemProvider) async -> String? {
    await withCheckedContinuation { continuation in
      _ = provider.loadItem(forTypeIdentifier: UTType.text.identifier, options: nil) { item, _ in
        continuation.resume(returning: item as? String)
      }
    }
  }

  private func loadURL(_ provider: NSItemProvider) async -> String? {
    await withCheckedContinuation { continuation in
      _ = provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
        if let url = item as? URL { continuation.resume(returning: url.absoluteString) }
        else if let s = item as? String { continuation.resume(returning: s) }
        else { continuation.resume(returning: nil) }
      }
    }
  }

  /// Copies a shared file into a temp location; the inbox move happens in
  /// `writeInbox` (representations are deleted when this callback returns).
  private func loadFile(_ provider: NSItemProvider) async -> (name: String, url: URL, mime: String?, size: Int?)? {
    let typeId = provider.registeredTypeIdentifiers.first ?? UTType.data.identifier
    let rawName = provider.suggestedName ?? "shared"
    let type = UTType(typeId)
    var name = rawName
    if !name.contains(".") {
      name += ".\(type?.preferredFilenameExtension ?? "dat")"
    }
    let mime = type?.preferredMIMEType ?? "application/octet-stream"
    let staging = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString + "-" + name)
    return await withCheckedContinuation { continuation in
      _ = provider.loadFileRepresentation(forTypeIdentifier: typeId) { url, _ in
        guard let url else { continuation.resume(returning: nil); return }
        do {
          try FileManager.default.copyItem(at: url, to: staging)
          let size = (try? FileManager.default.attributesOfItem(atPath: staging.path)[.size] as? Int) ?? 0
          continuation.resume(returning: (name, staging, mime, size))
        } catch {
          continuation.resume(returning: nil)
        }
      }
    }
  }

  // ── Inbox write ──

  private func writeInbox(
    text: String?, subject: String?,
    files: [(name: String, url: URL, mime: String?, size: Int?)],
    skipped outerSkipped: [(reason: String, name: String?)]
  ) {
    var skipped = outerSkipped
    guard let root = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: Self.appGroup
    )?.appendingPathComponent("share-inbox", isDirectory: true) else {
      extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
      return
    }
    let fm = FileManager.default
    let dir = root.appendingPathComponent("\(Date().timeIntervalSince1970)-\(UUID().uuidString)", isDirectory: true)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

    var fileEntries: [[String: Any]] = []
    for file in files {
      let destination = dir.appendingPathComponent(file.name)
      do {
        try fm.copyItem(at: file.url, to: destination)
        var entry: [String: Any] = ["name": file.name]
        entry["mime"] = file.mime ?? "application/octet-stream"
        if let size = file.size { entry["size"] = size }
        fileEntries.append(entry)
      } catch {
        skipped.append(("unreadable", file.name))
      }
      try? fm.removeItem(at: file.url)
    }

    var manifest: [String: Any] = [:]
    if let text, !text.isEmpty { manifest["text"] = text }
    if let subject, !subject.isEmpty { manifest["subject"] = subject }
    manifest["files"] = fileEntries
    manifest["skipped"] = skipped.map { ["reason": $0.reason, "name": $0.name ?? ""] }

    if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted]) {
      try? data.write(to: dir.appendingPathComponent("manifest.json"))
    }
  }
}
