import Foundation

/// A community's canonical origin; the host remains the tenant boundary.
public struct Community: Codable, Identifiable, Equatable, Sendable {
  /// Stable local identity, independent of the display name.
  public var id: String { origin.absoluteString }
  /// Canonical HTTP origin used by the Nostr bridge.
  public let origin: URL
  /// User-supplied local display name.
  public let name: String

  /// Accepts secure production origins and plain HTTP only for local development.
  public init(url: String, name: String) throws {
    guard
      var components = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
      let host = components.host?.lowercased(), !host.isEmpty,
      components.user == nil, components.password == nil,
      components.query == nil, components.fragment == nil,
      components.path.isEmpty || components.path == "/"
    else { throw BuzzError.invalidRelay }
    switch components.scheme?.lowercased() {
    case "wss", "https": components.scheme = "https"
    case "ws", "http":
      guard ["localhost", "127.0.0.1", "::1"].contains(host) else { throw BuzzError.invalidRelay }
      components.scheme = "http"
    default: throw BuzzError.invalidRelay
    }
    components.host = host
    components.path = ""
    if (components.scheme == "https" && components.port == 443)
      || (components.scheme == "http" && components.port == 80)
    {
      components.port = nil
    }
    guard let origin = components.url else { throw BuzzError.invalidRelay }
    self.origin = origin
    self.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? host : name
  }
}

/// A bounded Nostr REQ filter. All queries explicitly select event kinds.
public struct EventFilter: Encodable, Sendable {
  /// Explicit kind allowlist for this query.
  public let kinds: [Int]
  /// Optional author public keys.
  public var authors: [String]?
  /// Optional exact event IDs.
  public var ids: [String]?
  /// Tag keys without the wire `#` prefix.
  public var tags: [String: [String]]
  /// Relay-side NIP-50 full-text query.
  public var search: String?
  /// Inclusive upper timestamp bound.
  public var until: Int?
  /// Inclusive lower timestamp bound.
  public var since: Int?
  /// Buzz's exclusive event-ID bound paired with `until` for timestamp ties.
  public var beforeID: String?
  /// Maximum number of events requested per page.
  public var limit: Int
  /// Requests NIP-CW top-level rows and the relay's signed page bounds.
  public var topLevel: Bool?
  /// Requests edits, reactions and deletions associated with window rows.
  public var includeAux: Bool?
  /// Requests relay-signed thread summaries for window rows.
  public var includeSummaries: Bool?
  /// Maximum ancestry depth for a recursive thread query.
  public var depthLimit: Int?
  /// Exclusive ascending timestamp component for thread replies.
  public var threadCursor: Int?
  /// Exclusive ascending event-ID component for tied thread replies.
  public var threadCursorID: String?

  /// Creates a filter with a maximum page size of 500.
  public init(
    kinds: [Int], authors: [String]? = nil, ids: [String]? = nil,
    tags: [String: [String]] = [:], search: String? = nil,
    until: Int? = nil, since: Int? = nil, beforeID: String? = nil, limit: Int = 100
  ) {
    self.kinds = kinds
    self.authors = authors
    self.ids = ids
    self.tags = tags
    self.search = search
    self.until = until
    self.since = since
    self.beforeID = beforeID
    self.limit = min(max(limit, 1), 500)
  }

  private struct Key: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
  }

  /// Encodes the standard Nostr filter representation.
  public func encode(to encoder: any Encoder) throws {
    guard !kinds.isEmpty else { throw BuzzError.invalidResponse }
    var values = encoder.container(keyedBy: Key.self)
    try values.encode(kinds, forKey: Key("kinds"))
    try values.encodeIfPresent(authors, forKey: Key("authors"))
    try values.encodeIfPresent(ids, forKey: Key("ids"))
    try values.encodeIfPresent(search, forKey: Key("search"))
    try values.encodeIfPresent(until, forKey: Key("until"))
    try values.encodeIfPresent(since, forKey: Key("since"))
    try values.encodeIfPresent(beforeID, forKey: Key("before_id"))
    try values.encode(limit, forKey: Key("limit"))
    try values.encodeIfPresent(topLevel, forKey: Key("top_level"))
    try values.encodeIfPresent(includeAux, forKey: Key("include_aux"))
    try values.encodeIfPresent(includeSummaries, forKey: Key("include_summaries"))
    try values.encodeIfPresent(depthLimit, forKey: Key("depth_limit"))
    try values.encodeIfPresent(threadCursor, forKey: Key("thread_cursor"))
    try values.encodeIfPresent(threadCursorID, forKey: Key("thread_cursor_id"))
    for (key, value) in tags { try values.encode(value, forKey: Key("#" + key)) }
  }
}

/// Injectable network boundary shared by synchronization and the durable outbox.
public protocol RelayTransport: Sendable {
  /// Relay signing authority advertised by the origin's NIP-11 `self` field.
  func authority() async throws -> String
  /// Returns signature-verified events or throws; errors are never empty success.
  func query(_ filters: [EventFilter]) async throws -> [Event]
  /// Completes only on authoritative acceptance of this exact event ID.
  func publish(_ event: Event) async throws
}

/// Optional command-capable relay transport. Command events return a structured
/// response in the relay receipt message, unlike ordinary durable publishes.
public protocol CommandRelayTransport: RelayTransport {
  func publishCommand(_ event: Event) async throws -> String
}

extension RelayTransport {
  /// Transports without a verified discovery authority fail closed for membership operations.
  public func authority() async throws -> String { throw BuzzError.invalidResponse }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest
  ) async -> URLRequest? { nil }
}

/// NIP-98 authenticated access to Buzz's existing Nostr HTTP bridge.
public actor HTTPRelay: CommandRelayTransport {
  private let community: Community
  private let identity: Identity
  private let session: URLSession
  private let authTag: String?

  /// Binds credentials to exactly one community origin. Redirects are rejected.
  public init(
    community: Community, identity: Identity, authTag: String? = nil,
    configuration: URLSessionConfiguration = .ephemeral
  ) {
    self.community = community
    self.identity = identity
    self.authTag = authTag
    configuration.timeoutIntervalForRequest = 20
    configuration.timeoutIntervalForResource = 30
    configuration.httpMaximumConnectionsPerHost = 4
    session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
  }

  /// Fetches and verifies an explicit set of bounded Nostr filters.
  public func query(_ filters: [EventFilter]) async throws -> [Event] {
    guard !filters.isEmpty, filters.count <= 10 else { throw BuzzError.invalidResponse }
    let data = try await request(path: "query", body: JSONEncoder().encode(filters))
    let events = try JSONDecoder().decode([Event].self, from: data)
    guard events.count <= 5000 else { throw BuzzError.responseTooLarge }
    guard events.allSatisfy({ $0.hasValidIDAndSignature() }) else { throw BuzzError.invalidEvent }
    return events
  }

  /// Fetches NIP-11 without sending identity credentials. Operator `pubkey` is not signing authority.
  public func authority() async throws -> String {
    var request = URLRequest(url: community.origin)
    request.setValue("application/nostr+json", forHTTPHeaderField: "Accept")
    let data = try await response(request, maximum: 256 * 1024)
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard let key = object?["self"] as? String, key.utf8.count == 64,
      Hex.decode(key)?.count == 32
    else { throw BuzzError.invalidResponse }
    return key.lowercased()
  }

  /// Submits the unchanged signed event and checks the relay receipt.
  public func publish(_ event: Event) async throws {
    _ = try await publishReceipt(event)
  }

  public func publishCommand(_ event: Event) async throws -> String {
    let receipt = try await publishReceipt(event)
    return receipt.message
  }

  /// Performs one authenticated JSON POST for relay HTTP workflows that are
  /// intentionally outside the generic Nostr event bridge (for example,
  /// community invite minting and claiming).
  public func postJSON(path: String, body: Data) async throws -> Data {
    guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("..") else {
      throw BuzzError.invalidResponse
    }
    return try await request(path: path, body: body)
  }

  private struct Receipt: Decodable {
    let eventID: String
    let accepted: Bool
    let message: String
    enum CodingKeys: String, CodingKey {
      case eventID = "event_id"
      case accepted, message
    }
  }

  private func publishReceipt(_ event: Event) async throws -> Receipt {
    let data = try await request(path: "events", body: JSONEncoder().encode(event))
    let receipt = try JSONDecoder().decode(Receipt.self, from: data)
    guard receipt.eventID == event.id else { throw BuzzError.invalidResponse }
    guard receipt.accepted else { throw BuzzError.rejected(receipt.message) }
    return receipt
  }

  private func request(path: String, body: Data) async throws -> Data {
    let url = community.origin.appendingPathComponent(path)
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(
      try identity.authorization(url: url, body: body), forHTTPHeaderField: "Authorization")
    if let authTag { request.setValue(authTag, forHTTPHeaderField: "x-auth-tag") }
    return try await response(request, maximum: 8 * 1024 * 1024)
  }

  private func response(_ request: URLRequest, maximum: Int) async throws -> Data {
    let (bytes, response) = try await session.bytes(for: request)
    defer { bytes.task.cancel() }
    guard let response = response as? HTTPURLResponse else { throw BuzzError.invalidResponse }
    guard (200...299).contains(response.statusCode) else {
      throw BuzzError.http(response.statusCode)
    }
    guard response.expectedContentLength <= maximum else { throw BuzzError.responseTooLarge }
    var body = Data()
    for try await byte in bytes {
      guard body.count < maximum else { throw BuzzError.responseTooLarge }
      body.append(byte)
    }
    return body
  }
}
