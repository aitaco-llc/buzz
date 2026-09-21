import BuzzPushKit
import XCTest

@testable import Buzz

final class PushNavigationTests: XCTestCase {
  @MainActor func testNotificationTargetUsesExistingMessageDeepLinkPath() {
    let model = AppModel()
    let target = BuzzPushNavigationTarget(
      eventID: String(repeating: "a", count: 64),
      communityID: "https://push.example",
      channelID: "general")
    model.handle(notification: target)
    XCTAssertEqual(
      model.pendingDeepLink,
      BuzzDeepLink(channelID: "general", eventID: String(repeating: "a", count: 64)))
  }
}
