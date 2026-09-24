import BuzzCore
import XCTest

@testable import Buzz

final class MembershipWorkspaceTests: XCTestCase {
  @MainActor func testRetryUsesDurableRequestAfterChannelCacheIsLost() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let identity = try Identity(hex: String(repeating: "0", count: 63) + "1")
    let account = Account(
      id: UUID(), community: try Community(url: "https://membership.example", name: "Test"),
      pubkey: identity.pubkey)
    let store = try LocalStore(
      directory: directory, community: account.community, pubkey: identity.pubkey)
    let relay = UnavailableMembershipRelay()
    let workspace = Workspace(account: account, identity: identity, store: store, relay: relay)
    let previous = MembershipRequest(
      channelID: "missing-channel", channelName: "Saved channel name",
      event: try identity.sign(kind: 9022, content: "", tags: [["h", "missing-channel"]]))
    try await store.saveMembership(previous)
    try await store.updateMembership(id: previous.id, phase: .checking, failure: "Offline")
    try await store.saveDraft("Keep this draft", key: "missing-channel/timeline")
    await workspace.reload()
    XCTAssertTrue(workspace.channels.isEmpty)
    XCTAssertTrue(workspace.directory.isEmpty)

    await workspace.retryMembership(previous)
    let journal = await store.intentSnapshot()
    let replacement = try XCTUnwrap(journal.memberships.first)
    XCTAssertEqual(journal.memberships.count, 1)
    XCTAssertNotEqual(replacement.id, previous.id)
    XCTAssertEqual(replacement.channelID, previous.channelID)
    XCTAssertEqual(replacement.channelName, previous.channelName)
    XCTAssertEqual(replacement.event.kind, 9022)
    XCTAssertEqual(replacement.phase, .checking)
    XCTAssertNotNil(replacement.failure)
    XCTAssertEqual(journal.drafts["missing-channel/timeline"], "Keep this draft")
    let published = await relay.published
    XCTAssertEqual(published, [replacement.id])

    // A stale confirmation must not replace a newer request or send another command.
    await workspace.retryMembership(previous)
    let afterStaleRetry = await relay.published
    XCTAssertEqual(afterStaleRetry, published)
    XCTAssertNotNil(workspace.error)
    let reopened = try LocalStore(
      directory: directory, community: account.community, pubkey: identity.pubkey)
    let restored = await reopened.intentSnapshot()
    XCTAssertEqual(restored.memberships, journal.memberships)
  }

  @MainActor func testCreateChannelQueuesNip29CommandWithMetadataTags() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let identity = try Identity(hex: String(repeating: "0", count: 63) + "1")
    let community = try Community(url: "https://create-channel.example", name: "Test")
    let store = try LocalStore(directory: directory, community: community, pubkey: identity.pubkey)
    let workspace = Workspace(
      account: Account(id: UUID(), community: community, pubkey: identity.pubkey),
      identity: identity, store: store, relay: UnavailableMembershipRelay())
    let created = await workspace.createChannel(
      name: "Design", type: "forum", about: "Ideas", isPublic: true)
    XCTAssertTrue(created)
    let pending = await store.intentSnapshot().pending
    let event = try XCTUnwrap(pending.first?.event)
    XCTAssertEqual(event.kind, 9007)
    XCTAssertEqual(event.tag("name"), "Design")
    XCTAssertEqual(event.tag("channel_type"), "forum")
    XCTAssertEqual(event.tag("visibility"), "public")
    XCTAssertEqual(event.tag("about"), "Ideas")
    XCTAssertNotNil(event.tag("h"))
  }

  @MainActor func testUpdateChannelQueuesMetadataCommand() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let identity = try Identity(hex: String(repeating: "0", count: 63) + "1")
    let community = try Community(url: "https://update-channel.example", name: "Test")
    let store = try LocalStore(directory: directory, community: community, pubkey: identity.pubkey)
    let metadata = try identity.sign(
      kind: 39000, content: "", tags: [["d", "design"], ["name", "Design"], ["t", "stream"]])
    try await store.ingest([metadata])
    let channel = try XCTUnwrap(Channel(event: metadata))
    let workspace = Workspace(
      account: Account(id: UUID(), community: community, pubkey: identity.pubkey),
      identity: identity, store: store, relay: UnavailableMembershipRelay())
    let updated = await workspace.updateChannel(channel, name: "Product", about: "Plans")
    XCTAssertTrue(updated)
    let pending = await store.intentSnapshot().pending
    let event = try XCTUnwrap(pending.first?.event)
    XCTAssertEqual(event.kind, 9002)
    XCTAssertEqual(event.tag("h"), "design")
    XCTAssertEqual(event.tag("name"), "Product")
    XCTAssertEqual(event.tag("about"), "Plans")
  }

  @MainActor func testArchiveAndDeleteChannelQueueDistinctCommands() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let identity = try Identity(hex: String(repeating: "0", count: 63) + "1")
    let community = try Community(url: "https://archive-channel.example", name: "Test")
    let store = try LocalStore(directory: directory, community: community, pubkey: identity.pubkey)
    let metadata = try identity.sign(
      kind: 39000, content: "", tags: [["d", "design"], ["name", "Design"], ["t", "stream"]])
    try await store.ingest([metadata])
    let channel = try XCTUnwrap(Channel(event: metadata))
    let workspace = Workspace(
      account: Account(id: UUID(), community: community, pubkey: identity.pubkey),
      identity: identity, store: store, relay: UnavailableMembershipRelay())
    let archived = await workspace.archiveChannel(channel, archived: true)
    let deleted = await workspace.deleteChannel(channel)
    XCTAssertTrue(archived)
    XCTAssertTrue(deleted)
    let pending = await store.intentSnapshot().pending
    XCTAssertEqual(pending.map { $0.event.kind }, [9002, 9008])
    XCTAssertEqual(pending[0].event.tag("archived"), "true")
    XCTAssertEqual(pending[1].event.tag("h"), "design")
  }

  @MainActor func testAddMemberQueuesRoleAndChannelTags() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let identity = try Identity(hex: String(repeating: "0", count: 63) + "1")
    let other = try Identity(hex: String(repeating: "0", count: 63) + "2")
    let community = try Community(url: "https://member-add.example", name: "Test")
    let store = try LocalStore(directory: directory, community: community, pubkey: identity.pubkey)
    let metadata = try identity.sign(
      kind: 39000, content: "", tags: [["d", "design"], ["name", "Design"], ["t", "stream"]])
    try await store.ingest([metadata])
    let channel = try XCTUnwrap(Channel(event: metadata))
    let workspace = Workspace(
      account: Account(id: UUID(), community: community, pubkey: identity.pubkey),
      identity: identity, store: store, relay: UnavailableMembershipRelay())
    let added = await workspace.addMember(channel: channel, pubkey: other.pubkey, role: "moderator")
    XCTAssertTrue(added)
    let snapshot = await store.intentSnapshot()
    let event = try XCTUnwrap(snapshot.pending.first?.event)
    XCTAssertEqual(event.kind, 9000)
    XCTAssertEqual(event.tag("h"), "design")
    XCTAssertEqual(event.tag("p"), other.pubkey)
    XCTAssertEqual(event.tag("role"), "moderator")
  }
}

private actor UnavailableMembershipRelay: RelayTransport {
  var published: [String] = []
  func query(_ filters: [EventFilter]) throws -> [Event] { throw BuzzError.http(503) }
  func publish(_ event: Event) throws {
    published.append(event.id)
    throw BuzzError.http(503)
  }
}
