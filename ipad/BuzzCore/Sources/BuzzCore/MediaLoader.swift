import CryptoKit
import Foundation

/// Blossom BUD-01 `t=get` authorization for relay-hosted media reads.
///
/// The relay requires this on every `/media/*` read — `authenticate_media_read`
/// in `crates/buzz-relay/src/api/media.rs`. Its verifier accepts either an `x`
/// tag naming one blob hash or a `server` tag naming the host
/// (`verify_blossom_get_auth`, `crates/buzz-media/src/auth.rs`). We sign the
/// `server` form, so a single event authorizes every blob on the community and
/// the header can be reused instead of re-signed per image.
///
/// Scope matters as much as the signature: `authorizes` is false for any URL
/// that is not this community's `/media/` path, so a profile `picture` or a
/// NIP-30 emoji pointing at a third-party host never receives Buzz credentials.
public struct MediaGetAuth: Sendable {
  /// Matches the Flutter client's lifetime so both sign the same shape.
  static let lifetime = 600
  /// Re-sign this far ahead of expiry, so a request that starts just before the
  /// boundary still arrives well inside the token's validity.
  static let refreshMargin = 60

  private let community: Community
  private let identity: Identity
  private let authTag: String?

  public init(community: Community, identity: Identity, authTag: String? = nil) {
    self.community = community
    self.identity = identity
    self.authTag = authTag
  }

  /// The community's canonical authority. `Community.init` has already
  /// lowercased the host and dropped a default port, which is the same
  /// normalization the relay applies before comparing the `server` tag.
  var serverAuthority: String? {
    community.origin.host.map { host in community.origin.port.map { "\(host):\($0)" } ?? host }
  }

  /// Whether this URL is a relay media read that may carry our credentials.
  public func authorizes(_ url: URL) -> Bool {
    guard let host = url.host?.lowercased(), let origin = community.origin.host?.lowercased(),
      host == origin, url.scheme?.lowercased() == community.origin.scheme,
      normalizedPort(of: url) == normalizedPort(of: community.origin)
    else { return false }
    return url.path.hasPrefix("/media/")
  }

  private func normalizedPort(of url: URL) -> Int {
    url.port ?? (url.scheme?.lowercased() == "http" ? 80 : 443)
  }

  /// Signs a fresh `t=get` event. `signedAt` is injected so tests can pin the
  /// expiration rather than racing the clock.
  func header(signedAt: Date = Date()) throws -> String {
    let now = Int(signedAt.timeIntervalSince1970)
    let event = try identity.sign(
      kind: 24242, content: "Get buzz-media",
      tags: [["t", "get"], ["expiration", "\(now + Self.lifetime)"]]
        + (serverAuthority.map { [["server", $0]] } ?? []),
      at: now)
    // base64url without padding: the relay decodes the header this way, and an
    // unescaped `+` or `/` would not survive the transport.
    let encoded = try JSONEncoder().encode(event).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    return "Nostr \(encoded)"
  }

  /// The NIP-OA credential, sent alongside the signature so an agent seat whose
  /// owner is the relay member passes `enforce_relay_membership`.
  var membershipTag: String? { authTag }
}

/// Fetches relay-hosted media with Blossom read auth attached.
///
/// Blobs are content-addressed and immutable, so the cache is keyed by the
/// `/media/` path — the blob hash — and never by the request headers, which
/// change every time the token is re-signed. Caching by header would miss on
/// every refresh and defeat the memo entirely.
public actor MediaLoader {
  /// Decoding a hostile or merely enormous image is the real risk here, so the
  /// ceiling is enforced against both the advertised and the received length.
  public static let maxBytes = 25 * 1024 * 1024
  private static let cacheBytes = 32 * 1024 * 1024

  private let auth: MediaGetAuth
  private let session: URLSession
  private let now: @Sendable () -> Date

  private var cache: [String: Data] = [:]
  private var order: [String] = []
  private var inflight: [String: Task<Data, Error>] = [:]
  private var memo: (header: String, refreshAt: Date)?

  public init(
    community: Community, identity: Identity, authTag: String? = nil,
    configuration: URLSessionConfiguration = .ephemeral,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    auth = MediaGetAuth(community: community, identity: identity, authTag: authTag)
    configuration.timeoutIntervalForRequest = 20
    configuration.timeoutIntervalForResource = 60
    // The auth event is the only credential this loader carries. Cookies and
    // stored URL credentials would ride along to any redirect target.
    configuration.httpShouldSetCookies = false
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    session = URLSession(configuration: configuration)
    self.now = now
  }

  public func authorizes(_ url: URL) -> Bool { auth.authorizes(url) }

  /// Read-auth headers for a URL, or empty for anything that is not this
  /// community's media. For callers that do their own fetching and so cannot
  /// use `data(for:)` — they still must not hand a credential to another host.
  public func headers(for url: URL) throws -> [String: String] {
    guard auth.authorizes(url) else { return [:] }
    var headers = ["Authorization": try authorization()]
    if let tag = auth.membershipTag { headers["x-auth-tag"] = tag }
    return headers
  }

  /// A local file holding this blob, for players that cannot take a header.
  ///
  /// `AVPlayer(url:)` issues its own unauthenticated requests, so audio and
  /// video 401 exactly like images did. The documented way to authenticate
  /// those is `AVAssetResourceLoaderDelegate`; the header-injection option key
  /// is undocumented and not worth shipping. Because blobs are content
  /// addressed and immutable, fetching once to a hash-named file is equivalent
  /// and far simpler — a repeat play reuses the file rather than the network.
  ///
  /// The cost is that playback waits for a full download, which is fine for a
  /// voice note and poor for a long video. Streaming needs the resource-loader
  /// delegate; this unblocks playback without it.
  public func fileURL(for url: URL) async throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("buzz-media", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // Keep the extension: AVFoundation uses it to pick a demuxer when the
    // response carries no usable content type.
    let name = url.deletingPathExtension().lastPathComponent
    let file = directory.appendingPathComponent(name).appendingPathExtension(url.pathExtension)
    if FileManager.default.fileExists(atPath: file.path) { return file }
    // Streamed to disk rather than routed through `data(for:)`: a video has no
    // business sitting in the image cache, and `download` bounds memory.
    let (temporary, response) = try await session.download(for: try authorizedRequest(for: url))
    guard let http = response as? HTTPURLResponse else { throw BuzzError.invalidResponse }
    guard (200...299).contains(http.statusCode) else {
      try? FileManager.default.removeItem(at: temporary)
      throw BuzzError.http(http.statusCode)
    }
    // `download` deletes its temporary file when this call returns, so the move
    // has to happen here rather than on a later hop.
    try? FileManager.default.removeItem(at: file)
    try FileManager.default.moveItem(at: temporary, to: file)
    return file
  }

  /// Returns the bytes for a relay blob, coalescing concurrent requests for the
  /// same hash so a screen of identical avatars costs one fetch.
  public func data(for url: URL) async throws -> Data {
    let key = cacheKey(for: url)
    if let cached = cache[key] {
      touch(key)
      return cached
    }
    if let existing = inflight[key] { return try await existing.value }
    let task = Task { try await fetch(url) }
    inflight[key] = task
    defer { inflight[key] = nil }
    let data = try await task.value
    store(data, key: key)
    return data
  }

  /// Content-addressed blobs share a cache entry across every message that
  /// embeds them; anything else falls back to the whole URL.
  private func cacheKey(for url: URL) -> String {
    url.path.hasPrefix("/media/") ? url.path : url.absoluteString
  }

  /// Attaches read auth, but only for this community's own media path.
  private func authorizedRequest(for url: URL) throws -> URLRequest {
    var request = URLRequest(url: url)
    guard auth.authorizes(url) else { return request }
    request.setValue(try authorization(), forHTTPHeaderField: "Authorization")
    if let tag = auth.membershipTag { request.setValue(tag, forHTTPHeaderField: "x-auth-tag") }
    return request
  }

  private func fetch(_ url: URL) async throws -> Data {
    let request = try authorizedRequest(for: url)
    // Buffered rather than streamed: `URLSession.bytes` yields one element per
    // byte, and awaiting 25M times to size-cap an image costs far more than the
    // cap saves. `timeoutIntervalForResource` bounds a response that never ends,
    // and the ceiling below rejects one that merely arrives too big.
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw BuzzError.invalidResponse }
    guard (200...299).contains(http.statusCode) else { throw BuzzError.http(http.statusCode) }
    guard data.count <= Self.maxBytes else { throw BuzzError.responseTooLarge }
    guard !data.isEmpty else { throw BuzzError.invalidResponse }
    return data
  }

  /// Re-signs only once the memo is inside its refresh margin. Every widget
  /// build would otherwise cost a Schnorr signature.
  private func authorization() throws -> String {
    if let memo, now() < memo.refreshAt { return memo.header }
    let signedAt = now()
    let header = try auth.header(signedAt: signedAt)
    memo = (
      header,
      signedAt.addingTimeInterval(Double(MediaGetAuth.lifetime - MediaGetAuth.refreshMargin))
    )
    return header
  }

  private func store(_ data: Data, key: String) {
    guard data.count <= Self.cacheBytes else { return }
    cache[key] = data
    touch(key)
    var total = cache.values.reduce(0) { $0 + $1.count }
    while total > Self.cacheBytes, let oldest = order.first {
      total -= cache.removeValue(forKey: oldest)?.count ?? 0
      order.removeFirst()
    }
  }

  private func touch(_ key: String) {
    order.removeAll { $0 == key }
    order.append(key)
  }
}
