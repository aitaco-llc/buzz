import Foundation
import Testing

@testable import BuzzCore

struct ChannelDiscoveryTests {
  @Test func joinedChannelsBeyondOnePageAndEqualTimestampsAreAllDiscovered() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let user = try Identity(hex: String(repeating: "0", count: 63) + "1")
    let signer = try Identity(hex: String(repeating: "0", count: 63) + "2")
    let community = try Community(url: "https://discovery.example", name: "Test")
    let store = try LocalStore(directory: directory, community: community, pubkey: user.pubkey)
    var events: [Event] = []
    for index in 0..<505 {
      events.append(
        try signer.sign(
          kind: 39002, content: "", tags: [["d", "c\(index)"], ["p", user.pubkey]], at: 10))
      events.append(
        try signer.sign(
          kind: 39000, content: "", tags: [["d", "c\(index)"], ["name", "Channel \(index)"]], at: 10
        ))
    }
    let old = try signer.sign(
      kind: 39002, content: "", tags: [["d", "departed"], ["p", user.pubkey]], at: 9)
    try await store.ingest([old])
    let revoked = try signer.sign(kind: 39002, content: "", tags: [["d", "departed"]], at: 10)
    events.append(revoked)
    let relay = DiscoveryRelay(signer: signer, events: events)
    try await ChannelDiscovery.refresh(store: store, relay: relay, pubkey: user.pubkey)
    let cached = await store.cachedEvents()
    #expect(Projection.channels(events: cached, pubkey: user.pubkey).count == 505)
    #expect(cached.contains(revoked))
    #expect(!cached.contains(old))
    #expect(await store.relayAuthority() == signer.pubkey)
    // Six membership pages, their terminating empty page, and batched metadata pages.
    #expect(await relay.requests > 7)

    await relay.returnEmpty()
    try await ChannelDiscovery.refresh(store: store, relay: relay, pubkey: user.pubkey)
    #expect(await store.cachedEvents().count == cached.count)
    let reopened = try LocalStore(directory: directory, community: community, pubkey: user.pubkey)
    #expect(await reopened.relayAuthority() == signer.pubkey)
    #expect(
      Projection.channels(events: await reopened.cachedEvents(), pubkey: user.pubkey).count == 505)
  }

  @Test func discoveryRejectsAuthorScopeAndCursorViolationsWithoutLosingCachedData() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let user = try Identity(hex: String(repeating: "0", count: 63) + "1")
    let signer = try Identity(hex: String(repeating: "0", count: 63) + "2")
    let store = try LocalStore(
      directory: directory, community: Community(url: "https://discovery.example", name: "Test"),
      pubkey: user.pubkey)
    let member = try signer.sign(
      kind: 39002, content: "", tags: [["d", "c"], ["p", user.pubkey]], at: 10)
    try await store.ingest([member])
    let relay = DiscoveryRelay(signer: signer, events: [])
    let forged = try user.sign(
      kind: 39002, content: "", tags: [["d", "fake"], ["p", user.pubkey]], at: 11)
    await relay.override([forged])
    await #expect(throws: BuzzError.invalidResponse) {
      try await ChannelDiscovery.refresh(store: store, relay: relay, pubkey: user.pubkey)
    }
    let unrelated = try signer.sign(kind: 39002, content: "", tags: [["d", "other"]], at: 11)
    await relay.override([unrelated])
    await #expect(throws: BuzzError.invalidResponse) {
      try await ChannelDiscovery.refresh(store: store, relay: relay, pubkey: user.pubkey)
    }
    await relay.override([member])
    await #expect(throws: BuzzError.invalidResponse) {
      try await ChannelDiscovery.refresh(store: store, relay: relay, pubkey: user.pubkey)
    }
    #expect(await store.cachedEvents() == [member])
  }
}

private actor DiscoveryRelay: RelayTransport {
  let signer: Identity
  var events: [Event]
  var requests = 0
  private var overridden: [Event]?
  init(signer: Identity, events: [Event]) {
    self.signer = signer
    self.events = events
  }
  func returnEmpty() { events = [] }
  func override(_ value: [Event]) { overridden = value }
  func authority() -> String { signer.pubkey }
  func publish(_ event: Event) throws { throw BuzzError.invalidEvent }
  func query(_ filters: [EventFilter]) throws -> [Event] {
    let filter = try #require(filters.first)
    #expect(filters.count == 1)
    #expect(filter.authors == [signer.pubkey])
    #expect(filter.limit <= 100)
    requests += 1
    if let overridden { return overridden }
    return Array(
      events.filter { event in
        filter.kinds.contains(event.kind)
          && filter.tags.allSatisfy { key, values in
            event.tags.contains { $0.count >= 2 && $0[0] == key && values.contains($0[1]) }
          }
          && (filter.beforeID.map {
            event.createdAt < (filter.until ?? Int.max)
              || (event.createdAt == filter.until && event.id > $0)
          }
            ?? true)
      }.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt }
        .prefix(filter.limit))
  }
}
