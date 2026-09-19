#if DEBUG
  import BuzzCore
  import Foundation

  /// Deterministic, local-only fixtures. Never compiled into Release/TestFlight builds.
  enum Demo {
    @MainActor static func workspace() async throws -> Workspace {
      let directory = URL.applicationSupportDirectory.appendingPathComponent("BuzzNativeUITests")
      if ProcessInfo.processInfo.arguments.contains("--reset-test-data"),
        FileManager.default.fileExists(atPath: directory.path)
      {
        try FileManager.default.removeItem(at: directory)
      }
      let identity = try Identity(hex: String(repeating: "0", count: 63) + "1")
      let colleague = try Identity(hex: String(repeating: "0", count: 63) + "2")
      let community = try Community(url: "https://ui-test.invalid", name: "Buzz Studio")
      let account = Account(id: UUID(), community: community, pubkey: identity.pubkey)
      let store = try LocalStore(
        directory: directory, community: community, pubkey: identity.pubkey)
      try await store.setRelayAuthority(identity.pubkey)
      let now = 1_789_760_000
      var fixtures = [
        try identity.sign(kind: 0, content: "{\"display_name\":\"Taylor\"}", tags: [], at: now),
        try colleague.sign(kind: 0, content: "{\"display_name\":\"Alex Chen\"}", tags: [], at: now),
      ]
      fixtures.append(
        try identity.sign(
          kind: 39000, content: "",
          tags: [
            ["d", "watercooler"], ["name", "watercooler"], ["t", "stream"], ["public"],
            ["about", "Meet the rest of the team."],
          ], at: now))
      fixtures.append(
        try identity.sign(
          kind: 39002, content: "", tags: [["d", "watercooler"], ["p", colleague.pubkey]], at: now))
      for (id, name, type, about) in [
        ("general", "general", "stream", "A place for everyone. Share what you’re working on."),
        ("design", "design", "stream", "Designing a workspace that feels like home."),
        ("engineering", "engineering", "stream", "Build notes, questions, and things we learned."),
        ("ideas", "Ideas & proposals", "forum", "Give good ideas room to grow."),
        ("alex", "Alex Chen", "dm", ""),
      ] {
        fixtures.append(
          try identity.sign(
            kind: 39000, content: "",
            tags: [
              ["d", id], ["name", name], ["t", type], ["about", about],
              ["p", identity.pubkey], ["p", colleague.pubkey],
            ], at: now))
        fixtures.append(
          try identity.sign(
            kind: 39002, content: "",
            tags: [
              ["d", id], ["p", identity.pubkey], ["p", colleague.pubkey],
            ], at: now))
      }
      let welcome = try colleague.sign(
        kind: 9,
        content:
          "Welcome to our workspace 👋\n\nA little space for big ideas. What are you working on today?",
        tags: [["h", "general"]], at: now + 1)
      fixtures += [
        welcome,
        try identity.sign(
          kind: 9,
          content:
            "Getting Buzz ready for iPad. Conversations on the left, a little more room to think on the right.",
          tags: [["h", "general"]], at: now + 2),
        try colleague.sign(
          kind: 9, content: "I love being able to keep a thread open alongside the channel.",
          tags: [["h", "general"], ["e", welcome.id, "", "reply"]], at: now + 3),
        try colleague.sign(
          kind: 45001,
          content:
            "A calmer home for our projects\n\nWhat if every project started with a conversation? Share your ideas here.",
          tags: [["h", "ideas"]], at: now + 4),
      ]
      let historyFixture = ProcessInfo.processInfo.arguments.contains("--history-fixture")
      if historyFixture {
        for index in 0..<121 {
          fixtures.append(
            try colleague.sign(
              kind: 9, content: index == 0 ? "Oldest history message" : "History message \(index)",
              tags: [["h", "engineering"]], at: now + index))
        }
      }
      try await store.ingest(fixtures)
      var remoteOnly: [Event] = []
      if ProcessInfo.processInfo.arguments.contains("--thread-aux-fixture"),
        let reply = fixtures.first(where: { $0.parentID == welcome.id })
      {
        let edit = try colleague.sign(
          kind: 40003, content: "This reply was edited before this iPad opened the thread.",
          tags: [["h", "general"], ["e", reply.id]], at: now + 20)
        let withdrawn = try colleague.sign(
          kind: 40003, content: "This edit was withdrawn.",
          tags: [["h", "general"], ["e", reply.id]], at: now + 21)
        let deletedReply = try colleague.sign(
          kind: 9, content: "Removed thread reply",
          tags: [["h", "general"], ["e", welcome.id, "", "reply"]], at: now + 22)
        let removedReaction = try identity.sign(
          kind: 7, content: "👍", tags: [["e", reply.id]], at: now + 23)
        remoteOnly = [
          edit, withdrawn, deletedReply, removedReaction,
          try colleague.sign(kind: 5, content: "", tags: [["e", withdrawn.id]], at: now + 24),
          try colleague.sign(kind: 5, content: "", tags: [["e", deletedReply.id]], at: now + 25),
          try identity.sign(kind: 5, content: "", tags: [["e", removedReaction.id]], at: now + 26),
          try identity.sign(kind: 7, content: "❤️", tags: [["e", reply.id]], at: now + 27),
        ]
      }
      let relay = DemoRelay(
        store: store, authority: identity, failHistoryOnce: historyFixture, remoteOnly: remoteOnly)
      let workspace = Workspace(account: account, identity: identity, store: store, relay: relay)
      await workspace.reload()
      return workspace
    }
  }

  private actor DemoRelay: RelayTransport {
    let store: LocalStore
    let signer: Identity
    var failHistoryOnce: Bool
    let remoteOnly: [Event]
    init(store: LocalStore, authority: Identity, failHistoryOnce: Bool, remoteOnly: [Event]) {
      self.store = store
      self.signer = authority
      self.failHistoryOnce = failHistoryOnce
      self.remoteOnly = remoteOnly
    }
    func authority() -> String { signer.pubkey }
    func query(_ filters: [EventFilter]) async throws -> [Event] {
      guard let first = filters.first else { return [] }
      if first.topLevel == true, first.beforeID != nil, failHistoryOnce {
        failHistoryOnce = false
        throw BuzzError.http(503)
      }
      let cached = await store.cachedEvents()
      let all = Array(
        Dictionary(
          (cached + remoteOnly).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        .values)
      let matching = all.filter { event in
        filters.contains { filter in
          filter.kinds.contains(event.kind)
            && (filter.authors?.contains(event.pubkey) ?? true)
            && (filter.ids?.contains(event.id) ?? true)
            && (filter.search.map { event.content.localizedCaseInsensitiveContains($0) } ?? true)
            && (filter.until.map { event.createdAt <= $0 } ?? true)
            && (filter.topLevel != true || event.parentID == nil
              || event.tags.contains(["broadcast", "1"]))
            && (filter.threadCursor.map { timestamp in
              (event.createdAt, event.id) > (timestamp, filter.threadCursorID ?? "")
            } ?? true)
            && (filter.beforeID.map { before in
              event.createdAt < (filter.until ?? Int.max)
                || (event.createdAt == filter.until && event.id > before)
            } ?? true)
            && filter.tags.allSatisfy { key, values in
              event.tags.contains { $0.count >= 2 && $0[0] == key && values.contains($0[1]) }
            }
        }
      }
      if first.topLevel == true, let channelID = first.tags["h"]?.first {
        let ordered = matching.sorted(by: EventCursor.relayOrder)
        let rows = Array(ordered.prefix(first.limit))
        let hasMore = ordered.count > first.limit
        let cursor: Any
        if hasMore, let last = rows.last {
          cursor = ["created_at": last.createdAt, "id": last.id]
        } else {
          cursor = NSNull()
        }
        let data = try JSONSerialization.data(withJSONObject: [
          "has_more": hasMore, "next_cursor": cursor,
        ])
        let binding = first.until.map { "\($0):\(first.beforeID ?? "")" } ?? "head"
        let bounds = try signer.sign(
          kind: 39006, content: String(decoding: data, as: UTF8.self),
          tags: [["h", channelID], ["d", "\(channelID):\(binding)"]])
        return rows + auxiliaryEvents(for: rows, filter: first, in: all) + [bounds]
      }
      let ordered =
        first.depthLimit == nil
        ? matching.sorted(by: EventCursor.relayOrder)
        : matching.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
      let rows = Array(ordered.prefix(first.limit))
      return rows + auxiliaryEvents(for: rows, filter: first, in: all)
    }

    private func auxiliaryEvents(for rows: [Event], filter: EventFilter, in all: [Event]) -> [Event]
    {
      guard filter.includeAux == true else { return [] }
      var targets = Set(rows.map(\.id))
      if filter.depthLimit != nil { targets.formUnion(filter.tags["e"] ?? []) }
      var found: [Event] = []
      var seen = Set<String>()
      for kinds in [[5, 7, 9005, 40003], [5, 9005]] {
        let hop = all.filter { event in
          kinds.contains(event.kind) && !seen.contains(event.id)
            && event.tags.contains { $0.count >= 2 && $0[0] == "e" && targets.contains($0[1]) }
        }
        found += hop
        targets = Set(hop.map(\.id))
        seen.formUnion(targets)
      }
      return found
    }
    func publish(_ event: Event) async throws {
      try await store.ingest([event])
      if [9021, 9022].contains(event.kind), let channel = event.tag("h") {
        let tags = [["d", channel]] + (event.kind == 9021 ? [["p", event.pubkey]] : [])
        let latest =
          await store.cachedEvents().filter { $0.kind == 39002 && $0.tag("d") == channel }.map(
            \.createdAt
          ).max() ?? 0
        try await store.ingest([
          signer.sign(
            kind: 39002, content: "", tags: tags,
            at: max(Int(Date().timeIntervalSince1970), latest + 1))
        ])
      }
    }
  }
#endif
