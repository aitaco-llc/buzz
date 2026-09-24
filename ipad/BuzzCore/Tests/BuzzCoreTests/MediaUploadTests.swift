import CryptoKit
import Foundation
import Testing

@testable import BuzzCore

struct MediaUploadTests {
  @Test func uploadsWithBoundHashAndBlossomAuth() async throws {
    let identity = try Identity(hex: String(repeating: "0", count: 63) + "1")
    let community = try Community(url: "https://media.example", name: "Media")
    let bytes = Data("hello".utf8)
    let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    UploadURLProtocol.handler = { request in
      #expect(request.httpMethod == "PUT")
      #expect(request.value(forHTTPHeaderField: "X-SHA-256") == hash)
      #expect(request.value(forHTTPHeaderField: "Content-Type") == "image/png")
      #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Nostr ") == true)
      let response = HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      let payload = Data(
        "{\"url\":\"https://media.example/media/\(hash).png\",\"sha256\":\"\(hash)\",\"size\":5,\"type\":\"image/png\",\"uploaded\":1}"
          .utf8)
      return (response, payload)
    }
    defer { UploadURLProtocol.handler = nil }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [UploadURLProtocol.self]
    let client = BlossomClient(
      community: community, identity: identity, configuration: configuration)
    let descriptor = try await client.upload(bytes, mimeType: "image/png")
    #expect(descriptor.sha256 == hash)
    #expect(
      descriptor.imetaTag() == [
        "imeta", "url https://media.example/media/\(hash).png", "m image/png", "x \(hash)",
        "size 5",
      ])
  }
}

@Suite struct ImetaTagTests {
  /// The tag is what the relay and every client read an attachment out of, so
  /// its field order and its handling of the optional members are pinned here.
  @Test func everyOptionalFieldAppearsInOrderAndOnlyWhenPresent() {
    let full = BlobDescriptor(
      url: "https://media.example/a.png", sha256: "abc", size: 5, type: "image/png",
      uploaded: 1, dim: "8x6", blurhash: "LEHV6n", thumb: "https://media.example/t.png",
      duration: 1.5)
    #expect(
      full.imetaTag(filename: "shot.png") == [
        "imeta", "url https://media.example/a.png", "m image/png", "x abc", "size 5",
        "dim 8x6", "blurhash LEHV6n", "thumb https://media.example/t.png", "duration 1.5",
        "filename shot.png",
      ])

    let bare = BlobDescriptor(
      url: "https://media.example/a.png", sha256: "abc", size: 5, type: "image/png", uploaded: 1)
    #expect(
      bare.imetaTag() == [
        "imeta", "url https://media.example/a.png", "m image/png", "x abc", "size 5",
      ])
  }
}

private final class UploadURLProtocol: URLProtocol {
  nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    guard let handler = Self.handler, let client else { return }
    let (response, data) = handler(request)
    client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client.urlProtocol(self, didLoad: data)
    client.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
