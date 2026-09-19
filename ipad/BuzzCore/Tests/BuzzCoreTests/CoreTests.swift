import Foundation
import Testing

@testable import BuzzCore

private let secret = String(repeating: "0", count: 63) + "1"
private let otherSecret = String(repeating: "0", count: 63) + "2"

struct CoreTests {
  @Test func signsAndVerifiesCanonicalUnicodeEvent() throws {
    let identity = try Identity(hex: secret)
    let event = try identity.sign(
      kind: 9, content: "Hello 🐝 / \"世界\"\n", tags: [["h", "channel"]], at: 100)
    #expect(event.pubkey == "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798")
    #expect(event.hasValidIDAndSignature())
    let tampered = Event(
      id: event.id, pubkey: event.pubkey, createdAt: event.createdAt,
      kind: 9, tags: event.tags, content: "tampered", sig: event.sig)
    #expect(!tampered.hasValidIDAndSignature())
    #expect(throws: BuzzError.self) { try Identity(hex: String(repeating: "+a", count: 32)) }
  }

  @Test func replyCountsHandleExplicitAndLegacyThreadRoots() throws {
    let identity = try Identity(hex: secret)
    let root = try identity.sign(kind: 9, content: "root", tags: [["h", "channel"]], at: 100)
    let explicit = try identity.sign(
      kind: 9, content: "explicit",
      tags: [["h", "channel"], ["e", root.id, "", "root"], ["e", root.id, "", "reply"]], at: 101)
    let legacy = try identity.sign(
      kind: 9, content: "legacy", tags: [["h", "channel"], ["e", root.id, "", "reply"]], at: 102)
    #expect(Projection.replyCounts(events: [root, explicit, legacy]) == [root.id: 2])
  }

  @Test func authIsBoundToBodyOriginAndUniqueNonce() throws {
    let identity = try Identity(hex: secret)
    let url = try #require(URL(string: "https://buzz.example/query"))
    let body = Data("[]".utf8)
    func decode(_ header: String) throws -> Event {
      let data = try #require(Data(base64Encoded: String(header.dropFirst(6))))
      return try JSONDecoder().decode(Event.self, from: data)
    }
    let first = try decode(identity.authorization(url: url, body: body))
    let second = try decode(identity.authorization(url: url, body: body))
    #expect(first.hasValidIDAndSignature())
    #expect(first.kind == 27235)
    #expect(first.tag("u") == url.absoluteString)
    #expect(
      first.tag("payload") == "4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945")
    #expect(first.id != second.id)
  }

  @Test func originsEnforceTenantAndCredentialBoundaries() throws {
    #expect(try Community(url: "wss://BUZZ.example:443/", name: "").id == "https://buzz.example")
    for invalid in [
      "https://user:secret@buzz.example", "https://buzz.example/path", "https://buzz.example?x=1",
      "http://buzz.example", "ws://buzz.example", "file:///tmp/foo",
    ] {
      #expect(throws: BuzzError.self) { try Community(url: invalid, name: "") }
    }
    #expect(try Community(url: "ws://localhost:3000", name: "Local").id == "http://localhost:3000")
  }

  @Test func filterRequiresKindsAndScopesUsingHashTags() throws {
    let filter = EventFilter(kinds: [9], tags: ["h": ["abc"]], limit: 999)
    let data = try JSONEncoder().encode(filter)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["#h"] as? [String] == ["abc"])
    #expect(object["limit"] as? Int == 500)
    #expect(throws: BuzzError.self) { try JSONEncoder().encode(EventFilter(kinds: [])) }
  }

  @Test func durableSendSurvivesRestartAndRetryKeepsIdentity() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let community = try Community(url: "https://buzz.example", name: "Test")
    let identity = try Identity(hex: secret)
    let store = try LocalStore(directory: root, community: community, pubkey: identity.pubkey)
    let event = try identity.sign(kind: 9, content: "Do not lose this", tags: [["h", "one"]])
    try await store.saveDraft(event.content, key: "one")
    try await store.enqueue(event, replacingDraft: "one", expectedDraft: event.content)
    let restarted = try LocalStore(directory: root, community: community, pubkey: identity.pubkey)
    let before = await restarted.intentSnapshot()
    #expect(before.drafts["one"] == nil)
    #expect(before.pending.map(\.id) == [event.id])
    let relay = FakeRelay()
    let outbox = Outbox(store: restarted, relay: relay)
    await #expect(throws: BuzzError.self) { try await outbox.flush() }
    let failed = await restarted.intentSnapshot()
    #expect(failed.pending.count == 1)
    #expect(failed.pending.first?.failure != nil)
    await relay.accept()
    try await outbox.flush()
    #expect(await relay.ids == [event.id, event.id])
    #expect(await restarted.intentSnapshot().pending.isEmpty)
    let again = try LocalStore(directory: root, community: community, pubkey: identity.pubkey)
    #expect(await again.cachedEvents().map(\.id) == [event.id])
    #expect(await again.intentSnapshot().pending.isEmpty)
  }

  @Test func communityAndIdentityStoresNeverMix() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let a = try Community(url: "https://a.example", name: "A")
    let b = try Community(url: "https://b.example", name: "B")
    let first = try LocalStore(directory: root, community: a, pubkey: "one")
    try await first.saveDraft("private", key: "channel")
    let second = try LocalStore(directory: root, community: b, pubkey: "one")
    let third = try LocalStore(directory: root, community: a, pubkey: "two")
    #expect(await second.intentSnapshot().drafts.isEmpty)
    #expect(await third.intentSnapshot().drafts.isEmpty)
  }

  @Test func enqueueDoesNotEraseNewerTypingAndRejectsTampering() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let identity = try Identity(hex: secret)
    let store = try LocalStore(
      directory: root, community: Community(url: "https://a.example", name: "A"),
      pubkey: identity.pubkey)
    try await store.saveDraft("newer draft", key: "c")
    let event = try identity.sign(kind: 9, content: "old draft", tags: [["h", "c"]])
    try await store.enqueue(event, replacingDraft: "c", expectedDraft: "old draft")
    #expect(await store.intentSnapshot().drafts["c"] == "newer draft")
    let bad = Event(
      id: event.id, pubkey: event.pubkey, createdAt: event.createdAt, kind: 9,
      tags: event.tags, content: "forged", sig: event.sig)
    await #expect(throws: BuzzError.self) { try await store.ingest([bad]) }
    #expect(await store.cachedEvents().isEmpty)
  }

  @Test func failedAtomicPersistLeavesDraftAndOutboxUnchanged() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let identity = try Identity(hex: secret)
    let community = try Community(url: "https://a.example", name: "A")
    let store = try LocalStore(directory: root, community: community, pubkey: identity.pubkey)
    try await store.saveDraft("Keep this draft", key: "c")
    let event = try identity.sign(kind: 9, content: "Keep this draft", tags: [["h", "c"]])
    let partition = try #require(
      FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
    let backup = root.appendingPathComponent("backup")
    try FileManager.default.moveItem(at: partition, to: backup)
    // A regular file where a directory belongs forces the production atomic write to fail.
    try Data().write(to: partition)
    await #expect(throws: (any Error).self) {
      try await store.enqueue(event, replacingDraft: "c", expectedDraft: event.content)
    }
    #expect(await store.intentSnapshot().pending.isEmpty)
    #expect(await store.intentSnapshot().drafts["c"] == event.content)
    try FileManager.default.removeItem(at: partition)
    try FileManager.default.moveItem(at: backup, to: partition)
    let reopened = try LocalStore(directory: root, community: community, pubkey: identity.pubkey)
    #expect(await reopened.intentSnapshot().drafts["c"] == event.content)
    try await reopened.enqueue(event, replacingDraft: "c", expectedDraft: event.content)
    #expect(await reopened.intentSnapshot().pending.map(\.id) == [event.id])
  }

  @Test func productionProjectionRespectsMembershipThreadsAndAuthors() throws {
    let identity = try Identity(hex: secret)
    let attacker = try Identity(hex: otherSecret)
    let metadata = try identity.sign(
      kind: 39000, content: "", tags: [["d", "c"], ["name", "General"], ["t", "stream"]])
    let membership = try identity.sign(
      kind: 39002, content: "", tags: [["d", "c"], ["p", identity.pubkey]])
    let root = try identity.sign(kind: 9, content: "original", tags: [["h", "c"]])
    let reply = try identity.sign(
      kind: 9, content: "reply", tags: [["h", "c"], ["e", root.id, "", "reply"]])
    let forgedEdit = try attacker.sign(
      kind: 40003, content: "forged", tags: [["h", "c"], ["e", root.id]])
    let forgedDeletion = try attacker.sign(
      kind: 5, content: "", tags: [["h", "c"], ["e", root.id]])
    let events = [metadata, membership, root, reply, forgedEdit, forgedDeletion]
    #expect(Projection.channels(events: events, pubkey: identity.pubkey).map(\.id) == ["c"])
    #expect(Projection.channels(events: events, pubkey: attacker.pubkey).isEmpty)
    #expect(Projection.messages(events: events, channelID: "c").map(\.id) == [root.id])
    #expect(Projection.messages(events: events, channelID: "c", rootID: root.id).count == 2)
    #expect(Projection.content(of: root, events: events) == "original")
    let edit = try identity.sign(
      kind: 40003, content: "edited", tags: [["h", "c"], ["e", root.id]])
    #expect(Projection.content(of: root, events: events + [edit]) == "edited")
    let deletion = try identity.sign(kind: 5, content: "", tags: [["h", "c"], ["e", root.id]])
    #expect(Projection.messages(events: events + [deletion], channelID: "c").isEmpty)
  }
}

private actor FakeRelay: RelayTransport {
  var ids: [String] = []
  private var succeeds = false
  func accept() { succeeds = true }
  func query(_ filters: [EventFilter]) async throws -> [Event] { [] }
  func publish(_ event: Event) async throws {
    ids.append(event.id)
    if !succeeds { throw BuzzError.http(503) }
  }
}
