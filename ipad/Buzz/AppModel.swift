import BuzzCore
import BuzzPushKit
import Foundation
import Observation

struct TypingIndicator: Equatable, Sendable {
  let pubkey: String
  let rootID: String?
  let expiresAt: Date
}

struct BuzzDeepLink: Equatable, Sendable {
  let channelID: String
  let eventID: String

  var url: URL? {
    var components = URLComponents()
    components.scheme = "buzz"
    components.host = "message"
    components.queryItems = [
      URLQueryItem(name: "channel", value: channelID),
      URLQueryItem(name: "id", value: eventID),
    ]
    return components.url
  }
}

struct HuddleSessionInfo: Identifiable, Equatable, Sendable {
  let id: String
  let parentChannelID: String
  let ephemeralChannelID: String
  let startedAt: Int
}

@MainActor @Observable
final class AppModel {
  var accounts: [Account] = []
  var workspace: Workspace?
  var error: String?
  var opening = false
  var pendingDeepLink: BuzzDeepLink?
  var pendingInvite: InviteLink?
  private var generation = UUID()
  private let directory: URL

  init() {
    directory = URL.applicationSupportDirectory.appendingPathComponent(
      "BuzzNative", isDirectory: true)
  }

  func start() async {
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
        // Signed out: the welcome and connection screens, with no community.
        if ProcessInfo.processInfo.arguments.contains("--signed-out") { return }
        do { workspace = try await Demo.workspace() } catch {
          self.error = error.localizedDescription
        }
        return
      }
    #endif
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let url = directory.appendingPathComponent("accounts.json")
      accounts = try Credentials.accounts()
      if FileManager.default.fileExists(atPath: url.path) {
        let legacy = try JSONDecoder().decode([Account].self, from: Data(contentsOf: url))
        for account in legacy where !accounts.contains(where: { $0.id == account.id }) {
          try Credentials.save(Credentials.load(account: account.id), account: account)
          accounts.append(account)
        }
        // Each account is now independently discoverable from its atomic Keychain record.
        try FileManager.default.removeItem(at: url)
      }
      if let account = accounts.first(where: { Aitaco.allows($0.community) }) {
        await open(account)
      }
    } catch { self.error = error.localizedDescription }
  }

  func handle(url: URL) {
    if let invite = InviteLink.parse(url) {
      guard (try? Aitaco.require(Community(url: invite.relay.absoluteString, name: ""))) != nil
      else {
        error = Aitaco.foreignCommunityMessage
        return
      }
      pendingInvite = invite
      return
    }
    guard url.scheme?.lowercased() == "buzz", url.host?.lowercased() == "message",
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let channel = components.queryItems?.first(where: { $0.name == "channel" })?.value,
      let event = components.queryItems?.first(where: { $0.name == "id" })?.value,
      !channel.isEmpty, !event.isEmpty
    else { return }
    pendingDeepLink = BuzzDeepLink(channelID: channel, eventID: event)
  }

  func handle(notification target: BuzzPushNavigationTarget) {
    guard !target.eventID.isEmpty, !target.communityID.isEmpty, !target.channelID.isEmpty else {
      return
    }
    pendingDeepLink = BuzzDeepLink(channelID: target.channelID, eventID: target.eventID)
  }

  /// Claims a relay invite with a newly generated identity and persists the
  /// account only after the relay has accepted the claim.
  func claim(invite: InviteLink) async throws -> Account {
    let community = try Aitaco.require(
      Community(url: invite.relay.absoluteString, name: invite.host))
    let identity = try Identity()
    let relay = HTTPRelay(community: community, identity: identity)
    let body = try JSONSerialization.data(withJSONObject: ["code": invite.code])
    let response = try await relay.postJSON(path: "api/invites/claim", body: body)
    let object = try JSONSerialization.jsonObject(with: response) as? [String: Any]
    let name =
      (object?["community_name"] as? String)
      ?? (object?["name"] as? String)
      ?? invite.host
    let namedCommunity = try Community(url: community.origin.absoluteString, name: name)
    return try save(community: namedCommunity, identity: identity)
  }

  func add(url: String, name: String, privateKey: String, authTag: String) async -> Bool {
    do {
      let community = try Community(url: url, name: name)
      let identity = try Identity(encoded: privateKey)
      let account = try save(community: community, identity: identity, authTag: authTag)
      await open(account)
      return workspace?.account.id == account.id
    } catch {
      self.error = error.localizedDescription
      return false
    }
  }

  // A pairing session acknowledges only this durable result, independent of opening the UI.
  func save(community: Community, identity: Identity, authTag: String = "") throws -> Account {
    let community = try Aitaco.require(community)
    let account =
      accounts.first { $0.community.id == community.id && $0.pubkey == identity.pubkey }
      ?? Account(id: UUID(), community: community, pubkey: identity.pubkey)
    try Credentials.save(
      Credential(
        privateKey: identity.privateKeyHex,
        authTag: authTag.isEmpty ? nil : authTag), account: account)
    var next = accounts.filter { $0.id != account.id }
    next.insert(account, at: 0)
    accounts = next
    return account
  }

  func open(_ account: Account) async {
    let token = UUID()
    generation = token
    opening = true
    // The outgoing workspace owns its own pending writes and network credentials.
    await workspace?.finishDraftWrites()
    guard generation == token else { return }
    workspace = nil
    do {
      let credentials = try Credentials.load(account: account.id)
      let directory = directory
      let (identity, store) = try await Task.detached {
        let identity = try Identity(hex: credentials.privateKey)
        guard identity.pubkey == account.pubkey else { throw BuzzError.invalidKey }
        let store = try LocalStore(
          directory: directory, community: account.community, pubkey: identity.pubkey)
        return (identity, store)
      }.value
      guard generation == token else { return }
      let relay = HTTPRelay(
        community: account.community, identity: identity, authTag: credentials.authTag)
      let next = Workspace(
        account: account, identity: identity, store: store, relay: relay,
        live: LiveRelay(community: account.community, identity: identity))
      await next.reload()
      await NativePushBridge.refresh(workspace: next)
      guard generation == token else { return }
      workspace = next
      opening = false
    } catch {
      guard generation == token else { return }
      self.error = error.localizedDescription
      opening = false
    }
  }
}

@MainActor @Observable
final class Workspace {
  let account: Account
  let identity: Identity
  let store: LocalStore
  let relay: any RelayTransport
  let outbox: Outbox
  let live: (any LiveEventTransport)?
  let membershipManager: MembershipManager
  var events: [Event] = []
  var pulseEvents: [Event] = []
  var pulseLoading = false
  var pulseError: String?
  var intents = IntentSnapshot()
  var channels: [Channel] = []
  var directory: [Channel] = []
  var directoryLoading = false
  var directoryError: String?
  var directoryHasMore = true
  var membershipBusy = false
  var directoryCursor: DirectoryCursor?
  var directoryPages = 0
  var error: String?
  var refreshing = false
  var sending = false
  var reactionBusy = Set<String>()
  var reactions: [String: [ReactionGroup]] = [:]
  var customEmoji: [CustomEmoji] = []
  var readState: [String: Int] = [:]
  var userStatus: Event?
  var presence = "offline"
  var typing: [String: [TypingIndicator]] = [:]
  var followedThreads: Set<String>
  var emojiLoading = false
  var emojiError: String?
  var searchResults: [Event] = []
  var searchError: String?
  var searching = false
  var searchHasMore = false
  private var searchQuery = ""
  private var searchChannelID: String?
  private var searchGeneration = UUID()
  private var reloadGeneration = UUID()
  private var draftWrite: Task<Void, Never>?

  init(
    account: Account, identity: Identity, store: LocalStore, relay: any RelayTransport,
    live: (any LiveEventTransport)? = nil
  ) {
    self.account = account
    self.identity = identity
    self.store = store
    self.relay = relay
    self.live = live
    outbox = Outbox(store: store, relay: relay)
    membershipManager = MembershipManager(store: store, relay: relay)
    let key = "buzz.followed-threads.\(account.community.id).\(identity.pubkey)"
    followedThreads = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
  }

  func toggleThreadFollow(_ rootID: String) {
    if followedThreads.contains(rootID) {
      followedThreads.remove(rootID)
    } else {
      followedThreads.insert(rootID)
      if followedThreads.count > 500 { followedThreads = Set(followedThreads.sorted().suffix(500)) }
    }
    let key = "buzz.followed-threads.\(account.community.id).\(identity.pubkey)"
    UserDefaults.standard.set(Array(followedThreads), forKey: key)
  }

  func reload() async {
    let token = UUID()
    reloadGeneration = token
    let cached = await store.cachedEvents()
    let journal = await store.intentSnapshot()
    let authority = await store.relayAuthority()
    let identity = self.identity
    let projected = await Task.detached {
      let ids = Set(cached.map(\.id))
      let visible = cached + journal.pending.map(\.event).filter { !ids.contains($0.id) }
      return (
        ReactionProjection.index(events: visible, authority: authority),
        CustomEmoji.palette(events: cached),
        ReadStateProjection.contexts(events: visible, identity: self.identity)
      )
    }.value
    guard reloadGeneration == token else { return }
    events = cached
    intents = journal
    reactions = projected.0
    customEmoji = projected.1
    readState = projected.2
    userStatus = cached.filter {
      $0.kind == 30315 && $0.pubkey == identity.pubkey && $0.tag("d") == "general"
    }.max(by: { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) })
    channels = Projection.channels(
      events: cached.filter { $0.pubkey == authority }, pubkey: identity.pubkey)
    directory = authority.map { Projection.directory(events: cached, relayPubkey: $0) } ?? []
  }

  func unreadCount(for channel: Channel) -> Int {
    let marker = readState[ReadStateProjection.contextKey(channelID: channel.id)] ?? 0
    return events.filter { event in
      Projection.messageKinds.contains(event.kind) && event.tag("h") == channel.id
        && event.createdAt > marker
        && !events.contains { deletion in
          EventRelations.deletes(deletion, target: event, channelID: channel.id)
        }
    }.count
  }

  /// Commits one encrypted read-state snapshot before attempting delivery.
  @discardableResult
  func markChannelRead(_ channelID: String, through timestamp: Int? = nil) async -> Bool {
    let latest =
      timestamp ?? events.filter {
        Projection.messageKinds.contains($0.kind) && $0.tag("h") == channelID
      }.map(\.createdAt).max() ?? 0
    guard latest > (readState[channelID] ?? 0) else { return true }
    do {
      await reload()
      var contexts = readState
      contexts[channelID] = max(contexts[channelID] ?? 0, latest)
      let blob = ReadStateBlob(clientID: identity.pubkey, contexts: contexts)
      let plaintext = String(decoding: try JSONEncoder().encode(blob), as: UTF8.self)
      let content = try ReadStateCrypto.encrypt(plaintext, identity: identity)
      let event = try identity.sign(
        kind: ReadStateProjection.kind, content: content,
        tags: [["d", ReadStateProjection.dTag], ["t", "read-state"]],
        at: max(Int(Date().timeIntervalSince1970), latest))
      try await store.enqueue(event)
      await reload()
      Task { await retry() }
      return true
    } catch {
      self.error = error.localizedDescription
      return false
    }
  }

  func name(_ pubkey: String) -> String { Projection.name(pubkey: pubkey, events: events) }

  /// Hydrates one linked event, including its channel/thread context when available.
  func resolveDeepLink(_ link: BuzzDeepLink) async -> Event? {
    if let cached = events.first(where: { $0.id == link.eventID }) { return cached }
    do {
      let found = try await relay.query([
        EventFilter(kinds: Projection.messageKinds.sorted(), ids: [link.eventID], limit: 1)
      ])
      try await store.ingest(found)
      await reload()
      return events.first(where: { $0.id == link.eventID })
    } catch {
      self.error = error.localizedDescription
      return nil
    }
  }

  func channelName(_ channel: Channel) -> String {
    guard channel.type == "dm" else { return channel.name }
    let others = channel.participants.filter { $0 != identity.pubkey }.map(name)
    return others.isEmpty ? channel.name : others.joined(separator: ", ")
  }

  func refresh() async {
    guard !refreshing else { return }
    refreshing = true
    defer { refreshing = false }
    do {
      try await ChannelDiscovery.refresh(store: store, relay: relay, pubkey: identity.pubkey)
      await reload()
      error = nil
      await retry()
      await checkMemberships()
      await NativePushBridge.refresh(workspace: self)
    } catch is CancellationError { return } catch {
      self.error = error.localizedDescription
      await reload()
      await NativePushBridge.refresh(workspace: self)
    }
  }

  func hydrateProfiles(for incoming: [Event]) async {
    do {
      let authors = Array(Set(incoming.map(\.pubkey))).sorted()
      for offset in stride(from: 0, to: authors.count, by: 100) {
        let batch = Array(authors[offset..<min(authors.count, offset + 100)])
        let profiles = try await relay.query([EventFilter(kinds: [0], authors: batch, limit: 100)])
        try await store.ingest(profiles)
      }
      await reload()
    } catch is CancellationError { return } catch { self.error = error.localizedDescription }
  }

  func loadStatus() async {
    do {
      let events = try await relay.query([
        EventFilter(kinds: [30315], authors: [identity.pubkey], tags: ["d": ["general"]], limit: 1)
      ])
      try await store.ingest(events)
      await reload()
    } catch is CancellationError { return } catch { self.error = error.localizedDescription }
  }

  /// Mints a bounded, relay-authorized community invite link.
  func mintInvite(ttlDays: Int, maxUses: Int?) async throws -> InviteLink {
    let validUses = maxUses.map { [1, 3, 5, 10, 25].contains($0) } ?? true
    guard (1...30).contains(ttlDays), validUses else {
      throw BuzzError.invalidResponse
    }
    guard let relay = relay as? HTTPRelay else { throw BuzzError.invalidResponse }
    var body: [String: Any] = ["ttl_secs": ttlDays * 24 * 60 * 60]
    if let maxUses { body["max_uses"] = maxUses }
    let data = try JSONSerialization.data(withJSONObject: body)
    let response = try await relay.postJSON(path: "api/invites", body: data)
    guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
      let code = object["code"] as? String, !code.isEmpty
    else { throw BuzzError.invalidResponse }
    return InviteLink(relay: account.community.origin, code: code)
  }

  /// Loads the public note stream used by the Pulse surface.
  func loadPulse() async {
    guard !pulseLoading else { return }
    pulseLoading = true
    defer { pulseLoading = false }
    do {
      let notes = try await relay.query([EventFilter(kinds: [1], limit: 100)])
      try await store.ingest(notes)
      await reload()
      pulseEvents = notes.sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
      pulseError = nil
    } catch is CancellationError {
      return
    } catch {
      pulseError = error.localizedDescription
    }
  }

  /// Queues a public Pulse note or reply as one durable local operation.
  @discardableResult
  func postPulse(text: String, replyTo: Event? = nil) async -> Bool {
    let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else { return false }
    do {
      var tags: [[String]] = []
      if let replyTo {
        let root = replyTo.rootID ?? replyTo.id
        tags.append(["e", root, "", "root"])
        tags.append(["e", replyTo.id, "", "reply"])
        tags.append(["p", replyTo.pubkey])
      }
      let event = try identity.sign(kind: 1, content: body, tags: tags)
      try await store.enqueue(event)
      await reload()
      Task { await retry() }
      pulseEvents.insert(event, at: 0)
      return true
    } catch {
      pulseError = error.localizedDescription
      return false
    }
  }

  @discardableResult
  func setStatus(text: String, emoji: String, expiration: Int? = nil) async -> Bool {
    var tags = [["d", "general"]]
    let trimmedEmoji = String(emoji.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32))
    if !trimmedEmoji.isEmpty { tags.append(["emoji", trimmedEmoji]) }
    if let expiration, expiration > Int(Date().timeIntervalSince1970) {
      tags.append(["expiration", "\(expiration)"])
    }
    let success = await action(kind: 30315, content: String(text.prefix(512)), tags: tags)
    if success { await reload() }
    return success
  }

  /// Uploads and publishes the current user's avatar while preserving profile fields.
  @discardableResult
  func setAvatar(_ data: Data, mimeType: String = "image/jpeg") async -> Bool {
    do {
      let descriptor = try await uploadMedia(data, mimeType: mimeType)
      let profile = events.filter { $0.kind == 0 && $0.pubkey == identity.pubkey }
        .max { $0.createdAt < $1.createdAt }
      var object: [String: Any] = [:]
      if let profile, let previous = profile.content.data(using: .utf8) {
        object = try JSONSerialization.jsonObject(with: previous) as? [String: Any] ?? [:]
      }
      object["picture"] = descriptor.url
      let content = String(
        decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
        as: UTF8.self)
      return await action(kind: 0, content: content, tags: [])
    } catch {
      self.error = error.localizedDescription
      return false
    }
  }

  func setPresence(_ value: String) async {
    guard ["online", "away", "offline"].contains(value) else { return }
    presence = value
    guard let live else { return }
    do {
      let event = try identity.sign(kind: 20001, content: value, tags: [])
      try await live.publishEphemeral(event)
    } catch {
      // Presence is ephemeral; the next explicit selection retries it.
    }
  }

  func sendTyping(channel: Channel, root: Event?) async {
    guard let live else { return }
    var tags = [["h", channel.id]]
    if let root {
      if let parent = root.parentID, parent != root.id {
        tags.append(["e", parent, "", "root"])
      }
      tags.append(["e", root.id, "", "reply"])
    }
    do {
      let event = try identity.sign(kind: 20002, content: "", tags: tags)
      try await live.publishEphemeral(event)
    } catch {
      // Typing is best-effort and never blocks message delivery.
    }
  }

  func activeHuddle(for channelID: String) -> HuddleSessionInfo? {
    let starts = events.filter { $0.kind == 48100 && $0.tag("h") == channelID }
      .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    var active: HuddleSessionInfo?
    for event in starts {
      guard let data = event.content.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let ephemeral = object["ephemeral_channel_id"] as? String, !ephemeral.isEmpty
      else { continue }
      let ended = events.contains {
        $0.kind == 48103 && $0.tag("h") == channelID
          && $0.content.contains(ephemeral) && ($0.createdAt, $0.id) > (event.createdAt, event.id)
      }
      if !ended {
        active = HuddleSessionInfo(
          id: event.id, parentChannelID: channelID, ephemeralChannelID: ephemeral,
          startedAt: event.createdAt)
      }
    }
    return active
  }

  @discardableResult
  func startHuddle(in channel: Channel) async -> HuddleSessionInfo? {
    guard activeHuddle(for: channel.id) == nil else { return activeHuddle(for: channel.id) }
    do {
      let ephemeral = UUID().uuidString.lowercased()
      let content = try JSONSerialization.data(
        withJSONObject: ["ephemeral_channel_id": ephemeral])
      let event = try identity.sign(
        kind: 48100, content: String(decoding: content, as: UTF8.self), tags: [["h", channel.id]])
      try await store.enqueue(event)
      await reload()
      Task { await retry() }
      return HuddleSessionInfo(
        id: event.id, parentChannelID: channel.id, ephemeralChannelID: ephemeral,
        startedAt: event.createdAt)
    } catch {
      self.error = error.localizedDescription
      return nil
    }
  }

  @discardableResult
  func endHuddle(_ session: HuddleSessionInfo) async -> Bool {
    do {
      let event = try identity.sign(
        kind: 48103, content: "{\"ephemeral_channel_id\":\"\(session.ephemeralChannelID)\"}",
        tags: [["h", session.parentChannelID]])
      try await store.enqueue(event)
      await reload()
      Task { await retry() }
      return true
    } catch {
      self.error = error.localizedDescription
      return false
    }
  }

  @discardableResult
  func sendHuddleReaction(_ emoji: String, in session: HuddleSessionInfo) async -> Bool {
    let value = String(emoji.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32))
    guard !value.isEmpty else { return false }
    return await action(
      kind: 24810, content: value,
      tags: [
        ["h", session.ephemeralChannelID], ["reaction", value],
        ["sender_name", name(identity.pubkey)],
      ])
  }

  func watch(channel: Channel) async {
    guard let live else { return }
    let since = Int(Date().timeIntervalSince1970)
    // A compact layout can show only the thread. Its live stream must still
    // receive edits/reactions targeting replies and deletions targeting those
    // auxiliary events; a root-only e-filter would exclude them.
    let tags = ["h": [channel.id]]
    // Each reconnect includes bounded history in the same persistent REQ.
    // A persistent failure terminates visibly; explicit refresh can restart it.
    for attempt in 0..<4 {
      do {
        try Task.checkCancellation()
        for try await event in live.events(
          filter: EventFilter(
            kinds: Projection.timelineKinds + [20002], tags: tags, since: since, limit: 200)
        ) {
          try Task.checkCancellation()
          guard EventRelations.hasCompatibleChannel(event, channelID: channel.id) else {
            throw BuzzError.invalidResponse
          }
          if event.kind == 20002 {
            recordTyping(event, channelID: channel.id)
            continue
          }
          try await store.ingest([event])
          await reload()
        }
        return
      } catch {
        guard !Task.isCancelled else { return }
        self.error = "Live updates interrupted. " + error.localizedDescription
        if attempt < 3 {
          do { try await Task.sleep(for: .seconds(1 << attempt)) } catch { return }
        }
      }
    }
  }

  /// Read-only: views call this from `body`. Writing `typing` here, even a
  /// no-op prune, would invalidate the view and re-render it without end.
  func typingNames(for channel: Channel, root: Event?) -> [String] {
    let now = Date()
    return (typing[channel.id] ?? [])
      .filter { $0.rootID == root?.id && $0.expiresAt > now }
      .map { name($0.pubkey) }
  }

  private func recordTyping(_ event: Event, channelID: String) {
    pruneTyping(channelID: channelID)
    var entries = typing[channelID] ?? []
    let rootID = event.rootID ?? event.tag("e")
    entries.removeAll { $0.pubkey == event.pubkey && $0.rootID == rootID }
    entries.append(
      TypingIndicator(pubkey: event.pubkey, rootID: rootID, expiresAt: Date().addingTimeInterval(8))
    )
    typing[channelID] = entries
  }

  private func pruneTyping(channelID: String) {
    guard let entries = typing[channelID] else { return }
    let now = Date()
    let live = entries.filter { $0.expiresAt > now }
    guard live.count != entries.count else { return }
    typing[channelID] = live.isEmpty ? nil : live
  }

  func saveDraft(_ text: String, key: String) {
    intents.drafts[key] = text
    let prior = draftWrite
    let store = store
    draftWrite = Task {
      await prior?.value
      do { try await store.saveDraft(text, key: key) } catch {
        self.error = error.localizedDescription
      }
    }
  }

  func finishDraftWrites() async { await draftWrite?.value }

  func send(
    text: String, channel: Channel, root: Event?, mediaTags: [[String]] = []
  ) async -> Bool {
    guard !sending, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return false
    }
    sending = true
    defer { sending = false }
    let key = Self.draftKey(channel: channel.id, root: root?.id)
    do {
      await finishDraftWrites()
      var tags = [["h", channel.id]]
      if let root { tags.append(["e", root.id, "", "reply"]) }
      tags += mediaTags
      let mentionCandidates = events.filter { $0.kind == 0 }.reduce(
        into: [String: MentionCandidate]()
      ) { result, event in
        result[event.pubkey] = MentionCandidate(
          pubkey: event.pubkey, name: Projection.name(pubkey: event.pubkey, events: events),
          member: channel.participants.contains(event.pubkey))
      }.values
      tags += Mentions.tags(in: text, candidates: Array(mentionCandidates))
      if channel.type == "dm" {
        tags += channel.participants.filter { $0 != identity.pubkey }.map { ["p", $0] }
      }
      let kind = channel.type == "forum" ? (root == nil ? 45001 : 45003) : 9
      let identity = identity
      let event = try await Task.detached {
        try identity.sign(kind: kind, content: text, tags: tags)
      }.value
      try await store.enqueue(event, replacingDraft: key, expectedDraft: text)
      await reload()
      Task { await retry() }
      return true
    } catch {
      self.error = error.localizedDescription
      return false
    }
  }

  /// Opens or resurfaces a DM using the relay's command response, then hydrates
  /// the returned channel before making it selectable in the sidebar.
  func openDM(with pubkeys: [String]) async throws -> Channel {
    let recipients = Array(Set(pubkeys.map { $0.lowercased() })).filter { $0 != identity.pubkey }
    guard !recipients.isEmpty, recipients.count <= 8 else {
      throw BuzzError.invalidResponse
    }
    guard let relay = relay as? any CommandRelayTransport else {
      throw BuzzError.invalidResponse
    }
    let identity = identity
    let event = try await Task.detached {
      try identity.sign(kind: 41010, content: "", tags: recipients.map { ["p", $0] })
    }.value
    let message = try await relay.publishCommand(event)
    guard let channelID = Self.commandChannelID(from: message) else {
      throw BuzzError.invalidResponse
    }
    let fetched = try await relay.query([
      EventFilter(kinds: [39000, 39002], tags: ["d": [channelID]], limit: 20)
    ])
    try await store.ingest(fetched)
    await reload()
    guard let channel = channels.first(where: { $0.id == channelID }) else {
      throw BuzzError.invalidResponse
    }
    return channel
  }

  func uploadMedia(_ data: Data, mimeType: String) async throws -> BlobDescriptor {
    try await BlossomClient(community: account.community, identity: identity)
      .upload(data, mimeType: mimeType)
  }

  private static func commandChannelID(from message: String) -> String? {
    let prefix = "response:"
    guard message.hasPrefix(prefix),
      let data = message.dropFirst(prefix.count).data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let value = object["channel_id"] as? String,
      !value.isEmpty, value.utf8.count <= 128
    else { return nil }
    return value
  }

  func retry() async {
    do { try await outbox.flush() } catch is CancellationError { return } catch {
      self.error = error.localizedDescription
    }
    await reload()
  }

  @discardableResult
  func action(kind: Int, content: String, tags: [[String]]) async -> Bool {
    do {
      let identity = identity
      let event = try await Task.detached {
        try identity.sign(kind: kind, content: content, tags: tags)
      }.value
      try await store.enqueue(event)
      await reload()
      await retry()
      return true
    } catch {
      self.error = error.localizedDescription
      return false
    }
  }

  func search(_ query: String, channelID: String? = nil) async {
    let token = UUID()
    searchGeneration = token
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    searchQuery = query
    searchChannelID = channelID
    searchResults = []
    searchError = nil
    searchHasMore = false
    searching = !query.isEmpty
    guard !query.isEmpty else { return }
    do {
      try await Task.sleep(for: .milliseconds(300))
      try Task.checkCancellation()
      var filter = EventFilter(kinds: Projection.messageKinds, search: query, limit: 100)
      if let channelID, !channelID.isEmpty { filter.tags = ["h": [channelID]] }
      let matches = try await relay.query([filter])
      guard searchGeneration == token else { return }
      try await store.ingest(matches)
      searchResults = matches.sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
      searchHasMore = matches.count == 100
      searching = false
      await reload()
    } catch is CancellationError { return } catch {
      guard searchGeneration == token else { return }
      searchError = error.localizedDescription
      searching = false
    }
  }

  func loadMoreSearch() async {
    guard !searching, searchHasMore, !searchQuery.isEmpty,
      let oldest = searchResults.min(by: { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) })
    else { return }
    let token = searchGeneration
    searching = true
    searchError = nil
    do {
      var filter = EventFilter(
        kinds: Projection.messageKinds, search: searchQuery,
        until: oldest.createdAt, beforeID: oldest.id, limit: 100)
      if let searchChannelID, !searchChannelID.isEmpty { filter.tags = ["h": [searchChannelID]] }
      let matches = try await relay.query([filter])
      guard searchGeneration == token else { return }
      let existing = Set(searchResults.map(\.id))
      try await store.ingest(matches)
      searchResults = (searchResults + matches.filter { !existing.contains($0.id) })
        .sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
      searchHasMore = matches.count == 100
      searching = false
      await reload()
    } catch is CancellationError { return } catch {
      guard searchGeneration == token else { return }
      searchError = error.localizedDescription
      searching = false
    }
  }

  var visibleEvents: [Event] {
    let cached = Set(events.map(\.id))
    return events + intents.pending.map(\.event).filter { !cached.contains($0.id) }
  }

  static func draftKey(channel: String, root: String?) -> String {
    channel + "/" + (root ?? "timeline")
  }
}
