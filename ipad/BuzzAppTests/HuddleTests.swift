import BuzzCore
import XCTest

@testable import Buzz

final class HuddleTests: XCTestCase {
  @MainActor func testHuddleLifecycleAndReactionUseDurableSignedEvents() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let identity = try Identity(hex: String(repeating: "0", count: 63) + "1")
    let community = try Community(url: "https://huddle.example", name: "Huddle")
    let store = try LocalStore(directory: directory, community: community, pubkey: identity.pubkey)
    let metadata = try identity.sign(
      kind: 39000, content: "", tags: [["d", "general"], ["name", "general"], ["t", "stream"]])
    let membership = try identity.sign(
      kind: 39002, content: "", tags: [["d", "general"], ["p", identity.pubkey, "member"]])
    try await store.ingest([metadata, membership])
    try await store.setRelayAuthority(identity.pubkey)
    let workspace = Workspace(
      account: Account(id: UUID(), community: community, pubkey: identity.pubkey),
      identity: identity, store: store, relay: HuddleRelay())
    await workspace.reload()
    let channel = try XCTUnwrap(workspace.channels.first)

    let startedValue = await workspace.startHuddle(in: channel)
    let started = try XCTUnwrap(startedValue)
    XCTAssertEqual(started.parentChannelID, channel.id)
    XCTAssertFalse(started.ephemeralChannelID.isEmpty)
    let initialSnapshot = await store.intentSnapshot()
    let startEvent = try XCTUnwrap(initialSnapshot.pending.last?.event)
    XCTAssertEqual(startEvent.kind, 48100)
    XCTAssertEqual(startEvent.tag("h"), channel.id)
    XCTAssertTrue(startEvent.content.contains(started.ephemeralChannelID))

    try await store.ingest([startEvent])
    workspace.events = await store.cachedEvents()
    XCTAssertEqual(
      workspace.activeHuddle(for: channel.id)?.ephemeralChannelID, started.ephemeralChannelID)

    let reacted = await workspace.sendHuddleReaction("👏", in: started)
    XCTAssertTrue(reacted)
    let ended = await workspace.endHuddle(started)
    XCTAssertTrue(ended)
    let pendingSnapshot = await store.intentSnapshot()
    let pending = pendingSnapshot.pending.map(\.event)
    XCTAssertTrue(
      pending.contains { $0.kind == 24810 && $0.tag("h") == started.ephemeralChannelID })
    XCTAssertTrue(pending.contains { $0.kind == 48103 && $0.tag("h") == channel.id })
  }
}

private actor HuddleRelay: RelayTransport {
  func query(_ filters: [EventFilter]) throws -> [Event] { [] }
  func publish(_ event: Event) throws { throw BuzzError.http(503) }
}
