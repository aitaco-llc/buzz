import BuzzCore
import XCTest

@testable import Buzz

final class ReadStateTests: XCTestCase {
  @MainActor func testMarkChannelReadIsEncryptedDurableAndRestoresAfterRestart() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let identity = try Identity(hex: String(repeating: "0", count: 63) + "1")
    let community = try Community(url: "https://read-state.example", name: "Read state")
    let store = try LocalStore(directory: directory, community: community, pubkey: identity.pubkey)
    let message = try identity.sign(kind: 9, content: "Unread", tags: [["h", "general"]], at: 100)
    try await store.ingest([message])
    let workspace = Workspace(
      account: Account(id: UUID(), community: community, pubkey: identity.pubkey),
      identity: identity, store: store, relay: ReadStateOfflineRelay())
    let metadata = try identity.sign(
      kind: 39000, content: "", tags: [["d", "general"], ["name", "general"], ["t", "stream"]])
    let channel = try XCTUnwrap(Channel(event: metadata))
    await workspace.reload()
    XCTAssertEqual(workspace.unreadCount(for: channel), 1)
    let marked = await workspace.markChannelRead(channel.id)
    XCTAssertTrue(marked)
    XCTAssertEqual(workspace.unreadCount(for: channel), 0)
    let pending = await store.intentSnapshot().pending
    let state = try XCTUnwrap(pending.first?.event)
    XCTAssertEqual(state.kind, ReadStateProjection.kind)
    XCTAssertEqual(state.tag("d"), ReadStateProjection.dTag)
    XCTAssertEqual(
      ReadStateProjection.contexts(events: [state], identity: identity)["general"], 100)

    let reopenedStore = try LocalStore(
      directory: directory, community: community, pubkey: identity.pubkey)
    let reopened = Workspace(
      account: workspace.account, identity: identity, store: reopenedStore,
      relay: ReadStateOfflineRelay())
    await reopened.reload()
    XCTAssertEqual(reopened.unreadCount(for: channel), 0)
  }
}

private actor ReadStateOfflineRelay: RelayTransport {
  func query(_ filters: [EventFilter]) throws -> [Event] { throw BuzzError.http(503) }
  func publish(_ event: Event) throws { throw BuzzError.http(503) }
}
