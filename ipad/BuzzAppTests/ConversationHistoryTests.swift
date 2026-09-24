import BuzzCore
import XCTest

@testable import Buzz

final class ConversationHistoryTests: XCTestCase {
  @MainActor func testThreadOnlyLiveViewReceivesNestedReplyOverlays() async throws {
    let f = try HistoryFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let root = try f.message("Root", at: 1)
    let reply = try f.signer.sign(
      kind: 9, content: "Reply", tags: [["h", "c"], ["e", root.id, "", "reply"]], at: 2)
    let nested = try f.signer.sign(
      kind: 9, content: "Nested", tags: [["h", "c"], ["e", reply.id, "", "reply"]], at: 3)
    try await f.store.ingest([root, reply, nested])
    let edit = try f.signer.sign(
      kind: 40003, content: "Updated nested reply", tags: [["h", "c"], ["e", nested.id]])
    let removed = try f.signer.sign(kind: 7, content: "👍", tags: [["e", nested.id]])
    let heart = try f.signer.sign(kind: 7, content: "❤️", tags: [["e", nested.id]])
    let deletion = try f.signer.sign(kind: 5, content: "", tags: [["e", removed.id]])
    let live = ThreadLiveFixture(packets: [edit, removed, heart, deletion])
    let workspace = Workspace(
      account: f.workspace.account, identity: f.signer, store: f.store, relay: f.relay, live: live)
    let metadata = try f.signer.sign(
      kind: 39000, content: "", tags: [["d", "c"], ["name", "Channel"], ["t", "stream"]])
    let channel = try XCTUnwrap(Channel(event: metadata))
    await workspace.reload()
    let history = ConversationHistory(workspace: workspace, channelID: "c", rootID: root.id)
    await workspace.watch(channel: channel)
    XCTAssertEqual(history.messages.map(\.id), [root.id, reply.id, nested.id])
    XCTAssertEqual(Projection.content(of: nested, events: workspace.events), "Updated nested reply")
    XCTAssertEqual(workspace.reactions[nested.id]?.map(\.value), ["❤️"])
    let filters = await live.filters
    XCTAssertEqual(filters.count, 1)
    XCTAssertEqual(filters.first?.tags, ["h": ["c"]])
    XCTAssertNotNil(filters.first?.since)
  }

  @MainActor func testThreadOverlaysPersistAndFailedRefreshKeepsThePreviousPage() async throws {
    let f = try HistoryFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let root = try f.message("Thread root", at: 1)
    let reply = try f.signer.sign(
      kind: 9, content: "Original reply", tags: [["h", "c"], ["e", root.id, "", "reply"]], at: 2)
    let edit = try f.signer.sign(
      kind: 40003, content: "Edited reply", tags: [["h", "c"], ["e", reply.id]], at: 3)
    let reaction = try f.signer.sign(kind: 7, content: "❤️", tags: [["e", reply.id]], at: 4)
    let removed = try f.signer.sign(kind: 7, content: "👍", tags: [["e", reply.id]], at: 5)
    let deletion = try f.signer.sign(kind: 5, content: "", tags: [["e", removed.id]], at: 6)
    try await f.store.ingest([root])
    await f.workspace.reload()
    let page = [reply, edit, reaction, removed, deletion]
    await f.relay.configure(head: page, older: [])
    let history = ConversationHistory(workspace: f.workspace, channelID: "c", rootID: root.id)
    await history.refresh()
    XCTAssertNil(history.error)
    XCTAssertFalse(history.hasMore)
    XCTAssertEqual(history.messages.map(\.id), [root.id, reply.id])
    XCTAssertEqual(Projection.content(of: reply, events: f.workspace.events), "Edited reply")
    XCTAssertEqual(f.workspace.reactions[reply.id]?.map(\.value), ["❤️"])

    let later = try f.signer.sign(
      kind: 9, content: "Later reply", tags: [["h", "c"], ["e", root.id, "", "reply"]], at: 7)
    let unrelated = try f.signer.sign(
      kind: 7, content: "🔥", tags: [["e", String(repeating: "0", count: 64)]], at: 8)
    await f.relay.configure(head: page + [later, unrelated], older: [])
    await history.refresh()
    XCTAssertNotNil(history.error)
    XCTAssertEqual(history.messages.map(\.id), [root.id, reply.id])
    let rejectedCache = await f.store.cachedEvents()
    XCTAssertFalse(rejectedCache.contains(later))
    XCTAssertFalse(rejectedCache.contains(unrelated))
    await f.relay.configure(head: page + [later], older: [])
    await history.loadMore()
    XCTAssertNil(history.error)
    XCTAssertEqual(history.messages.map(\.id), [root.id, reply.id, later.id])
    let filters = await f.relay.queries
    XCTAssertTrue(filters.allSatisfy { $0.includeAux == true && $0.threadCursor == nil })
    let reopened = try LocalStore(
      directory: f.directory, community: f.workspace.account.community,
      pubkey: f.workspace.identity.pubkey)
    let cached = await reopened.cachedEvents()
    XCTAssertEqual(Projection.content(of: reply, events: cached), "Edited reply")
    XCTAssertEqual(ReactionProjection.index(events: cached)[reply.id]?.map(\.value), ["❤️"])
  }

  @MainActor func testEmptyUnservedWindowKeepsCacheAndRetryRepeatsHeadRequest() async throws {
    let f = try HistoryFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let row = try f.message("Cached message", at: 20)
    let cursor = EventCursor(event: row)
    await f.relay.configure(head: try f.page([row], next: cursor), older: [])
    let history = ConversationHistory(workspace: f.workspace, channelID: "c", rootID: nil)
    await history.refresh()
    await f.relay.configure(head: [], older: [])
    await history.refresh()
    XCTAssertNotNil(history.error)
    XCTAssertEqual(history.messages.map(\.id), [row.id])
    await f.relay.configure(head: try f.page([row]), older: [])
    await history.loadMore()
    XCTAssertNil(history.error)
    XCTAssertFalse(history.hasMore)
    let last = await f.relay.queries.last
    XCTAssertNil(last?.beforeID)
    XCTAssertEqual(last?.topLevel, true)
    // A served, identity-verified empty window is different: its bounds confirm exhaustion.
    await f.relay.configure(head: try f.page([]), older: [])
    await history.refresh()
    XCTAssertNil(history.error)
    XCTAssertTrue(history.messages.isEmpty)
  }

  @MainActor func testFailedPageKeepsCursorAndCachedRowsUntilRetrySucceeds() async throws {
    let f = try HistoryFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let newest = try f.message("Newest", at: 20)
    let oldest = try f.message("Oldest", at: 10)
    let cursor = EventCursor(event: newest)
    await f.relay.configure(
      head: try f.page([newest], next: cursor), older: try f.page([oldest], after: cursor))
    try await f.store.ingest([newest, oldest])
    await f.workspace.reload()
    let history = ConversationHistory(workspace: f.workspace, channelID: "c", rootID: nil)
    XCTAssertEqual(history.messages.count, 2)
    await history.refresh()
    XCTAssertEqual(history.messages.map(\.id), [newest.id])
    XCTAssertTrue(history.hasMore)
    await f.relay.failNextPage()
    await history.loadMore()
    XCTAssertNotNil(history.error)
    XCTAssertTrue(history.hasMore)
    XCTAssertEqual(history.messages.map(\.id), [newest.id])
    await history.loadMore()
    XCTAssertNil(history.error)
    XCTAssertFalse(history.hasMore)
    XCTAssertEqual(history.messages.map(\.id), [oldest.id, newest.id])
    let queries = await f.relay.queries
    XCTAssertEqual(queries.count, 3)
    XCTAssertEqual(queries[1].beforeID, newest.id)
    XCTAssertEqual(queries[2].beforeID, newest.id)
    XCTAssertEqual(queries[2].until, 20)
    let reopened = try LocalStore(
      directory: f.directory, community: f.workspace.account.community,
      pubkey: f.workspace.identity.pubkey)
    let saved = await reopened.cachedEvents()
    XCTAssertTrue(saved.contains(oldest))
  }

  @MainActor func testRefreshRetainsLiveArrivalsAndRejectsLateCancelledPage() async throws {
    let f = try HistoryFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let old = try f.message("Retired page", at: 10)
    let current = try f.message("Current head", at: 20)
    let live = try f.message("Live while query pending", at: 30)
    await f.relay.configure(head: try f.page([current]), older: [])
    await f.relay.holdNextPage()
    let history = ConversationHistory(workspace: f.workspace, channelID: "c", rootID: nil)
    let retired = Task { await history.refresh() }
    await f.relay.waitForHeldQuery()
    try await f.store.ingest([live])
    await f.workspace.reload()
    // Cancelling the view fences even a transport that ignores task cancellation.
    history.cancel()
    await history.refresh()
    await f.relay.releaseHeld(try f.page([old]))
    await retired.value
    XCTAssertNil(history.error)
    XCTAssertFalse(history.loading)
    XCTAssertFalse(history.hasMore)
    let cached = await f.store.cachedEvents()
    XCTAssertFalse(cached.contains(old))
    XCTAssertTrue(cached.contains(live))
    XCTAssertEqual(history.messages.map(\.id), [current.id])

    // An arrival during a current head request remains visible after that page lands.
    await f.relay.holdNextPage()
    let refreshing = Task { await history.refresh() }
    await f.relay.waitForHeldQuery()
    let newerLive = try f.message("Newest live", at: 40)
    try await f.store.ingest([newerLive])
    await f.workspace.reload()
    await f.relay.releaseHeld(try f.page([current]))
    await refreshing.value
    XCTAssertEqual(history.messages.map(\.id), [current.id, newerLive.id])
  }

  @MainActor func testCacheWriteFailureDoesNotAdvanceHistory() async throws {
    let f = try HistoryFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let newest = try f.message("Newest", at: 20)
    let older = try f.message("Older", at: 10)
    let cursor = EventCursor(event: newest)
    await f.relay.configure(
      head: try f.page([newest], next: cursor), older: try f.page([older], after: cursor))
    let history = ConversationHistory(workspace: f.workspace, channelID: "c", rootID: nil)
    await history.refresh()
    let partition = try XCTUnwrap(
      FileManager.default.contentsOfDirectory(
        at: f.directory,
        includingPropertiesForKeys: nil
      ).first)
    let backup = f.directory.appendingPathComponent("backup")
    try FileManager.default.moveItem(at: partition, to: backup)
    try Data().write(to: partition)
    await history.loadMore()
    XCTAssertNotNil(history.error)
    XCTAssertTrue(history.hasMore)
    XCTAssertEqual(history.messages.map(\.id), [newest.id])
    try FileManager.default.removeItem(at: partition)
    try FileManager.default.moveItem(at: backup, to: partition)
    await history.loadMore()
    XCTAssertNil(history.error)
    XCTAssertEqual(history.messages.map(\.id), [older.id, newest.id])
  }
}

private actor ThreadLiveFixture: LiveEventTransport {
  let packets: [Event]
  var filters: [EventFilter] = []
  init(packets: [Event]) { self.packets = packets }
  nonisolated func events(filter: EventFilter) -> AsyncThrowingStream<Event, any Error> {
    AsyncThrowingStream(bufferingPolicy: .bufferingOldest(8)) { continuation in
      let producer = Task { await emit(filter, to: continuation) }
      continuation.onTermination = { _ in producer.cancel() }
    }
  }
  private func emit(
    _ filter: EventFilter, to continuation: AsyncThrowingStream<Event, any Error>.Continuation
  ) {
    filters.append(filter)
    for event in packets { continuation.yield(event) }
    continuation.finish()
  }
}

@MainActor private struct HistoryFixture {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let signer: Identity
  let store: LocalStore
  let relay: HistoryRelay
  let workspace: Workspace
  init() throws {
    signer = try Identity(hex: String(repeating: "0", count: 63) + "1")
    let community = try Community(url: "https://history.example", name: "Test")
    store = try LocalStore(directory: directory, community: community, pubkey: signer.pubkey)
    relay = HistoryRelay(authority: signer.pubkey)
    workspace = Workspace(
      account: Account(id: UUID(), community: community, pubkey: signer.pubkey),
      identity: signer, store: store, relay: relay)
  }
  func message(_ text: String, at time: Int) throws -> Event {
    try signer.sign(kind: 9, content: text, tags: [["h", "c"]], at: time)
  }
  func page(_ rows: [Event], after cursor: EventCursor? = nil, next: EventCursor? = nil) throws
    -> [Event]
  {
    let value: Any
    if let next {
      value = ["created_at": next.timestamp, "id": next.eventID]
    } else {
      value = NSNull()
    }
    let data = try JSONSerialization.data(withJSONObject: [
      "has_more": next != nil, "next_cursor": value,
    ])
    let binding = cursor.map { "\($0.timestamp):\($0.eventID)" } ?? "head"
    return rows + [
      try signer.sign(
        kind: 39006, content: String(decoding: data, as: UTF8.self),
        tags: [["h", "c"], ["d", "c:\(binding)"]])
    ]
  }
}

private actor HistoryRelay: RelayTransport {
  let key: String
  var queries: [EventFilter] = []
  private var head: [Event] = []
  private var older: [Event] = []
  private var failing = false
  private var hold = false
  private var held: CheckedContinuation<[Event], any Error>?
  private var observer: CheckedContinuation<Void, Never>?
  init(authority: String) { key = authority }
  func authority() -> String { key }
  func publish(_ event: Event) throws { throw BuzzError.invalidEvent }
  func configure(head: [Event], older: [Event]) {
    self.head = head
    self.older = older
  }
  func failNextPage() { failing = true }
  func holdNextPage() { hold = true }
  func waitForHeldQuery() async {
    if held != nil { return }
    await withCheckedContinuation { observer = $0 }
  }
  func releaseHeld(_ events: [Event]) {
    held?.resume(returning: events)
    held = nil
  }
  func query(_ filters: [EventFilter]) async throws -> [Event] {
    let filter = try XCTUnwrap(filters.first)
    if filter.kinds == [0] { return [] }
    queries.append(filter)
    if failing {
      failing = false
      throw BuzzError.http(503)
    }
    if hold {
      hold = false
      return try await withCheckedThrowingContinuation { continuation in
        held = continuation
        observer?.resume()
        observer = nil
      }
    }
    return filter.beforeID == nil ? head : older
  }
}
