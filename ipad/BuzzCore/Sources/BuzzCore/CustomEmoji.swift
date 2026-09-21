import Foundation

/// A normalized NIP-30 shortcode and its public image URL.
public struct CustomEmoji: Identifiable, Equatable, Sendable {
  /// Canonical shortcode without surrounding colons.
  public let shortcode: String
  /// Public HTTP image location; credentials are never attached by the renderer.
  public let url: URL
  /// Palette identity is shortcode-only, matching the existing mobile client.
  public var id: String { shortcode }
  /// Self-contained reaction content.
  public var value: String { ":\(shortcode):" }

  /// Parses a shortcode and a safe, absolute network image URL.
  public init?(shortcode: String, url: String) {
    guard let code = Self.normalize(shortcode), let parsed = URLComponents(string: url),
      parsed.scheme == "https"
        || (parsed.scheme == "http"
          && ["localhost", "127.0.0.1", "::1"].contains(parsed.host ?? "")),
      parsed.host?.isEmpty == false, parsed.user == nil, parsed.password == nil,
      let address = parsed.url, url.utf8.count <= 4096
    else { return nil }
    self.shortcode = code
    self.url = address
  }

  /// Shared mobile/relay normalization with the relay's 64-byte maximum.
  public static func normalize(_ value: String) -> String? {
    let code = value.trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: ":")).lowercased()
    guard !code.isEmpty, code.utf8.count <= 64,
      code.utf8.allSatisfy({
        (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
      })
    else { return nil }
    return code
  }

  /// Resolves a reaction's own emoji tag before consulting a mutable community palette.
  public static func inReaction(_ event: Event) -> CustomEmoji? {
    let content = event.content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard content.hasPrefix(":"), content.hasSuffix(":"), let code = normalize(content) else {
      return nil
    }
    return event.tags.lazy.compactMap { tag -> CustomEmoji? in
      guard tag.count >= 3, tag[0] == "emoji", normalize(tag[1]) == code else { return nil }
      return CustomEmoji(shortcode: code, url: tag[2])
    }.first
  }

  /// Unions each author's latest set; timestamp ties choose the lexical URL, as on mobile.
  public static func palette(events: [Event]) -> [CustomEmoji] {
    var heads: [String: Event] = [:]
    for event in events where event.kind == 30030 && event.tag("d") == "buzz:custom-emoji" {
      if let old = heads[event.pubkey],
        old.createdAt > event.createdAt
          || (old.createdAt == event.createdAt && old.id < event.id)
      {
        continue
      }
      heads[event.pubkey] = event
    }
    var winners: [String: (emoji: CustomEmoji, timestamp: Int)] = [:]
    for event in heads.values {
      var seen = Set<String>()
      for tag in event.tags where tag.count >= 3 && tag[0] == "emoji" {
        guard let emoji = CustomEmoji(shortcode: tag[1], url: tag[2]),
          seen.insert(emoji.shortcode).inserted
        else { continue }
        if let old = winners[emoji.shortcode],
          old.timestamp > event.createdAt
            || (old.timestamp == event.createdAt
              && old.emoji.url.absoluteString < emoji.url.absoluteString)
        {
          continue
        }
        winners[emoji.shortcode] = (emoji, event.createdAt)
      }
    }
    return winners.values.map(\.emoji).sorted { $0.shortcode < $1.shortcode }
  }
}
