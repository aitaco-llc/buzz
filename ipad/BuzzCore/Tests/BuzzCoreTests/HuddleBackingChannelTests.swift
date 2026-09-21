import Foundation
import Testing

@testable import BuzzCore

private let relaySecret = String(repeating: "0", count: 63) + "3"
private let creatorSecret = String(repeating: "0", count: 63) + "4"
private let intruderSecret = String(repeating: "0", count: 63) + "5"

private let backingChannelID = "22222222-2222-4222-8222-222222222222"

struct HuddleBackingChannelTests {
  /// The relay's metadata for a dead Huddle's backing channel can still say
  /// "not archived" long after the call ended, so the sidebar cannot wait for
  /// that flag. The creator-signed start is what makes the channel plumbing.
  @Test func backingChannelIsNeverARowEvenWhenItsMetadataLooksLive() throws {
    let relay = try Identity(hex: relaySecret)
    let creator = try Identity(hex: creatorSecret)
    let general = try relay.sign(
      kind: 39000, content: "", tags: [["d", "general"], ["name", "general"], ["t", "stream"]])
    let backing = try relay.sign(
      kind: 39000, content: "",
      tags: [
        ["d", backingChannelID], ["name", "huddle-22222222"], ["t", "stream"], ["private"],
        ["ttl", "3600"],
      ])
    let generalRoster = try relay.sign(
      kind: 39002, content: "", tags: [["d", "general"], ["p", creator.pubkey, "", "owner"]])
    let backingRoster = try relay.sign(
      kind: 39002, content: "",
      tags: [["d", backingChannelID], ["p", creator.pubkey, "", "owner"]])
    let start = try creator.sign(
      kind: 48100, content: "{\"ephemeral_channel_id\":\"\(backingChannelID)\"}",
      tags: [["h", "general"]])
    let events = [general, backing, generalRoster, backingRoster, start]

    let hidden = Projection.huddleBackingChannelIDs(events: events, relayPubkey: relay.pubkey)
    #expect(hidden == [backingChannelID])
    #expect(
      Projection.channels(events: events, pubkey: creator.pubkey, hiding: hidden).map(\.id)
        == ["general"])
    // Without the derivation the backing channel is a row — the state Lloyd's
    // sidebar was in, with five of them.
    #expect(
      Projection.channels(events: events, pubkey: creator.pubkey).map(\.id).contains(
        backingChannelID))
  }

  /// A start signed by someone who does not own the channel it names must not
  /// take that channel out of the signer's sidebar.
  @Test func aForgedStartCannotHideSomeoneElsesChannel() throws {
    let relay = try Identity(hex: relaySecret)
    let creator = try Identity(hex: creatorSecret)
    let intruder = try Identity(hex: intruderSecret)
    let roster = try relay.sign(
      kind: 39002, content: "",
      tags: [
        ["d", backingChannelID], ["p", creator.pubkey, "", "owner"],
        ["p", intruder.pubkey, "", "member"],
      ])
    let forged = try intruder.sign(
      kind: 48100, content: "{\"ephemeral_channel_id\":\"\(backingChannelID)\"}",
      tags: [["h", "general"]])

    #expect(
      Projection.huddleBackingChannelIDs(events: [roster, forged], relayPubkey: relay.pubkey)
        .isEmpty)
  }

  /// A start the relay did not sign the roster for proves nothing either.
  @Test func rosterMustBeRelaySigned() throws {
    let relay = try Identity(hex: relaySecret)
    let creator = try Identity(hex: creatorSecret)
    let selfRoster = try creator.sign(
      kind: 39002, content: "",
      tags: [["d", backingChannelID], ["p", creator.pubkey, "", "owner"]])
    let start = try creator.sign(
      kind: 48100, content: "{\"ephemeral_channel_id\":\"\(backingChannelID)\"}",
      tags: [["h", "general"]])

    #expect(
      Projection.huddleBackingChannelIDs(events: [selfRoster, start], relayPubkey: relay.pubkey)
        .isEmpty)
  }
}
