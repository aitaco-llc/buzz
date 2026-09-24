import BuzzCore
import XCTest

@testable import Buzz

final class PresenceTypingTests: XCTestCase {
  @MainActor func testPresenceAndTypingUseEphemeralWebSocketEvents() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let identity = try Identity(hex: String(repeating: "0", count: 63) + "1")
    let other = try Identity(hex: String(repeating: "0", count: 63) + "2")
    let community = try Community(url: "https://presence.example", name: "Presence")
    let store = try LocalStore(directory: directory, community: community, pubkey: identity.pubkey)
    let live = PresenceLive()
    let workspace = Workspace(
      account: Account(id: UUID(), community: community, pubkey: identity.pubkey),
      identity: identity, store: store, relay: PresenceRelay(), live: live)
    let metadata = try identity.sign(
      kind: 39000, content: "", tags: [["d", "general"], ["name", "general"], ["t", "stream"]])
    let channel = try XCTUnwrap(Channel(event: metadata))
    await workspace.setPresence("away")
    await workspace.sendTyping(channel: channel, root: nil)
    let events = live.eventsSent()
    XCTAssertEqual(events.map(\.kind), [20001, 20002])
    XCTAssertEqual(events[0].content, "away")
    XCTAssertEqual(events[1].tag("h"), "general")
  }
}

private actor PresenceRelay: RelayTransport {
  func query(_ filters: [EventFilter]) throws -> [Event] { [] }
  func publish(_ event: Event) throws {}
}

private final class PresenceLive: @unchecked Sendable, LiveEventTransport {
  private let lock = NSLock()
  var sent: [Event] = []
  nonisolated func events(filter: EventFilter) -> AsyncThrowingStream<Event, any Error> {
    AsyncThrowingStream { continuation in continuation.finish() }
  }
  nonisolated func publishEphemeral(_ event: Event) throws {
    lock.lock()
    defer { lock.unlock() }
    sent.append(event)
  }
  nonisolated func eventsSent() -> [Event] {
    lock.lock()
    defer { lock.unlock() }
    return sent
  }
}
