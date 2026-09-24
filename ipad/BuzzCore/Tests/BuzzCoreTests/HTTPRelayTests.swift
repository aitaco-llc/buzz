import Foundation
import Testing

@testable import BuzzCore

@Suite(.serialized)
struct HTTPRelayTests {
  @Test func discoveryAuthorityUsesNIP11SelfWithoutSendingCredentials() async throws {
    let identity = try Identity(hex: String(repeating: "0", count: 63) + "1")
    let signer = try Identity(hex: String(repeating: "0", count: 63) + "2")
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    let relay = HTTPRelay(
      community: try Community(url: "https://relay.example", name: "Test"), identity: identity,
      authTag: "must-not-be-sent", configuration: configuration)
    StubProtocol.install { request in
      #expect(request.httpMethod == "GET")
      #expect(request.value(forHTTPHeaderField: "Accept") == "application/nostr+json")
      #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
      #expect(request.value(forHTTPHeaderField: "x-auth-tag") == nil)
      return (
        200,
        try JSONSerialization.data(withJSONObject: [
          "self": signer.pubkey, "pubkey": identity.pubkey,
        ])
      )
    }
    #expect(try await relay.authority() == signer.pubkey)
    StubProtocol.install { _ in
      (200, try JSONSerialization.data(withJSONObject: ["pubkey": identity.pubkey]))
    }
    await #expect(throws: BuzzError.invalidResponse) { try await relay.authority() }
  }

  @Test func wireQuerySignsActualRequestAndRejectsForgedEvents() async throws {
    let identity = try Identity(hex: String(repeating: "0", count: 63) + "1")
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    let relay = HTTPRelay(
      community: try Community(url: "https://relay.example", name: "Test"),
      identity: identity, configuration: configuration)
    let event = try identity.sign(kind: 9, content: "actual wire", tags: [["h", "c"]])
    StubProtocol.install { request in
      #expect(request.url?.absoluteString == "https://relay.example/query")
      #expect(request.httpMethod == "POST")
      let auth = try #require(request.value(forHTTPHeaderField: "Authorization"))
      let data = try #require(Data(base64Encoded: String(auth.dropFirst(6))))
      let signedAuth = try JSONDecoder().decode(Event.self, from: data)
      #expect(signedAuth.hasValidIDAndSignature())
      #expect(signedAuth.tag("u") == request.url?.absoluteString)
      return (200, try JSONEncoder().encode([event]))
    }
    #expect(try await relay.query([EventFilter(kinds: [9], tags: ["h": ["c"]])]) == [event])
    StubProtocol.install { _ in
      let forged = Event(
        id: event.id, pubkey: event.pubkey, createdAt: event.createdAt,
        kind: 9, tags: event.tags, content: "forged", sig: event.sig)
      return (200, try JSONEncoder().encode([forged]))
    }
    await #expect(throws: BuzzError.invalidEvent) {
      try await relay.query([EventFilter(kinds: [9])])
    }
  }

  @Test func acceptanceRequiresMatchingIDAndTrueReceipt() async throws {
    let identity = try Identity(hex: String(repeating: "0", count: 63) + "1")
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    let relay = HTTPRelay(
      community: try Community(url: "https://relay.example", name: "Test"),
      identity: identity, configuration: configuration)
    let event = try identity.sign(kind: 9, content: "send", tags: [["h", "c"]])
    StubProtocol.install { request in
      #expect(request.url?.path == "/events")
      return (200, Data("{\"event_id\":\"\(event.id)\",\"accepted\":true,\"message\":\"ok\"}".utf8))
    }
    try await relay.publish(event)
    StubProtocol.install { _ in
      (200, Data("{\"event_id\":\"other\",\"accepted\":true,\"message\":\"ok\"}".utf8))
    }
    await #expect(throws: BuzzError.invalidResponse) { try await relay.publish(event) }
    StubProtocol.install { _ in
      (
        200,
        Data("{\"event_id\":\"\(event.id)\",\"accepted\":false,\"message\":\"not a member\"}".utf8)
      )
    }
    await #expect(throws: BuzzError.rejected("not a member")) { try await relay.publish(event) }
    StubProtocol.install { _ in (403, Data()) }
    await #expect(throws: BuzzError.http(403)) { try await relay.publish(event) }
  }
}

private final class StubProtocol: URLProtocol, @unchecked Sendable {
  typealias Responder = @Sendable (URLRequest) throws -> (Int, Data)
  private static let lock = NSLock()
  nonisolated(unsafe) private static var responder: Responder?
  static func install(_ callback: @escaping Responder) {
    lock.lock()
    defer { lock.unlock() }
    responder = callback
  }
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    Self.lock.lock()
    let callback = Self.responder
    Self.lock.unlock()
    do {
      guard let callback, let url = request.url else { throw BuzzError.invalidResponse }
      let (status, data) = try callback(request)
      guard
        let response = HTTPURLResponse(
          url: url, statusCode: status,
          httpVersion: "HTTP/1.1", headerFields: nil)
      else {
        throw BuzzError.invalidResponse
      }
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
  override func stopLoading() {}
}
