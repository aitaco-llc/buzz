import BuzzCore
import SwiftUI

struct ActivityItem: Identifiable, Equatable {
  let id: String
  let event: Event
  let title: String
  let detail: String
  let channelID: String?
}

enum ActivityProjection {
  static func items(events: [Event], identity: Identity, channels: [Channel]) -> [ActivityItem] {
    var names: [String: String] = [:]
    for event in events where names[event.pubkey] == nil {
      names[event.pubkey] = String(event.pubkey.prefix(8)) + "…"
    }
    let channelIDs = Set(channels.map(\.id))
    let relevant = events.filter { event in
      guard event.pubkey != identity.pubkey else { return false }
      let addressed = event.tags.contains {
        $0.count >= 2 && $0[0] == "p" && $0[1] == identity.pubkey
      }
      let reply = event.parentID != nil && event.kind != 7
      let reaction = event.kind == 7 && event.tags.contains { $0.count >= 2 && $0[0] == "e" }
      return addressed || reply || reaction
    }
    return relevant.sorted { $0.createdAt > $1.createdAt }.prefix(100).compactMap { event in
      let channelID = event.tag("h").flatMap { channelIDs.contains($0) ? $0 : nil }
      let sender = names[event.pubkey] ?? "Someone"
      let title: String
      let detail: String
      switch event.kind {
      case 7:
        title = "\(sender) reacted to a message"
        detail = event.content.isEmpty ? "Reaction" : event.content
      default:
        title = event.parentID == nil ? "\(sender) mentioned you" : "\(sender) replied to a thread"
        detail = event.content.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      return ActivityItem(
        id: event.id, event: event, title: title, detail: detail, channelID: channelID)
    }
  }
}

struct ActivityView: View {
  let workspace: Workspace
  let open: (ActivityItem) -> Void
  @Environment(\.dismiss) private var dismiss

  private var items: [ActivityItem] {
    ActivityProjection.items(
      events: workspace.events, identity: workspace.identity, channels: workspace.channels)
  }

  var body: some View {
    NavigationStack {
      Group {
        if items.isEmpty {
          ContentUnavailableView(
            "No activity yet", systemImage: "bell",
            description: Text("Mentions, replies, and reactions will appear here."))
        } else {
          List(items) { item in
            Button {
              open(item)
              dismiss()
            } label: {
              VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.headline)
                if !item.detail.isEmpty {
                  Text(item.detail).lineLimit(2).foregroundStyle(.secondary)
                }
                Text(
                  Date(timeIntervalSince1970: TimeInterval(item.event.createdAt)), style: .relative
                )
                .font(.caption).foregroundStyle(.tertiary)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("activity-\(item.id)")
          }
        }
      }
      .navigationTitle("Activity")
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
    }
  }
}
