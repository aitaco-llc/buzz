import Foundation

/// A channel reconstructed from NIP-29 metadata.
public struct Channel: Identifiable, Equatable, Sendable {
  /// NIP-29 channel identifier from the metadata d-tag.
  public let id: String
  /// Relay-provided channel name.
  public let name: String
  /// Stream, forum, or direct message channel type.
  public let type: String
  /// Human-readable channel description.
  public let about: String
  /// Public keys from the latest membership roster, falling back to metadata when unavailable.
  public let participants: [String]
  /// Whether the relay marked the channel archived.
  public let archived: Bool
  /// Whether this is an open stream/forum that permits self-join.
  public var isJoinable: Bool { isPublic && !archived && ["stream", "forum"].contains(type) }
  /// NIP-29 visibility; hidden groups and private groups never enter the public directory.
  public let isPublic: Bool

  /// Parses a metadata event; rejects missing channel identity.
  public init?(event: Event, participants: [String]? = nil) {
    guard event.kind == 39000, let id = event.tag("d"), !id.isEmpty else { return nil }
    self.id = id
    name = event.tag("name") ?? id
    type = event.tag("t") ?? (event.tags.contains(["hidden"]) ? "dm" : "stream")
    about = event.tag("about") ?? ""
    self.participants = Array(
      Set(participants ?? event.tags.filter { $0.count >= 2 && $0[0] == "p" }.map { $0[1] })
    ).sorted()
    archived = event.tag("archived") == "true"
    isPublic = !event.tags.contains(["private"]) && !event.tags.contains(["hidden"])
  }
}

/// Pure views of cached, verified events; the UI never consumes raw network events.
public enum Projection {
  /// Verified relay-authored metadata, deduplicated by channel with NIP-01 tie ordering.
  public static func directory(events: [Event], relayPubkey: String) -> [Channel] {
    latest(events.filter { $0.kind == 39000 && $0.pubkey == relayPubkey }, key: { $0.tag("d") })
      .values.compactMap { Channel(event: $0) }.filter(\.isJoinable)
      .sorted { ($0.name.localizedLowercase, $0.id) < ($1.name.localizedLowercase, $1.id) }
  }
  /// Kinds representing visible conversations, including older relay message formats.
  public static let messageKinds = [9, 40001, 40002, 45001, 45003]
  /// NIP-AR per-turn receipts. An overlay on the messages one agent turn
  /// published, never a row of its own.
  public static let turnReceiptKind = 44201
  /// Conversation updates needed to fold edits, reactions, deletions and receipts.
  public static let timelineKinds =
    messageKinds + [
      5, 7, 9005, 40003, 24810, 48100, 48103, turnReceiptKind,
    ]

  /// Counts visible replies by their thread root. Older clients sometimes omit
  /// the explicit `root` marker, so a direct `reply` parent is used as the
  /// root in that form as well.
  public static func replyCounts(events: [Event]) -> [String: Int] {
    events.reduce(into: [:]) { counts, event in
      guard messageKinds.contains(event.kind), let root = event.rootID ?? event.parentID else {
        return
      }
      counts[root, default: 0] += 1
    }
  }

  /// Most recent membership and metadata, using `d` tags for channel identity.
  public static func channels(events: [Event], pubkey: String) -> [Channel] {
    let memberships = latest(events.filter { $0.kind == 39002 }, key: { $0.tag("d") })
    let joined = Set(
      memberships.values.filter {
        $0.tags.contains { $0.count >= 2 && $0[0] == "p" && $0[1] == pubkey }
      }.compactMap { $0.tag("d") })
    return latest(events.filter { $0.kind == 39000 }, key: { $0.tag("d") }).values
      .compactMap { event in
        let members = memberships[event.tag("d") ?? ""]?.tags.filter {
          $0.count >= 2 && $0[0] == "p"
        }.map { $0[1] }
        return Channel(event: event, participants: members)
      }.filter { joined.contains($0.id) }
      .sorted { ($0.name.localizedLowercase, $0.id) < ($1.name.localizedLowercase, $1.id) }
  }

  /// Resolves the newest profile, falling back to an unambiguous short public key.
  public static func name(pubkey: String, events: [Event]) -> String {
    guard
      let profile = events.filter({ $0.kind == 0 && $0.pubkey == pubkey })
        .max(by: older),
      let data = profile.content.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return String(pubkey.prefix(12))
    }
    return object["display_name"] as? String ?? object["name"] as? String
      ?? String(pubkey.prefix(12))
  }

  /// Folds author edits/deletions into a channel's timeline, retaining thread relationships.
  public static func messages(
    events: [Event], channelID: String, rootID: String? = nil, windowRowIDs: Set<String>? = nil
  ) -> [Event] {
    let scoped = events.filter { $0.tag("h") == channelID }
    let byID = Dictionary(scoped.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    func belongsToThread(_ event: Event, root: String) -> Bool {
      if event.id == root || event.rootID == root { return true }
      var parent = event.parentID
      var visited = Set<String>()
      while let id = parent, visited.count < 64, visited.insert(id).inserted {
        if id == root { return true }
        parent = byID[id]?.parentID
      }
      return false
    }
    func broadcastRoot(_ event: Event) -> Bool {
      guard event.tags.contains(["broadcast", "1"]), let parent = event.parentID else {
        return false
      }
      if let known = byID[parent] { return known.parentID == nil }
      return event.rootID == parent
    }
    return scoped.filter { event in
      guard messageKinds.contains(event.kind),
        rootID.map({ belongsToThread(event, root: $0) })
          ?? (event.parentID == nil || windowRowIDs?.contains(event.id) == true
            || broadcastRoot(event))
      else { return false }
      return !events.contains { deletion in
        EventRelations.deletes(deletion, target: event, channelID: channelID)
      }
    }.sorted { lhs, rhs in
      if rootID != nil { return older(lhs, rhs) }
      return EventCursor.relayOrder(rhs, lhs)
    }
  }

  /// Edited text remains a presentation overlay; the original signed bytes are never altered.
  public static func content(of event: Event, events: [Event]) -> String {
    guard let channelID = event.tag("h") else { return event.content }
    return events.filter { edit in
      edit.kind == 40003 && edit.pubkey == event.pubkey
        && EventRelations.hasCompatibleChannel(edit, channelID: channelID)
        && EventRelations.target(edit) == event.id
        && !events.contains { EventRelations.deletes($0, target: edit, channelID: channelID) }
    }.max(by: older)?.content ?? event.content
  }

  private static func older(_ lhs: Event, _ rhs: Event) -> Bool {
    (lhs.createdAt, lhs.id) < (rhs.createdAt, rhs.id)
  }

  private static func latest(_ events: [Event], key: (Event) -> String?) -> [String: Event] {
    var result: [String: Event] = [:]
    for event in events {
      guard let id = key(event) else { continue }
      // NIP-01: lower event ID wins when replacement timestamps tie.
      if let previous = result[id],
        previous.createdAt > event.createdAt
          || (previous.createdAt == event.createdAt && previous.id < event.id)
      {
        continue
      }
      result[id] = event
    }
    return result
  }
}
