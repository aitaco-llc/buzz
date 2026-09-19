import Foundation

/// A durable join/leave intent whose completion requires a relay-authored membership snapshot.
public struct MembershipRequest: Codable, Identifiable, Equatable, Sendable {
  /// Whether this request has crossed the point at which sending may have occurred.
  public enum Phase: String, Codable, Sendable { case queued, checking }
  /// Identity of this particular user-authorized attempt.
  public var id: String { event.id }
  /// Channel referenced by the signed command's h tag.
  public let channelID: String
  /// Display name retained while the channel is inaccessible.
  public let channelName: String
  /// Original signed command, retained across process death.
  public let event: Event
  /// Queued commands may be sent once; checking commands are never automatically replayed.
  public var phase: Phase = .queued
  /// The last visible network, authorization or verification failure.
  public var failure: String?
  /// The desired membership state.
  public var joining: Bool { event.kind == 9021 }

  /// Creates a request from an already-signed join or leave command.
  public init(channelID: String, channelName: String, event: Event) {
    self.channelID = channelID
    self.channelName = channelName
    self.event = event
  }
}

/// Separates command delivery from authoritative membership verification.
public actor MembershipManager {
  private let store: LocalStore
  private let relay: any RelayTransport
  private var working = false

  /// Binds membership reconciliation to one identity/community store and transport.
  public init(store: LocalStore, relay: any RelayTransport) {
    self.store = store
    self.relay = relay
  }

  /// Sends untouched queued requests once, then checks their actual membership effect.
  public func synchronize() async throws {
    guard !working else { return }
    working = true
    defer { working = false }
    let requests = await store.intentSnapshot().memberships
    for request in requests {
      try Task.checkCancellation()
      if request.phase == .queued {
        // Persist before crossing the network boundary. A crash leaves an ambiguous
        // request to reconcile, never a command that gets replayed automatically.
        try await store.updateMembership(id: request.id, phase: .checking, failure: nil)
        do { try await relay.publish(request.event) } catch {
          try await store.updateMembership(
            id: request.id, phase: .checking, failure: error.localizedDescription)
          continue
        }
      }
      do {
        let authority = try await relay.authority()
        try await store.setRelayAuthority(authority)
        let responses = try await relay.query([
          EventFilter(
            kinds: [39002], authors: [authority], tags: ["d": [request.channelID]], limit: 10)
        ])
        let candidates = responses.filter {
          $0.kind == 39002 && $0.pubkey == authority && $0.tag("d") == request.channelID
            && $0.hasValidIDAndSignature()
        }.sorted {
          $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt
        }
        guard let roster = candidates.first else {
          throw BuzzError.rejected(
            "Membership could not be verified. Check status again; an empty response is not confirmation."
          )
        }
        let cached = await store.cachedEvents().filter {
          $0.kind == 39002 && $0.pubkey == authority && $0.tag("d") == request.channelID
        }
        guard
          !cached.contains(where: {
            $0.createdAt > roster.createdAt
              || ($0.createdAt == roster.createdAt && $0.id < roster.id)
          })
        else {
          throw BuzzError.rejected(
            "The relay returned an older membership snapshot. Check status again.")
        }
        try await store.ingest([roster])
        let joined = roster.tags.contains {
          $0.count >= 2 && $0[0] == "p" && $0[1] == request.event.pubkey
        }
        guard joined == request.joining else {
          throw BuzzError.rejected(
            "The requested membership change is not confirmed. Check status or explicitly send a new request."
          )
        }
        try await store.removeMembership(id: request.id)
      } catch {
        try await store.updateMembership(
          id: request.id, phase: .checking, failure: error.localizedDescription)
      }
    }
  }
}

/// A composite cursor for Buzz directory pages, including equal-timestamp events.
public typealias DirectoryCursor = EventCursor

/// A validated, bounded directory page. The next empty page marks the end.
public struct DirectoryPage: Sendable {
  /// Relay-authored metadata accepted from this page.
  public let events: [Event]
  /// Cursor to request the next page, or nil after an empty response.
  public let next: DirectoryCursor?

  /// Reads one page and rejects relays that ignore or regress the requested cursor.
  public static func fetch(
    relay: any RelayTransport, authority: String, after cursor: DirectoryCursor?
  ) async throws -> DirectoryPage {
    try await fetch(relay: relay, authority: authority, kinds: [39000], tags: [:], after: cursor)
  }

  static func fetch(
    relay: any RelayTransport, authority: String, kinds: [Int], tags: [String: [String]],
    after cursor: DirectoryCursor?
  ) async throws -> DirectoryPage {
    let events = try await relay.query([
      EventFilter(
        kinds: kinds, authors: [authority], tags: tags, until: cursor?.timestamp,
        beforeID: cursor?.eventID, limit: 100)
    ])
    guard events.count <= 100,
      events.allSatisfy({ event in
        kinds.contains(event.kind) && event.pubkey == authority && event.hasValidIDAndSignature()
          && tags.allSatisfy { key, values in
            event.tags.contains { $0.count >= 2 && $0[0] == key && values.contains($0[1]) }
          }
          && (cursor?.containsOlder(event) ?? true)
      })
    else { throw BuzzError.invalidResponse }
    let ordered = events.sorted(by: EventCursor.relayOrder)
    return DirectoryPage(
      events: ordered,
      next: ordered.last.map { EventCursor(event: $0) })
  }
}

/// Discovers all joined channels within bounded pages, retaining cached content on failure.
public enum ChannelDiscovery {
  /// Refreshes membership and metadata using the relay's NIP-11 signing authority.
  /// An empty page never deletes cached memberships: absence is not a signed revocation.
  public static func refresh(store: LocalStore, relay: any RelayTransport, pubkey: String)
    async throws
  {
    let authority = try await relay.authority()
    try await store.setRelayAuthority(authority)
    var ids = Set(
      await store.cachedEvents().filter { $0.kind == 39002 && $0.pubkey == authority }
        .compactMap { $0.tag("d") })
    try await collect(
      store: store, relay: relay, authority: authority, kinds: [39002], tags: ["p": [pubkey]],
      channelIDs: &ids)
    let ordered = ids.sorted()
    for offset in stride(from: 0, to: ordered.count, by: 100) {
      try Task.checkCancellation()
      let batch = Array(ordered[offset..<min(ordered.count, offset + 100)])
      var discovered = Set<String>()
      try await collect(
        store: store, relay: relay, authority: authority, kinds: [39000, 39002],
        tags: ["d": batch], channelIDs: &discovered)
    }
  }

  private static func collect(
    store: LocalStore, relay: any RelayTransport, authority: String, kinds: [Int],
    tags: [String: [String]], channelIDs: inout Set<String>
  ) async throws {
    var cursor: DirectoryCursor?
    // At most 10,000 events plus the final empty page; a misbehaving or enormous
    // relay ends with a visible error instead of an unbounded background loop.
    for pageNumber in 0...100 {
      try Task.checkCancellation()
      let page = try await DirectoryPage.fetch(
        relay: relay, authority: authority, kinds: kinds, tags: tags, after: cursor)
      if page.events.isEmpty { return }
      guard pageNumber < 100 else { throw BuzzError.capacity }
      try Task.checkCancellation()
      try await store.ingest(page.events)
      channelIDs.formUnion(page.events.compactMap { $0.tag("d") })
      guard channelIDs.count <= 10_000 else { throw BuzzError.capacity }
      cursor = page.next
    }
  }
}
