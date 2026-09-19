import XCTest

@testable import Buzz

final class NativePreferencesTests: XCTestCase {
  @MainActor func testAppearanceSnapshotPersistsAndRestoresWithoutRelayState() {
    let suiteName = "BuzzNativePreferencesTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let preferences = NativePreferences(defaults: defaults)
    XCTAssertEqual(preferences.scheme, .system)
    XCTAssertEqual(preferences.accent, .indigo)
    preferences.setScheme(.dark)
    preferences.setAccent(.orange)
    preferences.setMuted(true, channelID: "channel-muted")
    preferences.setStarred(true, channelID: "channel-starred")

    let restored = NativePreferences(defaults: defaults)
    XCTAssertEqual(restored.scheme, .dark)
    XCTAssertEqual(restored.accent, .orange)
    XCTAssertEqual(restored.colorScheme, .dark)
    XCTAssertTrue(restored.mutedChannels.contains("channel-muted"))
    XCTAssertTrue(restored.starredChannels.contains("channel-starred"))
  }
}
