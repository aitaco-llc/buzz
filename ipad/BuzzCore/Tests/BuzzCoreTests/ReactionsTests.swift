import Foundation
import Testing

@testable import BuzzCore

struct ReactionsTests {
  @Test func groupingCountsPeopleUsesLastTargetAndHonorsOnlyAuthorizedDeletions() throws {
    let f = try ReactionFixture()
    let message = try f.user.sign(kind: 9, content: "message", tags: [["h", "c"]])
    let first = try f.reaction(to: message, by: f.user, at: 1)
    let duplicate = try f.reaction(to: message, by: f.user, at: 2)
    let other = try f.reaction(to: message, by: f.other, at: 3)
    let wrongScope = try f.other.sign(
      kind: 7, content: "🎉", tags: [["h", "other"], ["e", message.id]])
    let ancestor = try f.other.sign(
      kind: 7, content: "🔥", tags: [["e", message.id], ["e", String(repeating: "0", count: 64)]])
    let forged = try f.other.sign(
      kind: 5, content: "", tags: [["e", first.id], ["e", duplicate.id]])
    let events = [message, first, duplicate, other, wrongScope, ancestor, forged]
    let groups = ReactionProjection.index(events: events)[message.id] ?? []
    #expect(groups.count == 1)
    #expect(groups.first?.count == 2)
    #expect(groups.first?.ownedIDs(f.user.pubkey) == [first.id, duplicate.id].sorted())
    let deletion = try f.user.sign(
      kind: 5, content: "", tags: [["e", first.id], ["e", duplicate.id]])
    let remaining = ReactionProjection.index(events: events + [deletion])[message.id]
    #expect(remaining?.first?.authors == [f.other.pubkey])
    let deleteMessage = try f.user.sign(kind: 5, content: "", tags: [["e", message.id]])
    #expect(ReactionProjection.index(events: events + [deleteMessage])[message.id] == nil)
    #expect(Projection.messages(events: events + [deleteMessage], channelID: "c").isEmpty)
    #expect(ReactionProjection.value("") == "👍")
    #expect(ReactionProjection.value("+") == "👍")
    #expect(ReactionProjection.value("-") == "👎")
  }

  @Test func relayModerationRequiresTheConfiguredAuthorityAndMatchingChannel() throws {
    let f = try ReactionFixture()
    let message = try f.user.sign(kind: 9, content: "message", tags: [["h", "c"]])
    let reaction = try f.reaction(to: message, by: f.user, at: 1)
    let deletion = try f.other.sign(
      kind: 9005, content: "", tags: [["h", "c"], ["e", reaction.id]])
    let events = [message, reaction, deletion]
    #expect(ReactionProjection.index(events: events)[message.id]?.first?.count == 1)
    #expect(ReactionProjection.index(events: events, authority: f.other.pubkey)[message.id] == nil)
    let wrongChannel = try f.other.sign(
      kind: 9005, content: "", tags: [["h", "other"], ["e", reaction.id]])
    #expect(
      ReactionProjection.index(
        events: [message, reaction, wrongChannel], authority: f.other.pubkey)[message.id]?.first?
        .count == 1)
  }

  @Test func customPaletteUsesLatestSetsAndReactionTagsKeepTheirOriginalImage() throws {
    let f = try ReactionFixture()
    let old = try f.user.sign(
      kind: 30030, content: "",
      tags: [["d", "buzz:custom-emoji"], ["emoji", "Party", "https://emoji.example/old.png"]], at: 1
    )
    let current = try f.user.sign(
      kind: 30030, content: "",
      tags: [
        ["d", "buzz:custom-emoji"], ["emoji", "party", "https://emoji.example/z.png"],
        ["emoji", "party", "https://emoji.example/duplicate.png"],
      ], at: 2)
    let other = try f.other.sign(
      kind: 30030, content: "",
      tags: [["d", "buzz:custom-emoji"], ["emoji", ":PARTY:", "https://emoji.example/a.png"]], at: 2
    )
    let palette = CustomEmoji.palette(events: [old, current, other])
    #expect(palette.count == 1)
    #expect(palette.first?.value == ":party:")
    #expect(palette.first?.url.absoluteString == "https://emoji.example/a.png")
    #expect(CustomEmoji.palette(events: [other, current, old]) == palette)
    let empty = try f.user.sign(
      kind: 30030, content: "", tags: [["d", "buzz:custom-emoji"]], at: 3)
    #expect(CustomEmoji.palette(events: [old, current, empty]).isEmpty)
    let reaction = try f.user.sign(
      kind: 7, content: ":Party:", tags: [["emoji", "party", "https://emoji.example/original.png"]])
    #expect(
      CustomEmoji.inReaction(reaction)?.url.absoluteString == "https://emoji.example/original.png")
    #expect(CustomEmoji.normalize(":" + String(repeating: "a", count: 64) + ":") != nil)
    #expect(CustomEmoji.normalize(String(repeating: "a", count: 65)) == nil)
    #expect(CustomEmoji(shortcode: "bad", url: "file:///etc/passwd") == nil)
    #expect(
      CustomEmoji(shortcode: "bad", url: "https://user:password@example.com/emoji.png") == nil)
    #expect(CustomEmoji.normalize("has spaces") == nil)
  }

  @Test func reactionUsageAndQueuedEventCommitTogetherAndRetryDoesNotCountTwice() async throws {
    let f = try ReactionFixture()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let community = try Community(url: "https://reaction.example", name: "Test")
    let store = try LocalStore(directory: directory, community: community, pubkey: f.user.pubkey)
    let message = try f.user.sign(kind: 9, content: "message", tags: [["h", "c"]])
    let reaction = try f.reaction(to: message, by: f.user, at: 1)
    try await store.enqueue(reaction, recordingReaction: "👍")
    try await store.enqueue(reaction, recordingReaction: "👍")
    #expect(await store.intentSnapshot().recentEmoji.first?.count == 1)
    let partition = try #require(
      FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
    let backup = directory.appendingPathComponent("backup")
    try FileManager.default.moveItem(at: partition, to: backup)
    try Data().write(to: partition)
    let second = try f.reaction(to: message, by: f.user, at: 2)
    await #expect(throws: (any Error).self) {
      try await store.enqueue(second, recordingReaction: "👍")
    }
    #expect(await store.intentSnapshot().pending.count == 1)
    #expect(await store.intentSnapshot().recentEmoji.first?.count == 1)
    try FileManager.default.removeItem(at: partition)
    try FileManager.default.moveItem(at: backup, to: partition)
    let reopened = try LocalStore(directory: directory, community: community, pubkey: f.user.pubkey)
    #expect(await reopened.intentSnapshot().recentEmoji.first?.value == "👍")
    var recent: [EmojiUsage] = []
    for i in 0..<30 { recent = EmojiUsage.recording(":e\(i):", in: recent, at: i) }
    #expect(recent.count == 24)
    #expect(recent.first?.value == ":e29:")
  }

  @Test func sharedCatalogIncludesVariantsAndMatchesMobileSearchTiers() throws {
    let json = """
      {"categories":[{"id":"people","emoji":["point_up","joy","smile"]}],"emoji":{
        "point_up":{"n":"Index Pointing Up","u":["☝️","☝🏽"],"k":["hand"]},
        "joy":{"n":"Face With Tears of Joy","u":["😂"],"k":["happy","laughing"]},
        "smile":{"n":"Smiling Face","u":["😄"],"k":["joyful"]}}}
      """
    let catalog = try EmojiCatalog(data: Data(json.utf8))
    #expect(catalog.entries.count == 4)
    #expect(catalog.search("pointup").map(\.glyph) == ["☝️", "☝🏽"])
    #expect(catalog.search("joy").first?.shortcode == "joy")
    #expect(catalog.search("laugh").first?.glyph == "😂")
    #expect(catalog.search("☝🏽").first?.glyph == "☝🏽")
    #expect(catalog.search("", category: "flags").isEmpty)
    #expect(catalog.search("no-such-emoji").isEmpty)
  }
}

private struct ReactionFixture {
  let user: Identity
  let other: Identity
  init() throws {
    user = try Identity(hex: String(repeating: "0", count: 63) + "1")
    other = try Identity(hex: String(repeating: "0", count: 63) + "2")
  }
  func reaction(to message: Event, by signer: Identity, at time: Int) throws -> Event {
    try signer.sign(
      kind: 7, content: "👍", tags: [["e", String(repeating: "a", count: 64)], ["e", message.id]],
      at: time)
  }
}
