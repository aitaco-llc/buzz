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
    try validate(response, channelID: channelID, kinds: Projection.timelineKinds, maximum: 200)
    guard response.allSatisfy({ cursor?.containsOlder($0) ?? true }) else {
      throw BuzzError.invalidResponse
    }
    let ordered = response.sorted(by: EventCursor.relayOrder)
    return ConversationPage(
      events: ordered, rows: ordered.filter { Projection.messageKinds.contains($0.kind) },
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
    try validate(
      response, channelID: channelID, kinds: Projection.timelineKinds + [39005, 39006],
      maximum: 2251)
    let rows = response.filter { Projection.messageKinds.contains($0.kind) }
    guard rows.count <= 50, rows.allSatisfy({ cursor?.containsOlder($0) ?? true }),
      rows.map(\.id) == rows.sorted(by: EventCursor.relayOrder).map(\.id)
    else { throw BuzzError.invalidResponse }
    let boundsEvents = response.filter { $0.kind == 39006 }
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
    let aux = try auxiliaries(response, targeting: rowIDs)
    for summary in response where summary.kind == 39005 {
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
    try validate(response, channelID: channelID, kinds: Projection.timelineKinds, maximum: 5000)
    let rows = response.filter { Projection.messageKinds.contains($0.kind) }
    guard rows.count <= 200,
      rows.allSatisfy({ event in
        event.parentID != nil && event.id != rootID
          && (cursor.map { (event.createdAt, event.id) > ($0.timestamp, $0.eventID) } ?? true)
      })
    else { throw BuzzError.invalidResponse }
    let aux = try auxiliaries(response, targeting: Set(rows.map(\.id) + [rootID]))
    let ordered = rows.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    return ConversationPage(
      events: ordered + aux, rows: ordered,
      next: ordered.count == 200 ? ordered.last.map(EventCursor.init) : nil, mode: .thread)
  }

  /// The bridge returns direct overlays and a second hop of deletions of those overlays.
  /// A thread includes its root in the target set even on an empty reply page.
  private static func auxiliaries(_ events: [Event], targeting targetIDs: Set<String>) throws
    -> [Event]
  {
    let aux = events.filter { [5, 7, 9005, 40003].contains($0.kind) }
    let firstHop = Set(
      aux.filter { item in
        item.tags.contains { $0.count >= 2 && $0[0] == "e" && targetIDs.contains($0[1]) }
      }.map(\.id))
    for item in aux where !firstHop.contains(item.id) {
      guard [5, 9005].contains(item.kind),
        item.tags.contains(where: {
          $0.count >= 2 && $0[0] == "e" && firstHop.contains($0[1])
        })
      else { throw BuzzError.invalidResponse }
    }
    return aux
  }

  private static func validate(
    _ events: [Event], channelID: String, kinds: [Int], maximum: Int
  ) throws {
    guard events.count <= maximum, Set(events.map(\.id)).count == events.count,
      events.allSatisfy({ event in
        kinds.contains(event.kind)
          && EventRelations.hasCompatibleChannel(event, channelID: channelID)
      })
    else { throw BuzzError.invalidResponse }
    guard events.allSatisfy({ $0.hasValidIDAndSignature() }) else { throw BuzzError.invalidEvent }
  }
}
