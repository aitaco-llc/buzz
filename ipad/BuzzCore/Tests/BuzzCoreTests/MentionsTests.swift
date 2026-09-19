import Testing

@testable import BuzzCore

struct MentionsTests {
  @Test func ranksMembersAndRejectsMidWordAtSigns() {
    let candidates = [
      MentionCandidate(pubkey: "a", name: "Alice Smith"),
      MentionCandidate(pubkey: "b", name: "Al", member: true),
      MentionCandidate(pubkey: "c", name: "Sally", member: true),
    ]
    #expect(Mentions.activeQuery(in: "hello @al") == "al")
    #expect(Mentions.activeQuery(in: "mail@alice") == nil)
    #expect(Mentions.ranked(candidates, query: "al").map(\.pubkey) == ["b", "a"])
  }

  @Test func emitsOnlyUnambiguousExactProfileTags() {
    let candidates = [
      MentionCandidate(pubkey: "a", name: "Alice"),
      MentionCandidate(pubkey: "b", name: "Bob"),
      MentionCandidate(pubkey: "c", name: "Alice"),
    ]
    #expect(Mentions.tags(in: "@Bob hi", candidates: candidates) == [["p", "b"]])
    #expect(Mentions.tags(in: "@Alice hi", candidates: candidates).isEmpty)
  }
}
