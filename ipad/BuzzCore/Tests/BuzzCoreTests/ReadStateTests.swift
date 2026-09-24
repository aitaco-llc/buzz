import Foundation
import Testing

@testable import BuzzCore

struct ReadStateTests {
  @Test func encryptedReadStateRoundTripsAndLatestContextWins() throws {
    let identity = try Identity(hex: String(repeating: "0", count: 63) + "1")
    let first = ReadStateBlob(
      clientID: identity.pubkey, contexts: ["general": 10, "thread:root": 8])
    let key = try NIP44.conversationKey(identity: identity, peer: identity.pubkey)
    let content = try NIP44.encrypt(
      String(decoding: JSONEncoder().encode(first), as: UTF8.self), key: key,
      nonce: Array(repeating: 7, count: 32))
    let event = try identity.sign(
      kind: ReadStateProjection.kind, content: content,
      tags: [["d", ReadStateProjection.dTag], ["t", "read-state"]], at: 10)
    let second = ReadStateBlob(clientID: identity.pubkey, contexts: ["general": 20])
    let secondContent = try NIP44.encrypt(
      String(decoding: JSONEncoder().encode(second), as: UTF8.self), key: key,
      nonce: Array(repeating: 8, count: 32))
    let secondEvent = try identity.sign(
      kind: ReadStateProjection.kind, content: secondContent,
      tags: [["d", ReadStateProjection.dTag], ["t", "read-state"]], at: 20)
    #expect(
      ReadStateProjection.contexts(events: [event, secondEvent], identity: identity) == [
        "general": 20, "thread:root": 8,
      ])
  }

  @Test func malformedOrForeignReadStateNeverMovesTheMarker() throws {
    let identity = try Identity(hex: String(repeating: "0", count: 63) + "1")
    let other = try Identity(hex: String(repeating: "0", count: 63) + "2")
    let key = try NIP44.conversationKey(identity: identity, peer: identity.pubkey)
    let content = try NIP44.encrypt("not-json", key: key, nonce: Array(repeating: 1, count: 32))
    let malformed = try identity.sign(
      kind: ReadStateProjection.kind, content: content,
      tags: [["d", ReadStateProjection.dTag], ["t", "read-state"]], at: 100)
    let foreign = try other.sign(
      kind: ReadStateProjection.kind, content: content,
      tags: [["d", ReadStateProjection.dTag], ["t", "read-state"]], at: 200)
    #expect(ReadStateProjection.contexts(events: [malformed, foreign], identity: identity).isEmpty)
  }
}
