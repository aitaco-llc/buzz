import BuzzCore
import UIKit
import XCTest
import os

@testable import Buzz

final class EmojiImagesTests: XCTestCase {
  @MainActor func testPublicImageRequestsOmitCredentialsCacheThumbnailsAndRejectOversizeImages()
    async throws
  {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [EmojiImageProtocol.self]
    config.httpAdditionalHeaders = ["Authorization": "must-not-send", "Cookie": "must-not-send"]
    let loader = EmojiImages(configuration: config)
    let png = try XCTUnwrap(
      UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { context in
        UIColor.systemIndigo.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
      }.pngData())
    EmojiImageProtocol.install(png, length: png.count)
    let url = try XCTUnwrap(URL(string: "https://emoji.example/first.png"))
    let first = try await loader.thumbnail(url)
    let second = try await loader.thumbnail(url)
    XCTAssertEqual(first, second)
    XCTAssertNotNil(UIImage(data: first))
    XCTAssertEqual(EmojiImageProtocol.requestCount, 1)
    XCTAssertFalse(EmojiImageProtocol.sentCredentials)

    EmojiImageProtocol.install(png, length: 1024 * 1024 + 1)
    do {
      _ = try await loader.thumbnail(XCTUnwrap(URL(string: "https://emoji.example/too-large.png")))
      XCTFail("An oversized response header must be rejected before decoding its valid image")
    } catch {}
    let large = try XCTUnwrap(
      UIGraphicsImageRenderer(size: CGSize(width: 1025, height: 1)).image { context in
        context.fill(CGRect(x: 0, y: 0, width: 1025, height: 1))
      }.pngData())
    EmojiImageProtocol.install(large, length: large.count)
    do {
      _ = try await loader.thumbnail(XCTUnwrap(URL(string: "https://emoji.example/too-wide.png")))
      XCTFail("Oversized decoded dimensions must be rejected")
    } catch {}
  }
}

private final class EmojiImageProtocol: URLProtocol {
  private struct State: Sendable {
    var data = Data()
    var length = 0
    var requests = 0
    var sentCredentials = false
  }
  private static let state = OSAllocatedUnfairLock(initialState: State())
  static var requestCount: Int { state.withLock { $0.requests } }
  static var sentCredentials: Bool { state.withLock { $0.sentCredentials } }
  static func install(_ data: Data, length: Int) {
    state.withLock { $0 = State(data: data, length: length) }
  }
  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "emoji.example"
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let credentials =
      request.value(forHTTPHeaderField: "Authorization") != nil
      || request.value(forHTTPHeaderField: "Cookie") != nil
    let payload = Self.state.withLock { state in
      state.requests += 1
      state.sentCredentials = credentials
      return (state.data, state.length)
    }
    guard let url = request.url,
      let response = HTTPURLResponse(
        url: url, statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "image/png", "Content-Length": String(payload.1)])
    else { return }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: payload.0)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
