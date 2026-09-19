import BuzzCore
import XCTest

@testable import Buzz

final class StatusTests: XCTestCase {
  @MainActor func testStatusPublishesReplaceableEventAndSurvivesReload() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let identity = try Identity(hex: String(repeating: "0", count: 63) + "1")
    let community = try Community(url: "https://status.example", name: "Status")
    let store = try LocalStore(directory: directory, community: community, pubkey: identity.pubkey)
    try await store.setRelayAuthority(identity.pubkey)
    let workspace = Workspace(
      account: Account(id: UUID(), community: community, pubkey: identity.pubkey),
      identity: identity, store: store, relay: StatusRelay())
    let saved = await workspace.setStatus(text: "Heads down", emoji: "🛠️")
    XCTAssertTrue(saved)
    await workspace.reload()
    XCTAssertEqual(workspace.userStatus?.kind, 30315)
    XCTAssertEqual(workspace.userStatus?.content, "Heads down")
    XCTAssertEqual(workspace.userStatus?.tag("d"), "general")
    XCTAssertEqual(workspace.userStatus?.tag("emoji"), "🛠️")
    let snapshot = await store.intentSnapshot()
    XCTAssertTrue(snapshot.pending.isEmpty)
  }
}

private actor StatusRelay: RelayTransport {
  func query(_ filters: [EventFilter]) throws -> [Event] { [] }
  func publish(_ event: Event) throws {}
}
