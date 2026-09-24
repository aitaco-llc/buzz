import Foundation

public struct MentionCandidate: Equatable, Sendable {
  public let pubkey: String
  public let name: String
  public let member: Bool

  public init(pubkey: String, name: String, member: Bool = false) {
    self.pubkey = pubkey
    self.name = name
    self.member = member
  }
}

public enum Mentions {
  public static func activeQuery(in text: String) -> String? {
    guard let at = text.lastIndex(of: "@") else { return nil }
    let before = at == text.startIndex ? nil : text[text.index(before: at)]
    guard before == nil || before == " " || before == "\n" || before == "\t" else { return nil }
    let query = String(text[text.index(after: at)...])
    guard !query.contains(where: { $0.isWhitespace || $0 == "@" }) else { return nil }
    return query
  }

  public static func ranked(_ candidates: [MentionCandidate], query: String, limit: Int = 8)
    -> [MentionCandidate]
  {
    let q = query.lowercased()
    return candidates.enumerated().compactMap { index, candidate in
      let name = candidate.name.lowercased()
      let score: Int?
      if q.isEmpty || name == q {
        score = 0
      } else if name.hasPrefix(q) {
        score = 1
      } else if name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" }).contains(
        where: { $0 == Substring(q) })
      {
        score = 2
      } else if name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" }).contains(
        where: { $0.hasPrefix(q) })
      {
        score = 3
      } else if candidate.pubkey.lowercased().hasPrefix(q) {
        score = 4
      } else {
        score = nil
      }
      return score.map { (candidate, candidate.member ? 0 : 1, $0, index) }
    }.sorted { ($0.1, $0.2, $0.3) < ($1.1, $1.2, $1.3) }.prefix(limit).map(\.0)
  }

  public static func tags(in text: String, candidates: [MentionCandidate]) -> [[String]] {
    var result: [[String]] = []
    for candidate in candidates {
      let escaped = NSRegularExpression.escapedPattern(for: candidate.name)
      guard
        let regex = try? NSRegularExpression(
          pattern: "(?<![A-Za-z0-9_])@" + escaped + "(?![A-Za-z0-9_])", options: [.caseInsensitive])
      else { continue }
      guard !regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).isEmpty else {
        continue
      }
      guard
        candidates.filter({ $0.name.caseInsensitiveCompare(candidate.name) == .orderedSame }).count
          == 1
      else { continue }
      result.append(["p", candidate.pubkey])
    }
    return result
  }
}
