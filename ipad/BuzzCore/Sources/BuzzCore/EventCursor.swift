import Foundation

/// A composite cursor in the relay's `created_at DESC, id ASC` history order.
public struct EventCursor: Codable, Equatable, Sendable {
  /// Inclusive timestamp component.
  public let timestamp: Int
  /// Exclusive event-ID component within the timestamp.
  public let eventID: String

  /// Captures a verified event's position.
  public init(event: Event) {
    timestamp = event.createdAt
    eventID = event.id
  }

  private enum CodingKeys: String, CodingKey {
    case timestamp = "created_at"
    case eventID = "id"
  }

  /// Rejects malformed relay-provided cursor values rather than resetting to the head.
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    timestamp = try values.decode(Int.self, forKey: .timestamp)
    eventID = try values.decode(String.self, forKey: .eventID)
    guard timestamp >= 0, eventID.count == 64,
      eventID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else { throw BuzzError.invalidResponse }
  }

  /// Whether an event belongs strictly after this position when paging into older history.
  public func containsOlder(_ event: Event) -> Bool {
    event.createdAt < timestamp || (event.createdAt == timestamp && event.id > eventID)
  }

  /// Whether another cursor advances into older history.
  public func precedes(_ next: EventCursor) -> Bool {
    next.timestamp < timestamp || (next.timestamp == timestamp && next.eventID > eventID)
  }

  /// Exact relay history order, including ascending IDs within one second.
  public static func relayOrder(_ lhs: Event, _ rhs: Event) -> Bool {
    lhs.createdAt == rhs.createdAt ? lhs.id < rhs.id : lhs.createdAt > rhs.createdAt
  }
}
