import Foundation
import Testing

@testable import BuzzCore

struct MembershipTests {
  @Test func journalFailurePreventsPublishAndRetainsQueuedIntent() async throws {
    let f = try MembershipFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let store = try f.store()
    let wrongOwner = MembershipRequest(
      channelID: "c", channelName: "Wrong account",
      event: try f.signer.sign(kind: 9021, content: "", tags: [["h", "c"]]))
    await #expect(throws: BuzzError.invalidEvent) { try await store.saveMembership(wrongOwner) }
    let request = try f.request(joining: true)
    try await store.saveMembership(request)
    let relay = MembershipRelay(signer: f.signer, user: f.user, store: store)
    let partition = try #require(
      FileManager.default.contentsOfDirectory(at: f.root, includingPropertiesForKeys: nil).first)
    let backup = f.root.appendingPathComponent("backup")
    try FileManager.default.moveItem(at: partition, to: backup)
    try Data().write(to: partition)
    await #expect(throws: (any Error).self) {
      try await MembershipManager(store: store, relay: relay).synchronize()
    }
    #expect(await relay.published.isEmpty)
    #expect(await store.intentSnapshot().memberships == [request])
    try FileManager.default.removeItem(at: partition)
    try FileManager.default.moveItem(at: backup, to: partition)
    let reopened = try f.store()
    #expect(await reopened.intentSnapshot().memberships == [request])
    let recoveredRelay = MembershipRelay(signer: f.signer, user: f.user, store: reopened)
    try await MembershipManager(store: reopened, relay: recoveredRelay).synchronize()
    #expect(await recoveredRelay.published == [request.id])
    #expect(await reopened.intentSnapshot().memberships.isEmpty)
  }

  @Test func lostAcceptanceIsReconciledAfterRestartWithoutReplayingJoin() async throws {
    let f = try MembershipFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let store = try f.store()
    let relay = MembershipRelay(signer: f.signer, user: f.user, store: store)
    await relay.configure(lostAck: true)
    let request = try f.request(joining: true)
    try await store.saveMembership(request)
    try await MembershipManager(store: store, relay: relay).synchronize()
    let pending = await store.intentSnapshot().memberships
    #expect(pending.count == 1)
    #expect(pending.first?.phase == .checking)
    #expect(pending.first?.failure != nil)
    let reopened = try f.store()
    try await MembershipManager(store: reopened, relay: relay).synchronize()
    #expect(await reopened.intentSnapshot().memberships.isEmpty)
    #expect(await relay.published == [request.id])
    #expect(await reopened.relayAuthority() == f.signer.pubkey)
  }

  @Test func acceptanceAloneAndEmptyOrForgedSnapshotsNeverProveMembership() async throws {
    let f = try MembershipFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let store = try f.store()
    let relay = MembershipRelay(signer: f.signer, user: f.user, store: store)
    await relay.configure(noEffect: true)
    let request = try f.request(joining: true)
    try await store.saveMembership(request)
    let manager = MembershipManager(store: store, relay: relay)
    try await manager.synchronize()
    #expect(await store.intentSnapshot().memberships.count == 1)
    await relay.override([])
    try await manager.synchronize()
    #expect(await store.intentSnapshot().memberships.count == 1)
    let forged = try f.user.sign(
      kind: 39002, content: "", tags: [["d", "c"], ["p", f.user.pubkey]], at: 40)
    await relay.override([forged])
    try await manager.synchronize()
    #expect(await store.intentSnapshot().memberships.count == 1)
    #expect(await relay.published.count == 1)
  }

  @Test func staleSnapshotCannotConfirmLeaveOrOverwriteANewerRoster() async throws {
    let f = try MembershipFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let store = try f.store()
    let current = try f.signer.sign(
      kind: 39002, content: "", tags: [["d", "c"], ["p", f.user.pubkey]], at: 100)
    try await store.ingest([current])
    let relay = MembershipRelay(signer: f.signer, user: f.user, store: store)
    await relay.configure(noEffect: true)
    let old = try f.signer.sign(kind: 39002, content: "", tags: [["d", "c"]], at: 99)
    await relay.override([old])
    try await store.saveMembership(f.request(joining: false))
    try await MembershipManager(store: store, relay: relay).synchronize()
    #expect(await store.intentSnapshot().memberships.count == 1)
    #expect(await store.cachedEvents() == [current])
  }

  @Test func explicitNewAttemptPreservesDraftsAndRequiresNewUserIntent() async throws {
    let f = try MembershipFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let store = try f.store()
    try await store.saveDraft("keep this", key: "c/timeline")
    let relay = MembershipRelay(signer: f.signer, user: f.user, store: store)
    await relay.configure(noEffect: true)
    let first = try f.request(joining: true)
    try await store.saveMembership(first)
    let manager = MembershipManager(store: store, relay: relay)
    try await manager.synchronize()
    let second = try f.request(joining: true)
    await #expect(throws: BuzzError.self) { try await store.saveMembership(second) }
    try await store.saveMembership(second, replacing: first.id)
    await relay.configure(noEffect: false)
    try await manager.synchronize()
    #expect(await relay.published == [first.id, second.id])
    #expect(await store.intentSnapshot().memberships.isEmpty)
    #expect(await store.intentSnapshot().drafts["c/timeline"] == "keep this")
    let old = try JSONDecoder().decode(
      IntentSnapshot.self, from: Data("{\"drafts\":{\"c\":\"old draft\"},\"pending\":[]}".utf8))
    #expect(old.memberships.isEmpty)
    #expect(old.drafts["c"] == "old draft")
  }

  @Test func directoryUsesCompositeCursorAndRejectsUntrustedOrPrivateChannels() async throws {
    let f = try MembershipFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let store = try f.store()
    let relay = MembershipRelay(signer: f.signer, user: f.user, store: store)
    let metadata = try (0..<205).map { index in
      try f.signer.sign(
        kind: 39000, content: "",
        tags: [["d", "\(index)"], ["name", "Channel \(index)"], ["t", "stream"]], at: 10)
    }
    await relay.directory(metadata)
    var cursor: DirectoryCursor?
    var ids = Set<String>()
    for _ in 0..<4 {
      let page = try await DirectoryPage.fetch(
        relay: relay, authority: f.signer.pubkey, after: cursor)
      ids.formUnion(page.events.map(\.id))
      cursor = page.next
    }
    #expect(ids.count == 205)
    #expect(cursor == nil)
    let first = try await DirectoryPage.fetch(relay: relay, authority: f.signer.pubkey, after: nil)
    await relay.ignoreCursor()
    await #expect(throws: BuzzError.invalidResponse) {
      try await DirectoryPage.fetch(relay: relay, authority: f.signer.pubkey, after: first.next)
    }
    let privateChannel = try f.signer.sign(
      kind: 39000, content: "", tags: [["d", "private"], ["private"]])
    let dm = try f.signer.sign(
      kind: 39000, content: "", tags: [["d", "dm"], ["hidden"], ["t", "dm"]])
    let archived = try f.signer.sign(
      kind: 39000, content: "", tags: [["d", "archived"], ["archived", "true"]])
    let fake = try f.user.sign(kind: 39000, content: "", tags: [["d", "forged"]])
    #expect(
      Projection.directory(
        events: metadata + [privateChannel, dm, archived, fake], relayPubkey: f.signer.pubkey
      ).count == 205)
  }

  @Test(.timeLimit(.minutes(1))) func cacheEvictionPinsJoinedMetadataAndNeverRevivesOldMembership()
    async throws
  {
    let f = try MembershipFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let store = try f.store()
    try await store.setRelayAuthority(f.signer.pubkey)
    let meta = try f.signer.sign(
      kind: 39000, content: "", tags: [["d", "c"], ["name", "Joined"]], at: 1)
    let member = try f.signer.sign(
      kind: 39002, content: "", tags: [["d", "c"], ["p", f.user.pubkey]], at: 2)
    try await store.ingest([meta, member])
    for batch in 0..<3 {
      let size = batch == 2 ? 1 : 5000
      let messages = try (0..<size).map { index in
        try f.user.sign(
          kind: 9, content: "cached", tags: [["h", "c"]], at: 10 + batch * 5000 + index)
      }
      try await store.ingest(messages)
    }
    let cached = await store.cachedEvents()
    #expect(cached.count == 10_000)
    #expect(Projection.channels(events: cached, pubkey: f.user.pubkey).map(\.id) == ["c"])
    // A page must not save a newer row while silently evicting its old auxiliary event.
    let row = try f.user.sign(kind: 9, content: "New page", tags: [["h", "c"]], at: 30_000)
    let aux = try f.user.sign(kind: 7, content: "👍", tags: [["e", row.id]], at: 3)
    await #expect(throws: (any Error).self) {
      try await store.ingest([row, aux], requiring: [row.id, aux.id])
    }
    #expect(Set(await store.cachedEvents().map(\.id)) == Set(cached.map(\.id)))
    let reopened = try f.store()
    #expect(Set(await reopened.cachedEvents().map(\.id)) == Set(cached.map(\.id)))
    let departed = try f.signer.sign(kind: 39002, content: "", tags: [["d", "c"]], at: 20_000)
    try await store.ingest([departed, member])
    #expect(await store.cachedEvents().filter { $0.kind == 39002 }.map(\.id) == [departed.id])
    #expect(await store.intentSnapshot().memberships.isEmpty)
  }
}

private struct MembershipFixture {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let signer: Identity
  let user: Identity
  let community: Community
  init() throws {
    signer = try Identity(hex: String(repeating: "0", count: 63) + "1")
    user = try Identity(hex: String(repeating: "0", count: 63) + "2")
    community = try Community(url: "https://membership.example", name: "Test")
  }
  func store() throws -> LocalStore {
    try LocalStore(directory: root, community: community, pubkey: user.pubkey)
  }
  func request(joining: Bool) throws -> MembershipRequest {
    MembershipRequest(
      channelID: "c", channelName: "Test channel",
      event: try user.sign(
        kind: joining ? 9021 : 9022, content: "",
        tags: [["h", "c"], ["nonce", UUID().uuidString]], at: 20))
  }
}

private actor MembershipRelay: RelayTransport {
  let signer: Identity
  let user: Identity
  let store: LocalStore
  var published: [String] = []
  private var lostAck = false
  private var noEffect = false
  private var joined = false
  private var overriding: [Event]?
  private var metadata: [Event] = []
  private var ignoringCursor = false
  init(signer: Identity, user: Identity, store: LocalStore) {
    self.signer = signer
    self.user = user
    self.store = store
  }
  func configure(lostAck: Bool = false, noEffect: Bool = false) {
    self.lostAck = lostAck
    self.noEffect = noEffect
  }
  func override(_ events: [Event]) { overriding = events }
  func directory(_ events: [Event]) { metadata = events }
  func ignoreCursor() { ignoringCursor = true }
  func authority() -> String { signer.pubkey }
  func query(_ filters: [EventFilter]) throws -> [Event] {
    let filter = try #require(filters.first)
    #expect(filter.authors == [signer.pubkey])
    if filter.kinds == [39000] {
      let encoded = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(filter)) as? [String: Any])
      #expect(encoded["before_id"] as? String == filter.beforeID)
      return Array(
        metadata.filter { event in
          ignoringCursor
            || (filter.beforeID.map {
              event.createdAt < (filter.until ?? Int.max)
                || (event.createdAt == filter.until && event.id > $0)
            }
              ?? true)
        }.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt }
          .prefix(filter.limit))
    }
    #expect(filter.tags == ["d": ["c"]])
    if let overriding { return overriding }
    return [
      try signer.sign(
        kind: 39002, content: "", tags: [["d", "c"]] + (joined ? [["p", user.pubkey]] : []), at: 30)
    ]
  }
  func publish(_ event: Event) async throws {
    #expect(
      await store.intentSnapshot().memberships.first { $0.id == event.id }?.phase == .checking)
    #expect(event.hasValidIDAndSignature())
    published.append(event.id)
    if !noEffect { joined = event.kind == 9021 }
    if lostAck { throw BuzzError.http(503) }
  }
}
