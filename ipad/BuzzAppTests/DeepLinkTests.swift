import XCTest

@testable import Buzz

final class DeepLinkTests: XCTestCase {
  @MainActor func testMessageDeepLinkParsesChannelAndEvent() throws {
    let model = AppModel()
    model.handle(url: try XCTUnwrap(URL(string: "buzz://message?channel=design&id=abc123")))
    XCTAssertEqual(model.pendingDeepLink, BuzzDeepLink(channelID: "design", eventID: "abc123"))
    model.handle(url: try XCTUnwrap(URL(string: "https://example.com/message?channel=wrong&id=x")))
    XCTAssertEqual(model.pendingDeepLink, BuzzDeepLink(channelID: "design", eventID: "abc123"))
  }

  @MainActor func testMessageDeepLinkRoundTripsThroughCanonicalURL() throws {
    let original = BuzzDeepLink(channelID: "team design", eventID: "abc/123")
    let model = AppModel()
    model.handle(url: try XCTUnwrap(original.url))
    XCTAssertEqual(model.pendingDeepLink, original)
  }
}
