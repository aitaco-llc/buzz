import BuzzCore
import XCTest

@testable import Buzz

final class AitacoCommunityTests: XCTestCase {
  func testOnlyAitacoRelayIsAllowedInRelease() throws {
    XCTAssertTrue(Aitaco.allows(try Community(url: "https://buzz.aitaco.co", name: "")))
    XCTAssertTrue(Aitaco.allows(try Community(url: "wss://BUZZ.aitaco.co:443", name: "")))
    XCTAssertFalse(Aitaco.allows(try Community(url: "https://buzz.aitaco.co:8443", name: "")))
    XCTAssertFalse(Aitaco.allows(try Community(url: "https://buzz.example", name: "")))
    XCTAssertFalse(Aitaco.allows(try Community(url: "https://evil-buzz.aitaco.co", name: "")))
  }

  func testRequireNamesTheCommunityAndRefusesOthers() throws {
    let community = try Aitaco.require(Community(url: "wss://buzz.aitaco.co", name: "Buzz"))
    XCTAssertEqual(community.origin.absoluteString, "https://buzz.aitaco.co")
    XCTAssertEqual(community.name, "aitaco")
    XCTAssertThrowsError(try Aitaco.require(Community(url: "https://buzz.example", name: ""))) {
      XCTAssertEqual($0.localizedDescription, Aitaco.foreignCommunityMessage)
    }
  }

  @MainActor func testForeignInviteLinkIsRefusedBeforeAnyClaim() throws {
    let model = AppModel()
    model.handle(url: try XCTUnwrap(URL(string: "https://buzz.example/invite/abc123")))
    XCTAssertNil(model.pendingInvite)
    XCTAssertEqual(model.error, Aitaco.foreignCommunityMessage)

    model.error = nil
    model.handle(url: try XCTUnwrap(URL(string: "https://buzz.aitaco.co/invite/abc123")))
    XCTAssertEqual(model.pendingInvite?.code, "abc123")
    XCTAssertNil(model.error)
  }
}
