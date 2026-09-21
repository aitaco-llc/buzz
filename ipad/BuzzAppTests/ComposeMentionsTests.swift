import BuzzCore
import XCTest

@testable import Buzz

final class ComposeMentionsTests: XCTestCase {
  @MainActor func testSendAddsUnambiguousProfileMentionTag() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let identity = try Identity(hex: String(repeating: "0", count: 63) + "1")
    let other = try Identity(hex: String(repeating: "0", count: 63) + "2")
    let community = try Community(url: "https://mentions.example", name: "Mentions")
    let store = try LocalStore(directory: directory, community: community, pubkey: identity.pubkey)
    let profile = try other.sign(kind: 0, content: "{\"display_name\":\"Alice\"}", tags: [])
    try await store.ingest([profile])
    let workspace = Workspace(
      account: Account(id: UUID(), community: community, pubkey: identity.pubkey),
      identity: identity, store: store, relay: MentionOfflineRelay())
    await workspace.reload()
    let metadata = try identity.sign(
      kind: 39000, content: "", tags: [["d", "general"], ["name", "general"], ["t", "stream"]])
    let channel = try XCTUnwrap(Channel(event: metadata))
    let sent = await workspace.send(text: "Hi @Alice", channel: channel, root: nil)
    XCTAssertTrue(sent)
    let pending = await store.intentSnapshot().pending
    XCTAssertEqual(pending.last?.event.tag("p"), other.pubkey)
  }

  @MainActor func testOpenDMUsesCommandResponseAndHydratesChannel() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let identity = try Identity(hex: String(repeating: "0", count: 63) + "1")
    let other = try Identity(hex: String(repeating: "0", count: 63) + "2")
    let community = try Community(url: "https://dm.example", name: "DM")
    let store = try LocalStore(directory: directory, community: community, pubkey: identity.pubkey)
    let relay = DmCommandRelay(identity: identity, participant: other.pubkey)
    try await store.setRelayAuthority(identity.pubkey)
    try await store.ingest([
      try other.sign(kind: 0, content: "{\"display_name\":\"Alice\"}", tags: [])
    ])
    let workspace = Workspace(
      account: Account(id: UUID(), community: community, pubkey: identity.pubkey),
      identity: identity, store: store, relay: relay)
    await workspace.reload()
    let channel = try await workspace.openDM(with: [other.pubkey])
    XCTAssertEqual(channel.id, "dm-channel")
    XCTAssertEqual(channel.type, "dm")
    let sent = await relay.sentTags()
    XCTAssertEqual(sent, [["p", other.pubkey]])
  }
}

private actor MentionOfflineRelay: RelayTransport {
  func query(_ filters: [EventFilter]) throws -> [Event] { throw BuzzError.http(503) }
  func publish(_ event: Event) throws { throw BuzzError.http(503) }
}

private actor DmCommandRelay: CommandRelayTransport {
  let identity: Identity
  let participant: String
  var tags: [[String]] = []

  init(identity: Identity, participant: String) {
    self.identity = identity
    self.participant = participant
  }

  func authority() async throws -> String { identity.pubkey }

  func query(_ filters: [EventFilter]) async throws -> [Event] {
    guard filters.first?.tags["d"] == ["dm-channel"] else { return [] }
    return [
      try identity.sign(
        kind: 39000, content: "",
        tags: [
          ["d", "dm-channel"], ["name", "DM"], ["t", "dm"], ["hidden"], ["p", identity.pubkey],
          ["p", participant],
        ]),
      try identity.sign(
        kind: 39002, content: "",
        tags: [["d", "dm-channel"], ["p", identity.pubkey], ["p", participant]]),
    ]
  }

  func publish(_ event: Event) async throws {}

  func publishCommand(_ event: Event) async throws -> String {
    tags = event.tags
    return "response:{\"channel_id\":\"dm-channel\"}"
  }

  func sentTags() -> [[String]] { tags }
}
