import Foundation
import Testing

@testable import BuzzCore

struct ConversationPageTests {
  @Test func windowUsesSignedScanPositionAndAuthoritativeExhaustion() throws {
    let f = try PageFixture()
    let row = try f.message(at: 100)
    let skipped = try f.message(at: 90)
    let scan = EventCursor(event: skipped)
    let page = try ConversationPage.window(
      [row, f.bounds(next: scan)], channelID: "c", authority: f.relay.pubkey, after: nil)
    #expect(page.next == scan)
    #expect(page.events == [row])
    #expect(page.rows == [row])
    let emptyButMore = try ConversationPage.window(
      [f.bounds(next: scan)], channelID: "c", authority: f.relay.pubkey, after: nil)
    #expect(emptyButMore.rows.isEmpty)
    #expect(emptyButMore.next == scan)
    let rows = try (0..<50).map { try f.message(at: 100 - $0) }
    let exhausted = try ConversationPage.window(
      rows + [f.bounds(next: nil)], channelID: "c", authority: f.relay.pubkey, after: nil)
    #expect(exhausted.rows.count == 50)
    #expect(exhausted.next == nil)
  }

  @Test func windowRejectsWrongAuthorityBindingTypesScopeAndRegressingCursors() throws {
    let f = try PageFixture()
    let row = try f.message(at: 10)
    let cursor = EventCursor(event: row)
    let valid = try f.bounds(next: nil)
    let wrongSigner = try f.user.sign(kind: 39006, content: valid.content, tags: valid.tags)
    let wrongBinding = try f.relay.sign(
      kind: 39006, content: valid.content, tags: [["h", "c"], ["d", "c:other"]])
    let wrongTypes = try f.relay.sign(
      kind: 39006, content: "{\"has_more\":0,\"next_cursor\":null}", tags: valid.tags)
    let contradictory = try f.relay.sign(
      kind: 39006, content: "{\"has_more\":true,\"next_cursor\":null}", tags: valid.tags)
    let extraTag = try f.relay.sign(
      kind: 39006, content: valid.content, tags: valid.tags + [["h", "c"]])
    for bounds in [wrongSigner, wrongBinding, wrongTypes, contradictory, extraTag] {
      #expect(throws: BuzzError.invalidResponse) {
        try ConversationPage.window(
          [row, bounds], channelID: "c", authority: f.relay.pubkey, after: nil)
      }
    }
    #expect(throws: BuzzError.invalidResponse) {
      try ConversationPage.window(
        [row, valid, valid], channelID: "c", authority: f.relay.pubkey, after: nil)
    }
    #expect(throws: BuzzError.invalidResponse) {
      try ConversationPage.window(
        [f.bounds(after: cursor, next: cursor)], channelID: "c", authority: f.relay.pubkey,
        after: cursor)
    }
    let foreign = try f.user.sign(kind: 9, content: "wrong channel", tags: [["h", "other"]])
    #expect(throws: BuzzError.invalidResponse) {
      try ConversationPage.window(
        [foreign, valid], channelID: "c", authority: f.relay.pubkey, after: nil)
    }
    let tampered = Event(
      id: row.id, pubkey: row.pubkey, createdAt: row.createdAt,
      kind: row.kind, tags: row.tags, content: "changed", sig: row.sig)
    #expect(throws: BuzzError.invalidEvent) {
      try ConversationPage.window(
        [tampered, valid], channelID: "c", authority: f.relay.pubkey, after: nil)
    }
  }

  @Test func sameSecondWindowOrderAndTwoHopAuxiliaryClosureMatchRelayContract() throws {
    let f = try PageFixture()
    let rows = try (0..<4).map { try f.message(at: 10, text: "\($0)") }.sorted { $0.id < $1.id }
    let cursor = EventCursor(event: rows[1])
    let reaction = try f.user.sign(kind: 7, content: "👍", tags: [["e", rows[2].id]])
    let deletion = try f.user.sign(kind: 5, content: "", tags: [["e", reaction.id]])
    let page = try ConversationPage.window(
      [rows[2], rows[3], reaction, deletion, f.bounds(after: cursor, next: nil)],
      channelID: "c", authority: f.relay.pubkey, after: cursor)
    #expect(page.events.count == 4)
    #expect(page.rows.map(\.id) == [rows[2].id, rows[3].id])
    #expect(
      Projection.messages(events: rows, channelID: "c").map(\.id) == rows.reversed().map(\.id))
    #expect(throws: BuzzError.invalidResponse) {
      try ConversationPage.window(
        [rows[0], f.bounds(after: cursor, next: nil)],
        channelID: "c", authority: f.relay.pubkey, after: cursor)
    }
    #expect(throws: BuzzError.invalidResponse) {
      try ConversationPage.window(
        [rows[3], rows[2], f.bounds(after: cursor, next: nil)],
        channelID: "c", authority: f.relay.pubkey, after: cursor)
    }
    let unrelated = try f.user.sign(kind: 7, content: "👍", tags: [["h", "c"], ["e", rows[0].id]])
    #expect(throws: BuzzError.invalidResponse) {
      try ConversationPage.window(
        [rows[2], unrelated, f.bounds(next: nil)],
        channelID: "c", authority: f.relay.pubkey, after: nil)
    }
  }

  @Test func unsupportedHeadRetriesCleanFilterButNetworkFailureDoesNotDowngrade() async throws {
    let f = try PageFixture()
    let row = try f.message(at: 10)
    let relay = PageRelay(events: [row])
    let page = try await ConversationPage.fetch(
      relay: relay, channelID: "c", authority: f.relay.pubkey)
    #expect(page.mode == .standard)
    #expect(page.events == [row])
    let queries = await relay.queries
    #expect(queries.count == 2)
    let window = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(queries[0])) as? [String: Any])
    #expect(window["top_level"] as? Bool == true)
    #expect(window["include_aux"] as? Bool == true)
    #expect(window["limit"] as? Int == 50)
    let clean = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(queries[1])) as? [String: Any])
    #expect(Set(clean.keys) == ["kinds", "#h", "limit"])
    await relay.failWith(.http(503))
    await #expect(throws: BuzzError.http(503)) {
      try await ConversationPage.fetch(relay: relay, channelID: "c", authority: f.relay.pubkey)
    }
    #expect(await relay.queries.count == 3)
    await relay.failWith(nil)
    await #expect(throws: BuzzError.invalidResponse) {
      try await ConversationPage.fetch(
        relay: relay, channelID: "c", authority: f.relay.pubkey,
        after: EventCursor(event: row), mode: .window)
    }
    #expect(await relay.queries.count == 4)
  }

  @Test func threadCursorPagesAscendingWithoutDroppingSameSecondReplies() async throws {
    let f = try PageFixture()
    let root = try f.message(at: 1)
    let replies = try (0..<205).map { index in
      try f.user.sign(
        kind: 9, content: "Reply \(index)", tags: [["h", "c"], ["e", root.id, "", "reply"]], at: 10)
    }.sorted { $0.id < $1.id }
    let relay = PageRelay(events: replies)
    let first = try await ConversationPage.fetch(
      relay: relay, channelID: "c", rootID: root.id, authority: f.relay.pubkey)
    let second = try await ConversationPage.fetch(
      relay: relay, channelID: "c", rootID: root.id, authority: f.relay.pubkey,
      after: first.next, mode: first.mode)
    #expect(first.rows.count == 200)
    #expect(second.rows.count == 5)
    #expect(second.next == nil)
    #expect((first.rows + second.rows).map(\.id) == replies.map(\.id))
    let queries = await relay.queries
    #expect(queries[0].depthLimit == 64)
    #expect(queries[1].threadCursor == 10)
    #expect(queries[1].threadCursorID == replies[199].id)
    #expect(queries[1].beforeID == nil)
    #expect(queries[1].until == nil)
    #expect(queries[1].tags == ["h": ["c"], "e": [root.id]])
    let wire = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(queries[1])) as? [String: Any])
    #expect(wire["thread_cursor"] as? Int == 10)
    #expect(wire["thread_cursor_id"] as? String == replies[199].id)
    #expect(wire["depth_limit"] as? Int == 64)
  }

  @Test func threadProjectionFollowsNestedParentsAndBroadcastsRemainInTheTimeline() throws {
    let f = try PageFixture()
    let root = try f.message(at: 1)
    let reply = try f.user.sign(
      kind: 9, content: "Broadcast reply",
      tags: [["h", "c"], ["e", root.id, "", "reply"], ["broadcast", "1"]], at: 2)
    let child = try f.user.sign(
      kind: 9, content: "Nested reply",
      tags: [["h", "c"], ["e", reply.id, "", "reply"], ["broadcast", "1"]], at: 3)
    let other = try f.message(at: 4)
    let events = [root, reply, child, other]
    #expect(
      Projection.messages(events: events, channelID: "c", rootID: root.id).map(\.id) == [
        root.id, reply.id, child.id,
      ])
    #expect(
      Projection.messages(events: events, channelID: "c").map(\.id) == [
        root.id, reply.id, other.id,
      ])
  }

  @Test func threadAuxiliariesDoNotChangeReplyCursorOrExhaustion() async throws {
    let f = try PageFixture()
    let root = try f.message(at: 1)
    let replies = try (0..<200).map { index in
      try f.user.sign(
        kind: 9, content: "Reply \(index)", tags: [["h", "c"], ["e", root.id, "", "reply"]], at: 10)
    }.sorted { $0.id < $1.id }
    let firstReply = try #require(replies.first)
    let reaction = try f.user.sign(kind: 7, content: "❤️", tags: [["e", firstReply.id]], at: 500)
    let deletion = try f.user.sign(kind: 5, content: "", tags: [["e", reaction.id]], at: 600)
    let rootReaction = try f.user.sign(kind: 7, content: "🔥", tags: [["e", root.id]], at: 700)
    let rootDeletion = try f.user.sign(kind: 5, content: "", tags: [["e", root.id]], at: 800)
    let relay = ThreadResponseRelay(responses: [
      replies + [reaction, deletion, rootReaction], [rootReaction, rootDeletion],
    ])
    let page = try await ConversationPage.fetch(
      relay: relay, channelID: "c", rootID: root.id, authority: f.relay.pubkey)
    #expect(page.rows == replies)
    #expect(page.events.count == 203)
    #expect(page.next == replies.last.map(EventCursor.init))
    #expect(ReactionProjection.index(events: [root] + page.events)[firstReply.id] == nil)
    #expect(ReactionProjection.index(events: [root] + page.events)[root.id]?.first?.value == "🔥")
    let tail = try await ConversationPage.fetch(
      relay: relay, channelID: "c", rootID: root.id, authority: f.relay.pubkey,
      after: page.next, mode: page.mode)
    #expect(tail.rows.isEmpty)
    #expect(tail.next == nil)
    #expect(tail.events == [rootReaction, rootDeletion])
    let queries = await relay.queries
    #expect(queries.count == 2)
    #expect(queries.allSatisfy { $0.includeAux == true && $0.limit == 200 })
    #expect(queries[1].threadCursorID == replies.last?.id)
    #expect(queries[1].threadCursor == 10)
    let wire = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(queries[0])) as? [String: Any])
    #expect(wire["include_aux"] as? Bool == true)
  }

  // Lloyd hit `BuzzError.invalidResponse` on every "Open thread" in a channel an
  // agent posts to (#general, 2026-09-21 03:50Z). The relay's aux closure began
  // returning NIP-AR receipts, and `validate` rejects any kind outside
  // `Projection.timelineKinds`, so one receipt on one reply failed the whole
  // page. The literal 44201 is deliberate: this test has to compile and fail
  // against a tree that does not yet know the kind by name.
  @Test func aThreadCarryingATurnReceiptLoadsRatherThanFailingTheWholePage() async throws {
    let f = try PageFixture()
    let root = try f.message(at: 1)
    let reply = try f.user.sign(
      kind: 9, content: "Reply", tags: [["h", "c"], ["e", root.id, "", "reply"]], at: 2)
    let receipt = try f.user.sign(
      kind: 44201, content: #"{"model":"opus[1m]","harness":"buzz-acp","turn":{}}"#,
      tags: [["h", "c"], ["e", reply.id]], at: 3)
    let relay = ThreadResponseRelay(responses: [[reply, receipt]])
    let page = try await ConversationPage.fetch(
      relay: relay, channelID: "c", rootID: root.id, authority: f.relay.pubkey)
    #expect(page.rows == [reply])
    #expect(page.events.contains(receipt))
    // An overlay is never a row, so it must not move the cursor or exhaustion.
    #expect(page.next == nil)
  }

  // The relay's auxiliary closure grows without asking the app. Kind 44201
  // joined it while 2.0.0 (5) was in testers' hands and every thread in
  // #general failed for an evening, because the page validator rejected any
  // kind it did not know (buzz#57). Rows stay strict; an unknown kind rides the
  // page and is dropped, so the next aux kind is not another outage.
  //
  // 65001 stands in for that next kind: outside every range we assign, so it
  // stays unknown however the real allowlist grows.
  @Test func aThreadCarryingAnUnknownAuxiliaryKindLoadsRatherThanFailing() async throws {
    let f = try PageFixture()
    let root = try f.message(at: 1)
    let reply = try f.user.sign(
      kind: 9, content: "Reply", tags: [["h", "c"], ["e", root.id, "", "reply"]], at: 2)
    let unknown = try f.user.sign(
      kind: 65001, content: "{}", tags: [["h", "c"], ["e", reply.id]], at: 3)
    let page = try await ConversationPage.fetch(
      relay: ThreadResponseRelay(responses: [[reply, unknown]]), channelID: "c", rootID: root.id,
      authority: f.relay.pubkey)
    #expect(page.rows == [reply])
    #expect(!page.events.contains(unknown))
    #expect(page.next == nil)

    // Dropped means dropped: an unknown kind is never signature-checked, never
    // bound to a row, and never able to fail the page around it. A tampered one
    // must not raise `invalidEvent` the way a tampered reaction does.
    var object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(unknown)) as? [String: Any])
    object["content"] = "tampered"
    let forged = try JSONDecoder().decode(
      Event.self, from: JSONSerialization.data(withJSONObject: object))
    let unbound = try f.user.sign(
      kind: 65001, content: "{}", tags: [["h", "c"], ["e", String(repeating: "a", count: 64)]],
      at: 4)
    let foreign = try f.user.sign(kind: 65001, content: "{}", tags: [["h", "other"]], at: 5)
    for stray in [forged, unbound, foreign] {
      let tolerated = try await ConversationPage.fetch(
        relay: ThreadResponseRelay(responses: [[reply, stray]]), channelID: "c", rootID: root.id,
        authority: f.relay.pubkey)
      #expect(tolerated.rows == [reply])
      #expect(!tolerated.events.contains(stray))
    }
  }

  // The same rule on the channel side, where the cost of rejecting is larger:
  // `fetch` falls back to the plain filter on `invalidResponse`, so an unknown
  // kind in the head window silently downgraded the whole channel to the
  // pre-NIP-CW protocol instead of failing loudly.
  @Test func aWindowCarryingAnUnknownAuxiliaryKindStillRendersItsRows() throws {
    let f = try PageFixture()
    let message = try f.message(at: 10)
    let unknown = try f.user.sign(
      kind: 65001, content: "{}", tags: [["h", "c"], ["e", message.id]], at: 11)
    let page = try ConversationPage.window(
      [message, unknown, try f.bounds(next: nil)], channelID: "c", authority: f.relay.pubkey,
      after: nil)
    #expect(page.rows == [message])
    #expect(!page.events.contains(unknown))
    #expect(page.mode == .window)
  }

  @Test func threadRejectsUnboundAuxiliariesWrongChannelsAndInvalidSignatures() async throws {
    let f = try PageFixture()
    let root = try f.message(at: 1)
    let reply = try f.user.sign(
      kind: 9, content: "Reply", tags: [["h", "c"], ["e", root.id, "", "reply"]], at: 2)
    let unrelated = try f.message(at: 3)
    let reaction = try f.user.sign(kind: 7, content: "👍", tags: [["e", reply.id]])
    let validDelete = try f.user.sign(kind: 5, content: "", tags: [["e", reaction.id]])
    let badEvents = [
      try f.user.sign(kind: 7, content: "👍", tags: [["e", unrelated.id]]),
      try f.user.sign(kind: 7, content: "👍", tags: [["e", reaction.id]]),
      try f.user.sign(kind: 5, content: "", tags: [["e", validDelete.id]]),
      try f.user.sign(kind: 5, content: "", tags: [["h", "other"], ["e", reaction.id]]),
    ]
    for bad in badEvents {
      let relay = ThreadResponseRelay(responses: [[reply, reaction, validDelete, bad]])
      await #expect(throws: BuzzError.invalidResponse) {
        try await ConversationPage.fetch(
          relay: relay, channelID: "c", rootID: root.id, authority: f.relay.pubkey)
      }
    }
    var object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(reaction)) as? [String: Any])
    object["content"] = "tampered"
    let invalid = try JSONDecoder().decode(
      Event.self, from: JSONSerialization.data(withJSONObject: object))
    let relay = ThreadResponseRelay(responses: [[reply, invalid]])
    await #expect(throws: BuzzError.invalidEvent) {
      try await ConversationPage.fetch(
        relay: relay, channelID: "c", rootID: root.id, authority: f.relay.pubkey)
    }
  }

  @Test func deletedEditsFallBackToPreviousAuthorEditUsingLastTarget() throws {
    let f = try PageFixture()
    let message = try f.message(at: 1, text: "Original")
    let old = try f.user.sign(
      kind: 40003, content: "First edit", tags: [["h", "c"], ["e", message.id]], at: 2)
    let newest = try f.user.sign(
      kind: 40003, content: "Latest edit",
      tags: [["h", "c"], ["e", String(repeating: "0", count: 64)], ["e", message.id]], at: 3)
    let foreignDeletion = try f.relay.sign(kind: 5, content: "", tags: [["e", newest.id]], at: 4)
    let deletion = try f.user.sign(kind: 5, content: "", tags: [["e", newest.id]], at: 5)
    let events = [message, old, newest, foreignDeletion]
    #expect(Projection.content(of: message, events: events) == "Latest edit")
    #expect(Projection.content(of: message, events: events + [deletion]) == "First edit")
    let deleteOld = try f.user.sign(kind: 5, content: "", tags: [["e", old.id]], at: 6)
    #expect(Projection.content(of: message, events: events + [deletion, deleteOld]) == "Original")
  }
}

private actor ThreadResponseRelay: RelayTransport {
  var responses: [[Event]]
  var queries: [EventFilter] = []
  init(responses: [[Event]]) { self.responses = responses }
  func publish(_ event: Event) throws { throw BuzzError.invalidEvent }
  func query(_ filters: [EventFilter]) throws -> [Event] {
    queries.append(try #require(filters.first))
    guard !responses.isEmpty else { throw BuzzError.invalidResponse }
    return responses.removeFirst()
  }
}

private struct PageFixture {
  let relay: Identity
  let user: Identity
  init() throws {
    relay = try Identity(hex: String(repeating: "0", count: 63) + "1")
    user = try Identity(hex: String(repeating: "0", count: 63) + "2")
  }
  func message(at timestamp: Int, text: String = "message") throws -> Event {
    try user.sign(kind: 9, content: text, tags: [["h", "c"]], at: timestamp)
  }
  func bounds(after cursor: EventCursor? = nil, next: EventCursor?) throws -> Event {
    let value: Any
    if let next {
      value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(next))
    } else {
      value = NSNull()
    }
    let data = try JSONSerialization.data(withJSONObject: [
      "has_more": next != nil, "next_cursor": value,
    ])
    let binding = cursor.map { "\($0.timestamp):\($0.eventID)" } ?? "head"
    return try relay.sign(
      kind: 39006, content: String(decoding: data, as: UTF8.self),
      tags: [["h", "c"], ["d", "c:\(binding)"]], at: 200)
  }
}

private actor PageRelay: RelayTransport {
  let events: [Event]
  var queries: [EventFilter] = []
  var failure: BuzzError?
  init(events: [Event]) { self.events = events }
  func failWith(_ error: BuzzError?) { failure = error }
  func publish(_ event: Event) throws { throw BuzzError.invalidEvent }
  func query(_ filters: [EventFilter]) throws -> [Event] {
    let filter = try #require(filters.first)
    queries.append(filter)
    if let failure { throw failure }
    if filter.depthLimit != nil {
      return Array(
        events.filter { event in
          filter.threadCursor.map { time in
            event.createdAt > time
              || (event.createdAt == time && event.id > (filter.threadCursorID ?? ""))
          } ?? true
        }.prefix(filter.limit))
    }
    return events
  }
}
