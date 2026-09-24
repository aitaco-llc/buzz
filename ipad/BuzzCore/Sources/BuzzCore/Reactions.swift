import Foundation

/// Reference and deletion rules shared by reaction and message projections.
public enum EventRelations {
  /// NIP-25 targets the last e-tag, rather than an earlier ancestor reference.
  public static func target(_ event: Event) -> String? {
    event.tags.last { $0.count >= 2 && $0[0] == "e" }?[1]
  }

  /// Signed author deletions may omit h; relay moderation requires a verified authority.
  public static func deletes(
    _ deletion: Event, target: Event, channelID: String, authority: String? = nil
  ) -> Bool {
    guard deletion.tag("h").map({ $0 == channelID }) ?? true,
      deletion.tags.contains(where: { $0.count >= 2 && $0[0] == "e" && $0[1] == target.id })
    else { return false }
    return (deletion.kind == 5 && deletion.pubkey == target.pubkey)
      || (deletion.kind == 9005 && deletion.pubkey == authority)
  }

  /// NIP-09/NIP-25 wire events can derive their channel from the referenced event.
  public static func hasCompatibleChannel(_ event: Event, channelID: String) -> Bool {
    let tags = event.tags.filter { $0.first == "h" }
    if tags.isEmpty { return [5, 7].contains(event.kind) }
    return tags.count == 1 && event.tag("h") == channelID
  }
}

/// A reaction group counts people once while retaining every own event needed for removal.
public struct ReactionGroup: Identifiable, Equatable, Sendable {
  /// Unicode glyph or canonical custom shortcode.
  public let value: String
  /// Stable identity within one message's reaction row.
  public var id: String { value }
  /// Distinct people who currently have this reaction.
  public let authors: [String]
  /// All active matching reaction events, including duplicate events from one author.
  public let events: [Event]
  /// The reaction's self-contained NIP-30 image, when present.
  public let imageURL: URL?
  /// Number of distinct people, not event count.
  public var count: Int { authors.count }
  /// Every event this person must delete to remove the reaction completely.
  public func ownedIDs(_ pubkey: String) -> [String] {
    events.filter { $0.pubkey == pubkey }.map(\.id).sorted()
  }
}

/// Pure grouping over the community's verified cache plus durable local actions.
public enum ReactionProjection {
  /// Treats legacy NIP-25 like/dislike values as their visible Unicode equivalents.
  public static func value(_ content: String) -> String? {
    let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty || text == "+" { return "👍" }
    if text == "-" { return "👎" }
    if text.hasPrefix(":"), text.hasSuffix(":"), let code = CustomEmoji.normalize(text) {
      return ":\(code):"
    }
    guard text.unicodeScalars.count <= 64 else { return nil }
    return text
  }

  /// Builds all message groups once per cache change, independently of input ordering.
  public static func index(events: [Event], authority: String? = nil) -> [String: [ReactionGroup]] {
    let byID = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let deletions = events.filter { [5, 9005].contains($0.kind) }
    var grouped: [String: [String: [Event]]] = [:]
    for reaction in byID.values where reaction.kind == 7 {
      guard let targetID = EventRelations.target(reaction), let target = byID[targetID],
        Projection.messageKinds.contains(target.kind), let channelID = target.tag("h"),
        EventRelations.hasCompatibleChannel(reaction, channelID: channelID),
        let value = value(reaction.content),
        !deletions.contains(where: {
          EventRelations.deletes($0, target: reaction, channelID: channelID, authority: authority)
            || EventRelations.deletes(
              $0, target: target, channelID: channelID, authority: authority)
        })
      else { continue }
      grouped[targetID, default: [:]][value, default: []].append(reaction)
    }
    return grouped.mapValues { values in
      values.map { value, events in
        let ordered = events.sorted(by: EventCursor.relayOrder)
        let image = ordered.lazy.compactMap { CustomEmoji.inReaction($0)?.url }.first
        return ReactionGroup(
          value: value, authors: Set(events.map(\.pubkey)).sorted(),
          events: ordered, imageURL: image)
      }.sorted { $0.count == $1.count ? $0.value < $1.value : $0.count > $1.count }
    }
  }
}

/// One locally ranked emoji choice, stored atomically with its outgoing reaction.
public struct EmojiUsage: Codable, Equatable, Sendable {
  /// Unicode glyph or custom shortcode.
  public let value: String
  /// Saturating number of selections.
  public let count: Int
  /// Most recent selection time in milliseconds.
  public let lastUsed: Int

  /// Updates the device-local frequency ranking, bounded to 24 entries.
  public static func recording(_ value: String, in entries: [EmojiUsage], at time: Int)
    -> [EmojiUsage]
  {
    let count = min(entries.first { $0.value == value }?.count ?? 0, 999_999) + 1
    let next =
      entries.filter { $0.value != value } + [
        EmojiUsage(value: value, count: count, lastUsed: time)
      ]
    return Array(
      next.sorted {
        if $0.count != $1.count { return $0.count > $1.count }
        if $0.lastUsed != $1.lastUsed { return $0.lastUsed > $1.lastUsed }
        return $0.value < $1.value
      }.prefix(24))
  }
}
