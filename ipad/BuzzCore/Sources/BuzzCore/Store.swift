import CryptoKit
import Foundation

/// A user's pending, already signed action. Failures retain the exact event for retry.
public struct PendingAction: Codable, Identifiable, Equatable, Sendable {
  /// The stable event ID reused for every delivery attempt.
  public var id: String { event.id }
  /// Original signed bytes represented as a canonical event.
  public let event: Event
  /// Last attempt’s visible failure, retained across launches.
  public var failure: String?
}

/// Durable user intent, isolated from disposable relay data.
public struct IntentSnapshot: Codable, Equatable, Sendable {
  /// Drafts keyed by channel and containing thread.
  public var drafts: [String: String] = [:]
  /// Signed actions that have not been durably acknowledged.
  public var pending: [PendingAction] = []
  /// Membership commands use explicit verification and never automatic message-outbox replay.
  public var memberships: [MembershipRequest] = []
  /// Device-local emoji usage, scoped to this community and identity.
  public var recentEmoji: [EmojiUsage] = []
  /// Starts an empty intent journal.
  public init() {}

  private enum CodingKeys: String, CodingKey { case drafts, pending, memberships, recentEmoji }

  /// Preserves journals from before membership commands were introduced.
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    drafts = try values.decodeIfPresent([String: String].self, forKey: .drafts) ?? [:]
    pending = try values.decodeIfPresent([PendingAction].self, forKey: .pending) ?? []
    memberships = try values.decodeIfPresent([MembershipRequest].self, forKey: .memberships) ?? []
    recentEmoji = try values.decodeIfPresent([EmojiUsage].self, forKey: .recentEmoji) ?? []
  }
}

/// Community-and-identity-scoped storage. All mutations replace one atomic snapshot.
public actor LocalStore {
  private let journalURL: URL
  private let cacheURL: URL
  private let authorityURL: URL
  private var authority: String?
  private let ownerPubkey: String
  private var intents: IntentSnapshot
  private var events: [String: Event]
  private static let maximumCacheEvents = 10_000

  /// Opens a store without silently discarding corrupt or inaccessible user intent.
  public init(directory: URL, community: Community, pubkey: String) throws {
    ownerPubkey = pubkey
    let partition = Hex.encode(SHA256.hash(data: Data((community.id + "\n" + pubkey).utf8)))
    let root = directory.appendingPathComponent(partition, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    journalURL = root.appendingPathComponent("intent-v1.json")
    cacheURL = root.appendingPathComponent("events-v1.json")
    authorityURL = root.appendingPathComponent("authority-v1.json")
    if FileManager.default.fileExists(atPath: authorityURL.path) {
      authority = try JSONDecoder().decode(String.self, from: Data(contentsOf: authorityURL))
    }
    if FileManager.default.fileExists(atPath: journalURL.path) {
      intents = try JSONDecoder().decode(IntentSnapshot.self, from: Data(contentsOf: journalURL))
    } else {
      intents = IntentSnapshot()
    }
    if FileManager.default.fileExists(atPath: cacheURL.path) {
      let saved = try JSONDecoder().decode([Event].self, from: Data(contentsOf: cacheURL))
      events = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    } else {
      events = [:]
    }
  }

  /// Returns durable drafts and pending sends.
  public func intentSnapshot() -> IntentSnapshot { intents }
  /// Returns the verified local event cache.
  public func cachedEvents() -> [Event] { Array(events.values) }

  /// The last successfully fetched signing identity for offline membership projection.
  public func relayAuthority() -> String? { authority }

  /// Pins the NIP-11 signing identity to this community's cache partition.
  public func setRelayAuthority(_ key: String) throws {
    guard key.utf8.count == 64, Hex.decode(key)?.count == 32 else { throw BuzzError.invalidKey }
    try Self.write(key, to: authorityURL)
    authority = key
  }

  /// Persists a new explicit membership action, optionally replacing a user-retried request.
  public func saveMembership(_ request: MembershipRequest, replacing: String? = nil) throws {
    guard [9021, 9022].contains(request.event.kind), request.event.hasValidIDAndSignature(),
      request.event.tag("h") == request.channelID, request.event.pubkey == ownerPubkey
    else { throw BuzzError.invalidEvent }
    var next = intents
    if let replacing,
      !next.memberships.contains(where: { $0.id == replacing && $0.channelID == request.channelID })
    {
      throw BuzzError.rejected("This membership request has already been resolved")
    }
    if let existing = next.memberships.first(where: { $0.channelID == request.channelID }),
      existing.id != replacing
    {
      throw BuzzError.rejected("Resolve the existing membership request first")
    }
    next.memberships.removeAll { $0.id == replacing }
    guard next.memberships.count < 100 else { throw BuzzError.capacity }
    next.memberships.append(request)
    try commit(next)
  }

  /// Updates only the still-current request; a stale response cannot replace a newer intent.
  public func updateMembership(id: String, phase: MembershipRequest.Phase, failure: String?) throws
  {
    var next = intents
    guard let index = next.memberships.firstIndex(where: { $0.id == id }) else { return }
    next.memberships[index].phase = phase
    next.memberships[index].failure = failure.map { String($0.prefix(1000)) }
    try commit(next)
  }

  /// Removes a verified or explicitly dismissed request without altering drafts or messages.
  public func removeMembership(id: String) throws {
    var next = intents
    next.memberships.removeAll { $0.id == id }
    try commit(next)
  }

  /// Persists a draft before reporting it saved.
  public func saveDraft(_ text: String, key: String) throws {
    var next = intents
    next.drafts[key] = text.isEmpty ? nil : text
    try commit(next)
  }

  /// Atomically moves a draft to the outbox. Failure leaves the original draft intact.
  public func enqueue(
    _ event: Event, replacingDraft key: String? = nil,
    expectedDraft: String? = nil, recordingReaction: String? = nil
  ) throws {
    guard
      [0, 5, 7, 9, 9000, 9002, 9007, 9008, 24810, 30078, 30315, 40003, 45001, 45003, 48100, 48103]
        .contains(event.kind),
      event.hasValidIDAndSignature()
    else { throw BuzzError.invalidEvent }
    var next = intents
    if !next.pending.contains(where: { $0.id == event.id }) {
      guard next.pending.count < 1000 else { throw BuzzError.capacity }
      next.pending.append(PendingAction(event: event))
      if let value = recordingReaction {
        guard event.kind == 7, ReactionProjection.value(event.content) == value else {
          throw BuzzError.invalidEvent
        }
        next.recentEmoji = EmojiUsage.recording(
          value, in: next.recentEmoji,
          at: Int(Date().timeIntervalSince1970 * 1000))
      }
    }
    // A slow signing operation must never erase newer typing.
    if let key, next.drafts[key] == expectedDraft { next.drafts.removeValue(forKey: key) }
    try commit(next)
  }

  /// Records a delivery failure without deleting retry material.
  public func recordFailure(id: String, message: String) throws {
    var next = intents
    guard let index = next.pending.firstIndex(where: { $0.id == id }) else { return }
    next.pending[index].failure = String(message.prefix(1000))
    try commit(next)
  }

  /// Caches accepted data first; then removes retry material. Every crash prefix is recoverable.
  public func acknowledge(_ event: Event) throws {
    try ingest([event])
    var next = intents
    next.pending.removeAll { $0.id == event.id }
    try commit(next)
  }

  /// Verifies newly received events before committing them to the bounded cache.
  /// Required IDs make a history page indivisible: eviction may not discard its overlays.
  public func ingest(_ incoming: [Event], requiring requiredIDs: Set<String> = []) throws {
    guard incoming.count <= 5000 else { throw BuzzError.responseTooLarge }
    var next = events
    for event in incoming where next[event.id] == nil {
      guard event.hasValidIDAndSignature() else { throw BuzzError.invalidEvent }
      next[event.id] = event
    }
    // Superseded membership snapshots must not reappear after cache eviction.
    var latest: [String: Event] = [:]
    for event in next.values where [39000, 39002, 30030, 30078, 30315].contains(event.kind) {
      guard let channel = event.tag("d") else { continue }
      let key = "\(event.pubkey)/\(event.kind)/\(channel)"
      if let old = latest[key],
        old.createdAt > event.createdAt
          || (old.createdAt == event.createdAt && old.id < event.id)
      {
        next.removeValue(forKey: event.id)
      } else {
        if let old = latest[key] { next.removeValue(forKey: old.id) }
        latest[key] = event
      }
    }
    if next.count > Self.maximumCacheEvents {
      let rosters = next.values.filter {
        $0.kind == 39002 && $0.pubkey == authority
          && $0.tags.contains { $0.count >= 2 && $0[0] == "p" && $0[1] == ownerPubkey }
      }
      let joined = Set(rosters.compactMap { $0.tag("d") })
      let pinned =
        rosters
        + next.values.filter {
          $0.kind == 39000 && $0.pubkey == authority && joined.contains($0.tag("d") ?? "")
        }
      guard pinned.count <= Self.maximumCacheEvents else { throw BuzzError.capacity }
      let pinnedIDs = Set(pinned.map(\.id))
      let retained =
        pinned
        + next.values.filter { !pinnedIDs.contains($0.id) }
        .sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
        .prefix(Self.maximumCacheEvents - pinned.count)
      next = Dictionary(uniqueKeysWithValues: retained.map { ($0.id, $0) })
    }
    guard requiredIDs.isSubset(of: Set(next.keys)) else {
      throw BuzzError.storage(
        "This history page could not fit in the local cache. Refresh to return to recent messages.")
    }
    try Self.write(Array(next.values), to: cacheURL)
    events = next
  }

  private func commit(_ next: IntentSnapshot) throws {
    guard next.drafts.count <= 1000,
      next.drafts.values.reduce(0, { $0 + $1.utf8.count }) <= 8 * 1024 * 1024
    else {
      throw BuzzError.capacity
    }
    guard try JSONEncoder().encode(next).count <= 16 * 1024 * 1024 else {
      throw BuzzError.capacity
    }
    try Self.write(next, to: journalURL)
    intents = next
  }

  private static func write(_ value: some Encodable, to url: URL) throws {
    let data = try JSONEncoder().encode(value)
    #if os(iOS)
      try data.write(
        to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    #else
      try data.write(to: url, options: .atomic)
    #endif
  }
}

/// Serial, bounded delivery of durable actions; retries always reuse the original signed event.
public actor Outbox {
  private let store: LocalStore
  private let relay: any RelayTransport
  private var sending = false
  private var rerun = false

  /// Binds one community store to its matching authenticated transport.
  public init(store: LocalStore, relay: any RelayTransport) {
    self.store = store
    self.relay = relay
  }

  /// Attempts each queued action once. Call on explicit retry or a later successful reconnect.
  ///
  /// A failed action keeps its error and stays queued, but does not hold back
  /// the actions after it: a relay that permanently rejects one event must not
  /// stall every later send. The first error is rethrown once all were tried.
  /// A flush requested while one is running runs again afterwards, so an
  /// action queued mid-flush is not left waiting for the next retry.
  public func flush() async throws {
    guard !sending else {
      rerun = true
      return
    }
    sending = true
    defer { sending = false }
    var firstError: (any Error)?
    repeat {
      rerun = false
      let snapshot = await store.intentSnapshot()
      for action in snapshot.pending {
        try Task.checkCancellation()
        do {
          try await relay.publish(action.event)
        } catch {
          try await store.recordFailure(id: action.id, message: error.localizedDescription)
          firstError = firstError ?? error
          continue
        }
        try await store.acknowledge(action.event)
      }
    } while rerun
    if let firstError { throw firstError }
  }
}
