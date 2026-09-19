import Foundation

/// One Unicode emoji variant from the same generated dataset as the Flutter client.
public struct EmojiEntry: Identifiable, Sendable {
  /// Stable tile identity, including skin-variant index.
  public let id: String
  /// Desktop/mobile-compatible shortcode.
  public let shortcode: String
  /// Human-readable search and accessibility name.
  public let name: String
  /// Unicode glyph including its skin modifiers.
  public let glyph: String
  /// Dataset category identifier.
  public let category: String
  /// Additional search terms from emoji-mart.
  public let keywords: [String]
}

/// Immutable, community-independent Unicode emoji data and shared-client search ranking.
public struct EmojiCatalog: Sendable {
  /// Ordered category identifiers.
  public let categories: [String]
  /// Every supported glyph variant in dataset order.
  public let entries: [EmojiEntry]

  private struct Source: Decodable {
    struct Category: Decodable {
      let id: String
      let emoji: [String]
    }
    struct Record: Decodable {
      let n: String
      let u: [String]
      let k: [String]
    }
    let categories: [Category]
    let emoji: [String: Record]
  }

  /// Decodes the checked-in mobile asset off the main actor.
  public init(data: Data) throws {
    guard data.count <= 2 * 1024 * 1024 else { throw BuzzError.responseTooLarge }
    let source = try JSONDecoder().decode(Source.self, from: data)
    guard source.categories.count <= 32, source.emoji.count <= 10_000 else {
      throw BuzzError.responseTooLarge
    }
    categories = source.categories.map(\.id)
    var result: [EmojiEntry] = []
    var seen = Set<String>()
    for category in source.categories {
      for code in category.emoji {
        guard let record = source.emoji[code], record.u.count <= 64 else {
          throw BuzzError.invalidResponse
        }
        for (index, glyph) in record.u.enumerated() {
          let id = "\(code)-\(index)"
          guard seen.insert(id).inserted else { continue }
          result.append(
            EmojiEntry(
              id: id, shortcode: code, name: record.n,
              glyph: glyph, category: category.id, keywords: record.k))
          guard result.count <= 20_000 else { throw BuzzError.responseTooLarge }
        }
      }
    }
    entries = result
  }

  /// Searches shortcode/name/keywords using mobile's exact, prefix, substring and subsequence tiers.
  public func search(_ query: String, category: String? = nil) -> [EmojiEntry] {
    let query = String(query.prefix(128)).trimmingCharacters(in: .whitespacesAndNewlines)
    if query.isEmpty { return entries.filter { category == nil || $0.category == category } }
    return entries.compactMap { entry -> (EmojiEntry, Int, Int)? in
      var match = Self.shortcodeScore(query, code: entry.shortcode)
      let words = ([entry.name] + entry.keywords).flatMap {
        $0.lowercased().split { $0.isWhitespace || $0 == "_" || $0 == "-" }.map(String.init)
      }
      for (index, word) in words.enumerated() {
        let tier =
          word.hasPrefix(query.lowercased()) ? 2 : (word.contains(query.lowercased()) ? 4 : 99)
        if tier < (match?.0 ?? 99) { match = (tier, index) }
      }
      if query == entry.glyph { match = (0, 0) }
      return match.map { (entry, $0.0, $0.1) }
    }.sorted {
      ($0.1, $0.2, $0.0.shortcode.count, $0.0.shortcode, $0.0.id)
        < ($1.1, $1.2, $1.0.shortcode.count, $1.0.shortcode, $1.0.id)
    }.map(\.0)
  }

  /// Ranks a custom shortcode with the same separator-insensitive tiers as standard emoji.
  public static func shortcodeScore(_ query: String, code: String) -> (Int, Int)? {
    func collapse(_ value: String) -> String {
      value.lowercased().filter { !$0.isWhitespace && $0 != ":" && $0 != "_" && $0 != "-" }
    }
    let q = collapse(String(query.prefix(128)))
    let target = collapse(code)
    guard !q.isEmpty, !target.isEmpty else { return nil }
    if q == target { return (0, 0) }
    if target.hasPrefix(q) { return (1, 0) }
    if let range = target.range(of: q) {
      return (3, target.distance(from: target.startIndex, to: range.lowerBound))
    }
    let needle = Array(q)
    var position = 0
    var first: Int?
    for (index, character) in target.enumerated() where character == needle[position] {
      if first == nil { first = index }
      position += 1
      if position == needle.count { return (5, index - (first ?? index)) }
    }
    return nil
  }
}
