import BuzzCore
import XCTest

@testable import Buzz

final class ReactionActionsTests: XCTestCase {
  @MainActor func testAddRemoveAndReaddRemainDurableAndDeleteEveryOwnDuplicate() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let identity = try Identity(hex: String(repeating: "0", count: 63) + "1")
    let other = try Identity(hex: String(repeating: "0", count: 63) + "2")
    let community = try Community(url: "https://reaction.example", name: "Test")
    let store = try LocalStore(directory: directory, community: community, pubkey: identity.pubkey)
    let message = try other.sign(kind: 9, content: "React here", tags: [["h", "c"]])
    try await store.ingest([message])
    let workspace = Workspace(
      account: Account(id: UUID(), community: community, pubkey: identity.pubkey),
      identity: identity, store: store, relay: OfflineReactionRelay())
    await workspace.reload()
    let added = await workspace.react(to: message, value: "❤️")
    XCTAssertTrue(added)
    let original = try XCTUnwrap(workspace.reactions[message.id]?.first?.events.first)
    XCTAssertEqual(original.kind, 7)
    XCTAssertEqual(EventRelations.target(original), message.id)
    XCTAssertEqual(original.tag("p"), other.pubkey)
    XCTAssertTrue(original.hasValidIDAndSignature())
    let duplicate = try identity.sign(
      kind: 7, content: "❤️", tags: [["e", message.id]], at: original.createdAt)
    try await store.ingest([duplicate])
    let alreadyAdded = await workspace.react(to: message, value: "❤️")
    XCTAssertTrue(alreadyAdded)
    XCTAssertEqual(workspace.intents.recentEmoji.first?.count, 1)
    let removed = await workspace.react(to: message, value: "❤️", toggle: true)
    XCTAssertTrue(removed)
    XCTAssertNil(workspace.reactions[message.id])
    let snapshot = await store.intentSnapshot()
    let removal = try XCTUnwrap(snapshot.pending.last?.event)
    XCTAssertEqual(removal.kind, 5)
    XCTAssertEqual(
      Set(removal.tags.filter { $0.first == "e" }.map { $0[1] }), [original.id, duplicate.id])
    XCTAssertEqual(snapshot.recentEmoji.first?.count, 1)
    let readded = await workspace.react(to: message, value: "❤️")
    XCTAssertTrue(readded)
    let fresh = try XCTUnwrap(workspace.reactions[message.id]?.first?.events.first)
    XCTAssertNotEqual(fresh.id, original.id)
    XCTAssertNotNil(fresh.tag("nonce"))
    XCTAssertEqual(workspace.intents.recentEmoji.first?.count, 2)
    let reopened = try LocalStore(
      directory: directory, community: community, pubkey: identity.pubkey)
    let saved = await reopened.intentSnapshot()
    XCTAssertEqual(saved.pending.map(\.event.kind), [7, 5, 7])
    XCTAssertEqual(saved.recentEmoji.first?.count, 2)
    let otherStore = try LocalStore(
      directory: directory, community: community, pubkey: other.pubkey)
    let otherSnapshot = await otherStore.intentSnapshot()
    XCTAssertTrue(otherSnapshot.recentEmoji.isEmpty)
  }

  @MainActor func testCustomReactionCarriesItsImageAndBundledCatalogHasEveryVariant() async throws {
    let catalog = try await EmojiCatalogStore.shared.load()
    XCTAssertEqual(catalog.entries.count, 3395)
    XCTAssertTrue(catalog.entries.contains { $0.glyph == "👍🏿" })
    XCTAssertTrue(catalog.categories.contains("flags"))
    XCTAssertEqual(catalog.search("thumbsup").first?.glyph, "👍")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let identity = try Identity(hex: String(repeating: "0", count: 63) + "1")
    let community = try Community(url: "https://reaction.example", name: "Test")
    let store = try LocalStore(directory: directory, community: community, pubkey: identity.pubkey)
    let message = try identity.sign(kind: 9, content: "React here", tags: [["h", "c"]])
    try await store.ingest([message])
    let workspace = Workspace(
      account: Account(id: UUID(), community: community, pubkey: identity.pubkey),
      identity: identity, store: store, relay: OfflineReactionRelay())
    let url = try XCTUnwrap(URL(string: "https://emoji.example/party.png"))
    let added = await workspace.react(to: message, value: ":Party:", imageURL: url)
    XCTAssertTrue(added)
    let pending = await store.intentSnapshot().pending
    let reaction = try XCTUnwrap(pending.first?.event)
    XCTAssertEqual(reaction.content, ":party:")
    XCTAssertTrue(reaction.tags.contains(["emoji", "party", url.absoluteString]))
  }

  @MainActor func testGlobalPulseNoteCanReceiveDurableReactionWithoutChannelTag() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let identity = try Identity(hex: String(repeating: "0", count: 63) + "1")
    let other = try Identity(hex: String(repeating: "0", count: 63) + "2")
    let community = try Community(url: "https://pulse-reaction.example", name: "Pulse")
    let store = try LocalStore(directory: directory, community: community, pubkey: identity.pubkey)
    let note = try other.sign(kind: 1, content: "Pulse note", tags: [])
    try await store.ingest([note])
    let workspace = Workspace(
      account: Account(id: UUID(), community: community, pubkey: identity.pubkey),
      identity: identity, store: store, relay: OfflineReactionRelay())
    await workspace.reload()
    let added = await workspace.react(to: note, value: "❤️")
    XCTAssertTrue(added)
    let snapshot = await store.intentSnapshot()
    let reaction = try XCTUnwrap(snapshot.pending.first?.event)
    XCTAssertEqual(reaction.kind, 7)
    XCTAssertEqual(reaction.tag("e"), note.id)
    XCTAssertNil(reaction.tag("h"))
  }
}

private actor OfflineReactionRelay: RelayTransport {
  func query(_ filters: [EventFilter]) throws -> [Event] { throw BuzzError.http(503) }
  func publish(_ event: Event) throws { throw BuzzError.http(503) }
}
