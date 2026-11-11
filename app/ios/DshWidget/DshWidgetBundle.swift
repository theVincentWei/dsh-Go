// DSH Go's widget extension: renders the ongoing live activity (the agent's
// state) on the Dynamic Island and the lock screen. Content is driven by the
// app process through ActivityKit (AppDelegate's DshLiveActivityController);
// the extension holds no state of its own.
import WidgetKit
import SwiftUI
import ActivityKit

@main
struct DshWidgetBundle: WidgetBundle {
  var body: some Widget {
    DshLiveActivityWidget()
  }
}

// ── Look helpers ──

private func moodEmoji(_ mood: String) -> String {
  switch mood {
  case "thinking": return "💭"
  case "working": return "⚙️"
  case "juggling": return "🤹"
  case "sweeping": return "🧹"
  case "notification": return "❓"
  case "attention": return "✅"
  case "error": return "❌"
  default: return "🐋"
  }
}

private let brandBlue = Color(red: 0x40 / 255, green: 0x5A / 255, blue: 0xAD / 255)

private func chipView(_ state: DshLiveActivityAttributes.ContentState) -> some View {
  HStack(spacing: 4) {
    if state.kind == "running", let startedAt = state.startedAt {
      Text(timerInterval: startedAt...startedAt.addingTimeInterval(3600), countsDown: false)
        .monospacedDigit()
        .font(.caption2)
        .frame(maxWidth: 56)
    } else {
      Text(state.chip)
        .font(.caption2.bold())
        .lineLimit(1)
    }
  }
  .foregroundStyle(.white)
  .padding(.horizontal, 8)
  .padding(.vertical, 3)
  .background(Capsule().fill(brandBlue))
}

// ── The widget ──

struct DshLiveActivityWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: DshLiveActivityAttributes.self) { context in
      // Lock screen card.
      HStack(spacing: 12) {
        Text(moodEmoji(context.state.mood)).font(.title2)
        VStack(alignment: .leading, spacing: 2) {
          Text(context.state.title).font(.footnote.bold()).lineLimit(1)
          Text(context.state.kind == "running" || context.state.kind == "waiting"
            ? context.state.publicText
            : context.state.text)
            .font(.caption).lineLimit(1)
            .foregroundStyle(.secondary)
        }
        Spacer()
        chipView(context.state)
      }
      .padding(.horizontal, 4)
      .activityBackgroundTint(brandBlue.opacity(0.18))
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Text(moodEmoji(context.state.mood)).font(.title2)
        }
        DynamicIslandExpandedRegion(.center) {
          VStack(alignment: .leading, spacing: 2) {
            Text(context.state.title).font(.caption.bold()).lineLimit(1)
            Text(context.state.text).font(.caption2).lineLimit(2).foregroundStyle(.secondary)
          }
        }
        DynamicIslandExpandedRegion(.trailing) {
          chipView(context.state)
        }
        DynamicIslandExpandedRegion(.bottom) {
          EmptyView()
        }
      } compactLeading: {
        Text(moodEmoji(context.state.mood)).font(.caption)
      } compactTrailing: {
        chipView(context.state)
      } minimal: {
        Text(moodEmoji(context.state.mood)).font(.caption2)
      }
    }
  }
}
