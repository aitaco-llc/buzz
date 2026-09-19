import XCTest

@testable import Buzz

final class InvitesTests: XCTestCase {
  func testCanonicalInviteNormalizesToRelayOriginAndBuildsShareURL() throws {
    let url = try XCTUnwrap(URL(string: "https://relay.example/invite/abc123"))
    let invite = try XCTUnwrap(InviteLink.parse(url))
    XCTAssertEqual(invite.relay.absoluteString, "https://relay.example")
    XCTAssertEqual(invite.code, "abc123")
    XCTAssertEqual(invite.shareURL.absoluteString, "https://relay.example/invite/abc123")
  }

  func testCustomJoinInviteConvertsWebSocketOrigin() throws {
    let url = try XCTUnwrap(
      URL(string: "buzz://join?relay=wss%3A%2F%2Frelay.example&code=one-time"))
    let invite = try XCTUnwrap(InviteLink.parse(url))
    XCTAssertEqual(invite.relay.absoluteString, "https://relay.example")
    XCTAssertEqual(invite.code, "one-time")
  }

  func testMalformedInviteDoesNotBecomeAJoinTarget() throws {
    let urls = [
      "https://relay.example/invite/",
      "https://relay.example/other/code",
      "buzz://join?relay=https%3A%2F%2Frelay.example&code=bad",
      "https://user:password@relay.example/invite/code",
      "buzz://join?relay=wss%3A%2F%2Frelay.example&code=ok&unexpected=1",
    ]
    for raw in urls {
      let url = try XCTUnwrap(URL(string: raw))
      XCTAssertNil(InviteLink.parse(url), raw)
    }
  }
}
