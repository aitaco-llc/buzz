import BuzzCore
import XCTest

@testable import Buzz

final class ThreadFollowTests: XCTestCase {
  @MainActor func testThreadFollowTogglePersistsPerCommunityAndIdentity() async throws {
    let identity = try Identity(hex: String(repeating: "0", count: 63) + "1")
    let community = try Community(url: "https://thread-follow.example", name: "Threads")
    let key = "buzz.followed-threads.\(community.id).\(identity.pubkey)"
    UserDefaults.standard.removeObject(forKey: key)
    defer { UserDefaults.standard.removeObject(forKey: key) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try LocalStore(directory: directory, community: community, pubkey: identity.pubkey)
    let workspace = Workspace(
      account: Account(id: UUID(), community: community, pubkey: identity.pubkey),
      identity: identity, store: store, relay: ThreadFollowRelay())
    workspace.toggleThreadFollow("root")
    XCTAssertTrue(workspace.followedThreads.contains("root"))
    XCTAssertEqual(UserDefaults.standard.stringArray(forKey: key), ["root"])
    workspace.toggleThreadFollow("root")
    XCTAssertFalse(workspace.followedThreads.contains("root"))
  }
}

private actor ThreadFollowRelay: RelayTransport {
  func query(_ filters: [EventFilter]) throws -> [Event] { [] }
  func publish(_ event: Event) throws {}
}
