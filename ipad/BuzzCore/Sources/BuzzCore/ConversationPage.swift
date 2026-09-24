import Foundation

/// An immutable conversation-page result; cursors never include live events or overlays.
public struct ConversationPage: Sendable {
  /// The wire protocol used for this cursor chain.
  public enum Mode: Sendable { case window, standard, thread }
  /// Original signed content and auxiliary events to fold into the local store.
  public let events: [Event]
  /// Content rows counted by this page, excluding overlays and auxiliaries.
  public let rows: [Event]
  /// The next page position, nil when this query is exhausted.
  public let next: EventCursor?
  /// The protocol that must be used to continue this page.
  public let mode: Mode

  /// Loads a page using NIP-CW for channel roots or the recursive thread query.
  /// A relay without a usable head window is retried with a clean standard filter.
  public static func fetch(
    relay: any RelayTransport, channelID: String, rootID: String? = nil,
    authority: String, after cursor: EventCursor? = nil, mode: Mode? = nil
  ) async throws -> ConversationPage {
    if let rootID {
      return try await thread(relay: relay, channelID: channelID, rootID: rootID, after: cursor)
    }
    if mode != .standard {
      do {
        var filter = EventFilter(
          kinds: Projection.messageKinds, tags: ["h": [channelID]], until: cursor?.timestamp,
          beforeID: cursor?.eventID, limit: 50)
        filter.topLevel = true
        filter.includeAux = true
        let response = try await relay.query([filter])
        try Task.checkCancellation()
        return try window(response, channelID: channelID, authority: authority, after: cursor)
      } catch {
        try Task.checkCancellation()
        // Never change protocols midway through a cursor chain, or turn a network
        // or signature failure into an apparently successful empty history.
        guard mode == nil, cursor == nil,
          error as? BuzzError == .invalidResponse || error as? BuzzError == .http(400)
        else { throw error }
      }
    }
    let response = try await relay.query([
      EventFilter(
        kinds: Projection.timelineKinds, tags: ["h": [channelID]], until: cursor?.timestamp,
        beforeID: cursor?.eventID, limit: 200)
    ])
    try Task.checkCancellation()
    let ordered = response.sorted(by: EventCursor.relayOrder)
    let kept = try retained(
      ordered, channelID: channelID, kinds: Projection.timelineKinds, maximum: 200)
    guard kept.allSatisfy({ cursor?.containsOlder($0) ?? true }) else {
      throw BuzzError.invalidResponse
    }
    return ConversationPage(
      events: kept, rows: kept.filter { Projection.messageKinds.contains($0.kind) },
      // Exhaustion and the cursor read off what the relay delivered. A dropped
      // event still filled a slot in the page, so counting survivors would end
      // the chain early and key the next page to the wrong position.
      next: ordered.count == 200 ? ordered.last.map(EventCursor.init) : nil, mode: .standard)
  }

  private struct Bounds: Decodable {
    let hasMore: Bool
    let next: EventCursor?
    enum CodingKeys: String, CodingKey {
      case hasMore = "has_more"
      case next = "next_cursor"
    }
    init(from decoder: any Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      guard values.contains(.next) else { throw BuzzError.invalidResponse }
      hasMore = try values.decode(Bool.self, forKey: .hasMore)
      next = try values.decodeIfPresent(EventCursor.self, forKey: .next)
    }
  }

  /// Verifies a complete NIP-CW response against its requested channel, cursor and authority.
  public static func window(
    _ response: [Event], channelID: String, authority: String, after cursor: EventCursor?
  ) throws -> ConversationPage {
    let events = try retained(
      response, channelID: channelID, kinds: Projection.timelineKinds + [39005, 39006],
      maximum: 2251)
    let rows = events.filter { Projection.messageKinds.contains($0.kind) }
    guard rows.count <= 50, rows.allSatisfy({ cursor?.containsOlder($0) ?? true }),
      rows.map(\.id) == rows.sorted(by: EventCursor.relayOrder).map(\.id)
    else { throw BuzzError.invalidResponse }
    let boundsEvents = events.filter { $0.kind == 39006 }
    let binding =
      channelID.lowercased() + ":"
      + (cursor.map { "\($0.timestamp):\($0.eventID)" } ?? "head")
    guard boundsEvents.count == 1, let event = boundsEvents.first,
      event.pubkey == authority, event.tags.count == 2,
      event.tags.contains(["d", binding]), event.tags.contains(["h", channelID])
    else { throw BuzzError.invalidResponse }
    let bounds: Bounds
    do { bounds = try JSONDecoder().decode(Bounds.self, from: Data(event.content.utf8)) } catch {
      throw BuzzError.invalidResponse
    }
    guard bounds.hasMore == (bounds.next != nil),
      bounds.next.map({ cursor?.precedes($0) ?? true }) ?? true
    else { throw BuzzError.invalidResponse }

    let rowIDs = Set(rows.map(\.id))
    let aux = try auxiliaries(events, targeting: rowIDs)
    for summary in events where summary.kind == 39005 {
      guard summary.pubkey == authority, summary.tags.count == 3,
        let rowID = summary.tag("e"), rowIDs.contains(rowID),
        summary.tags.contains(["e", rowID]), summary.tags.contains(["d", rowID]),
        summary.tags.contains(["h", channelID])
      else { throw BuzzError.invalidResponse }
    }
    // The scan cursor can refer to a candidate omitted by the relay. It must
    // advance from the request, but must never be derived from delivered rows.
    return ConversationPage(events: rows + aux, rows: rows, next: bounds.next, mode: .window)
  }

  private static func thread(
    relay: any RelayTransport, channelID: String, rootID: String, after cursor: EventCursor?
  ) async throws -> ConversationPage {
    var filter = EventFilter(
      kinds: Projection.messageKinds, tags: ["h": [channelID], "e": [rootID]], limit: 200)
    filter.depthLimit = 64
    filter.includeAux = true
    filter.threadCursor = cursor?.timestamp
    filter.threadCursorID = cursor?.eventID
    let response = try await relay.query([filter])
    try Task.checkCancellation()
    let events = try retained(
      response, channelID: channelID, kinds: Projection.timelineKinds, maximum: 5000)
    let rows = events.filter { Projection.messageKinds.contains($0.kind) }
    guard rows.count <= 200,
      rows.allSatisfy({ event in
        event.parentID != nil && event.id != rootID
          && (cursor.map { (event.createdAt, event.id) > ($0.timestamp, $0.eventID) } ?? true)
      })
    else { throw BuzzError.invalidResponse }
    let aux = try auxiliaries(events, targeting: Set(rows.map(\.id) + [rootID]))
    let ordered = rows.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    return ConversationPage(
      events: ordered + aux, rows: ordered,
      next: ordered.count == 200 ? ordered.last.map(EventCursor.init) : nil, mode: .thread)
  }

  /// The bridge returns direct overlays and a second hop of deletions of those overlays.
  /// A thread includes its root in the target set even on an empty reply page.
  /// A NIP-AR receipt names every message of one turn, which can straddle this
  /// page: one naming nothing here has nothing to annotate, so it is dropped
  /// rather than failing the page it arrived with.
  private static func auxiliaries(_ events: [Event], targeting targetIDs: Set<String>) throws
    -> [Event]
  {
    func references(_ item: Event, _ ids: Set<String>) -> Bool {
      item.tags.contains { $0.count >= 2 && $0[0] == "e" && ids.contains($0[1]) }
    }
    let aux = events.filter { [5, 7, 9005, 40003].contains($0.kind) }
    let receipts = events.filter { $0.kind == Projection.turnReceiptKind }
    let firstHop = Set(
      aux.filter { references($0, targetIDs) }.map(\.id) + receipts.map(\.id))
    for item in aux where !firstHop.contains(item.id) {
      guard [5, 9005].contains(item.kind), references(item, firstHop) else {
        throw BuzzError.invalidResponse
      }
    }
    return aux + receipts.filter { references($0, targetIDs) }
  }

  /// Validates everything this client will keep from a page, and returns it.
  ///
  /// **Rows stay strict**: a malformed, foreign or unsigned content event still
  /// fails the whole page. An event of a kind this build has never heard of is
  /// **dropped** instead. The relay's auxiliary closure grows on its own
  /// schedule -- kind 44201 joined it while `2.0.0 (5)` was in testers' hands,
  /// and every thread in a channel an agent posts to failed with
  /// `invalidResponse` until a new build cleared the App Store. A closed
  /// allowlist makes each future aux kind another outage of that shape, and
  /// rejecting buys nothing a renderer that cannot draw the kind would have
  /// used.
  private static func retained(
    _ events: [Event], channelID: String, kinds: [Int], maximum: Int
  ) throws -> [Event] {
    // The cap counts what the relay delivered, not what survives: an unknown
    // kind still cost the memory and the page slot it arrived in.
    guard events.count <= maximum else { throw BuzzError.invalidResponse }
    let known = Set(kinds)
    let kept = events.filter { known.contains($0.kind) }
    guard Set(kept.map(\.id)).count == kept.count,
      kept.allSatisfy({ EventRelations.hasCompatibleChannel($0, channelID: channelID) })
    else { throw BuzzError.invalidResponse }
    guard kept.allSatisfy({ $0.hasValidIDAndSignature() }) else { throw BuzzError.invalidEvent }
    return kept
  }
}
