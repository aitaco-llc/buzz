import Foundation
import Testing

@testable import BuzzCore

/// The simulator suite missed the 401 because it only ever checked which URL a
/// view asked for. These assert the request the relay actually sees.
@Suite(.serialized)
struct MediaLoaderTests {
  private func identity() throws -> Identity {
    try Identity(hex: String(repeating: "0", count: 63) + "1")
  }

  private func community(_ url: String = "https://relay.example") throws -> Community {
    try Community(url: url, name: "Test")
  }

  private func configuration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MediaURLProtocol.self]
    return configuration
  }

  @Test func relayReadCarriesAVerifiableGetAuthEventNamingTheHost() async throws {
    let identity = try identity()
    let loader = MediaLoader(
      community: try community(), identity: identity, authTag: "owner-credential",
      configuration: configuration())
    MediaURLProtocol.install { request in
      let header = try #require(request.value(forHTTPHeaderField: "Authorization"))
      #expect(header.hasPrefix("Nostr "))
      let event = try decodeAuth(header)
      // The relay verifies all of these before it serves a byte.
      #expect(event.hasValidIDAndSignature())
      #expect(event.pubkey == identity.pubkey)
      #expect(event.kind == 24242)
      #expect(event.content == "Get buzz-media")
      #expect(event.tag("t") == "get")
      #expect(event.tag("server") == "relay.example")
      let expiration = try #require(event.tag("expiration").flatMap(Int.init))
      #expect(expiration > Int(Date().timeIntervalSince1970))
      #expect(request.value(forHTTPHeaderField: "x-auth-tag") == "owner-credential")
      return (200, Data("png".utf8))
    }
    let url = try #require(
      URL(string: "https://relay.example/media/\(String(repeating: "a", count: 64)).png"))
    #expect(try await loader.data(for: url) == Data("png".utf8))
  }

  /// The signed event is base64url with no padding. A stock base64 header would
  /// carry `+` and `/`, which do not survive the transport.
  @Test func authorizationIsUnpaddedBase64URL() async throws {
    let header = try MediaGetAuth(community: try community(), identity: try identity()).header()
    let encoded = String(header.dropFirst("Nostr ".count))
    #expect(!encoded.contains("+"))
    #expect(!encoded.contains("/"))
    #expect(!encoded.contains("="))
    #expect(try decodeAuth(header).tag("t") == "get")
  }

  /// A `picture` or NIP-30 emoji URL may point anywhere. Signing a read for a
  /// third-party host would hand it a credential for our relay.
  @Test func credentialsNeverLeaveTheCommunityMediaPath() async throws {
    let auth = MediaGetAuth(community: try community(), identity: try identity())
    let allowed = ["https://relay.example/media/abc.png", "https://RELAY.example/media/abc.png"]
    let refused = [
      "https://evil.example/media/abc.png",
      "https://relay.example.evil.com/media/abc.png",
      "https://relay.example/query",
      "http://relay.example/media/abc.png",
      "https://relay.example:8443/media/abc.png",
    ]
    for value in allowed {
      #expect(auth.authorizes(try #require(URL(string: value))), "should authorize \(value)")
    }
    for value in refused {
      #expect(!auth.authorizes(try #require(URL(string: value))), "should refuse \(value)")
    }

    let loader = MediaLoader(
      community: try community(), identity: try identity(), authTag: "owner-credential",
      configuration: configuration())
    MediaURLProtocol.install { request in
      #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
      #expect(request.value(forHTTPHeaderField: "x-auth-tag") == nil)
      return (200, Data("gif".utf8))
    }
    let third = try #require(URL(string: "https://emoji.example/media/abc.png"))
    #expect(try await loader.data(for: third) == Data("gif".utf8))
  }

  /// One signed `server` event covers every blob, so the header is memoized —
  /// and the cache is keyed by blob hash so the memo refresh cannot miss it.
  @Test func headerIsReusedUntilItsRefreshMarginAndCacheKeysOnTheBlob() async throws {
    let clock = Clock()
    let loader = MediaLoader(
      community: try community(), identity: try identity(),
      configuration: configuration(), now: { clock.now })
    let seen = Headers()
    MediaURLProtocol.install { request in
      seen.record(request.value(forHTTPHeaderField: "Authorization"))
      return (200, Data("png".utf8))
    }
    let hash = String(repeating: "b", count: 64)
    let first = try #require(URL(string: "https://relay.example/media/\(hash).png"))
    // Same blob reached through a different query string is the same bytes.
    let again = try #require(URL(string: "https://relay.example/media/\(hash).png?v=2"))
    let other = try #require(
      URL(string: "https://relay.example/media/\(String(repeating: "c", count: 64)).png"))

    _ = try await loader.data(for: first)
    _ = try await loader.data(for: again)
    #expect(seen.count == 1, "a cached blob must not be re-fetched")
    _ = try await loader.data(for: other)
    #expect(seen.count == 2)
    #expect(seen.unique.count == 1, "one signature should cover both blobs")

    clock.advance(by: Double(MediaGetAuth.lifetime - MediaGetAuth.refreshMargin) + 1)
    let third = try #require(
      URL(string: "https://relay.example/media/\(String(repeating: "d", count: 64)).png"))
    _ = try await loader.data(for: third)
    #expect(seen.unique.count == 2, "the header must be re-signed past its refresh margin")
  }

  @Test func relayRejectionSurfacesItsStatusRatherThanEmptyBytes() async throws {
    let loader = MediaLoader(
      community: try community(), identity: try identity(), configuration: configuration())
    MediaURLProtocol.install { _ in (401, Data(#"{"error":"authentication failed"}"#.utf8)) }
    let url = try #require(
      URL(string: "https://relay.example/media/\(String(repeating: "e", count: 64)).png"))
    await #expect(throws: BuzzError.http(401)) { try await loader.data(for: url) }
  }
}

private func decodeAuth(_ header: String) throws -> Event {
  var encoded = String(header.dropFirst("Nostr ".count))
    .replacingOccurrences(of: "-", with: "+")
    .replacingOccurrences(of: "_", with: "/")
  while encoded.count % 4 != 0 { encoded += "=" }
  let data = try #require(Data(base64Encoded: encoded))
  return try JSONDecoder().decode(Event.self, from: data)
}

private final class Clock: @unchecked Sendable {
  private let lock = NSLock()
  private var value = Date(timeIntervalSince1970: 1_700_000_000)
  var now: Date { lock.withLock { value } }
  func advance(by interval: TimeInterval) { lock.withLock { value += interval } }
}

private final class Headers: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String] = []
  func record(_ value: String?) { lock.withLock { values.append(value ?? "") } }
  var count: Int { lock.withLock { values.count } }
  var unique: Set<String> { lock.withLock { Set(values) } }
}

private final class MediaURLProtocol: URLProtocol {
  nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?

  static func install(_ handler: @escaping (URLRequest) throws -> (Int, Data)) {
    Self.handler = handler
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let handler = Self.handler, let url = request.url else {
      client?.urlProtocol(self, didFailWithError: BuzzError.invalidResponse)
      return
    }
    do {
      let (status, data) = try handler(request)
      let response = HTTPURLResponse(
        url: url, statusCode: status, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Length": "\(data.count)"])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}
