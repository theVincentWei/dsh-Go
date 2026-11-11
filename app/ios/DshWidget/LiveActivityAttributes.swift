// Shared between the app and the DshWidget extension (compiled into both):
// the ActivityKit attributes of DSH Go's one ongoing live activity — the
// agent's working/waiting/done state on the Dynamic Island and lock screen.
import ActivityKit
import Foundation

struct DshLiveActivityAttributes: ActivityAttributes {
  /// The conversation the tap falls back to, and the activity's identity
  /// (one conversation = one island): `<host encoded>|<sessionId>`.
  var conversationKey: String

  struct ContentState: Codable & Hashable {
    /// running | waiting | done | failed
    var kind: String
    /// The conversation's title (masked).
    var title: String
    /// The line under the title.
    var text: String
    /// A word or two for the compact chip (「干活中」/「待确认」…).
    var chip: String
    /// The privacy-safe line for the lock screen.
    var publicText: String
    /// The pet state name (thinking/working/juggling/sweeping/notification/attention/error).
    var mood: String
    /// When the run started: the island counts up from it (running/waiting).
    var startedAt: Date?

    static func == (lhs: ContentState, rhs: ContentState) -> Bool {
      lhs.kind == rhs.kind && lhs.title == rhs.title && lhs.text == rhs.text
        && lhs.chip == rhs.chip && lhs.publicText == rhs.publicText && lhs.mood == rhs.mood
        && lhs.startedAt == rhs.startedAt
    }

    func hash(into hasher: inout Hasher) {
      hasher.combine(kind)
      hasher.combine(title)
      hasher.combine(text)
      hasher.combine(chip)
      hasher.combine(publicText)
      hasher.combine(mood)
      hasher.combine(startedAt)
    }
  }
}
