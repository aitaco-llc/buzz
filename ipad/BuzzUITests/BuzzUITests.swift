import UIKit
import XCTest

final class BuzzUITests: XCTestCase {
  @MainActor func testThreadFetchesExistingEditsReactionsAndTheirDeletions() throws {
    XCUIDevice.shared.orientation = .landscapeLeft
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing", "--reset-test-data", "--thread-aux-fixture"]
    app.launch()
    let channel = app.staticTexts["channel-general"]
    XCTAssertTrue(channel.waitForExistence(timeout: 15))
    channel.tap()
    let open = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'thread-' "))
      .firstMatch
    XCTAssertTrue(open.waitForExistence(timeout: 10))
    open.tap()
    let thread = app.scrollViews["thread-history"]
    XCTAssertTrue(thread.waitForExistence(timeout: 5))
    let edited = thread.staticTexts["This reply was edited before this iPad opened the thread."]
    XCTAssertTrue(edited.waitForExistence(timeout: 10))
    XCTAssertEqual(
      app.otherElements["channel-toolbar"].buttons.matching(identifier: "Refresh").count, 1)
    XCTAssertEqual(
      app.otherElements["thread-toolbar"].buttons.matching(identifier: "Refresh").count, 1)
    XCTAssertFalse(thread.staticTexts["This edit was withdrawn."].exists)
    XCTAssertFalse(thread.staticTexts["Removed thread reply"].exists)
    let heart = thread.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH 'reaction-' AND identifier ENDSWITH '-❤️' ")
    )
    .firstMatch
    XCTAssertTrue(heart.waitForExistence(timeout: 5))
    XCTAssertEqual(heart.value as? String, "You reacted")
    XCTAssertTrue(heart.label.contains("1 person"))
    XCTAssertFalse(
      thread.buttons.matching(
        NSPredicate(format: "identifier BEGINSWITH 'reaction-' AND identifier ENDSWITH '-👍' ")
      )
      .firstMatch.exists)
    let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    screenshot.name = "Thread history with edits and reactions"
    screenshot.lifetime = .keepAlways
    add(screenshot)
    app.otherElements["thread-toolbar"].buttons["Close thread"].tap()
    expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: thread)
    waitForExpectations(timeout: 5)
    XCTAssertTrue(app.otherElements["channel-toolbar"].exists)
  }

  @MainActor func testReactionPickerAddsRemovesAndRestoresReactionAfterRelaunch() throws {
    XCUIDevice.shared.orientation = .landscapeLeft
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing", "--reset-test-data"]
    app.launch()
    let channel = app.staticTexts["channel-general"]
    XCTAssertTrue(channel.waitForExistence(timeout: 15))
    channel.tap()
    let addButton = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH 'add-reaction-' ")
    ).firstMatch
    XCTAssertTrue(addButton.waitForExistence(timeout: 10))
    let messageID = String(addButton.identifier.dropFirst("add-reaction-".count))
    let pill = app.buttons["reaction-\(messageID)-❤️"]

    @MainActor func chooseHeart() {
      app.buttons["add-reaction-\(messageID)"].tap()
      let search = app.searchFields.firstMatch
      XCTAssertTrue(search.waitForExistence(timeout: 5))
      search.tap()
      search.typeText("heart")
      let heart = app.buttons["emoji-choice-❤️"]
      XCTAssertTrue(heart.waitForExistence(timeout: 10))
      let picker = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
      picker.name = "Native emoji search"
      picker.lifetime = .keepAlways
      add(picker)
      heart.tap()
      XCTAssertTrue(pill.waitForExistence(timeout: 10))
    }

    chooseHeart()
    XCTAssertEqual(pill.value as? String, "You reacted")
    XCTAssertTrue(pill.label.contains("1 person"))
    let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    screenshot.name = "Native reaction pills"
    screenshot.lifetime = .keepAlways
    add(screenshot)
    pill.tap()
    expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: pill)
    waitForExpectations(timeout: 10)
    chooseHeart()
    app.terminate()
    app.launchArguments = ["--ui-testing"]
    app.launch()
    XCTAssertTrue(channel.waitForExistence(timeout: 15))
    channel.tap()
    XCTAssertTrue(pill.waitForExistence(timeout: 10))
    XCTAssertEqual(pill.value as? String, "You reacted")
    XCTAssertTrue(pill.label.contains("1 person"))
  }

  @MainActor func testOlderHistoryRetriesFailedPageAndReachesOldestMessage() throws {
    XCUIDevice.shared.orientation = .landscapeLeft
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing", "--reset-test-data", "--history-fixture"]
    app.launch()
    let channel = app.staticTexts["channel-engineering"]
    XCTAssertTrue(channel.waitForExistence(timeout: 15))
    channel.tap()
    XCTAssertTrue(app.staticTexts["History message 120"].waitForExistence(timeout: 10))
    app.buttons["Older messages"].tap()
    let older = app.buttons["load-older-messages"]
    XCTAssertTrue(older.waitForExistence(timeout: 5))
    older.tap()
    XCTAssertTrue(app.staticTexts["history-error"].waitForExistence(timeout: 5))
    XCTAssertEqual(older.label, "Retry history")
    older.tap()
    let noError = NSPredicate(format: "exists == false")
    expectation(for: noError, evaluatedWith: app.staticTexts["history-error"])
    waitForExpectations(timeout: 10)
    app.buttons["Older messages"].tap()
    XCTAssertTrue(older.waitForExistence(timeout: 5))
    older.tap()
    app.buttons["Older messages"].tap()
    XCTAssertTrue(app.staticTexts["Oldest history message"].waitForExistence(timeout: 5))
    XCTAssertFalse(older.exists)
    let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    screenshot.name = "Older conversation history"
    screenshot.lifetime = .keepAlways
    add(screenshot)
    app.buttons["Latest"].tap()
    XCTAssertTrue(app.staticTexts["History message 120"].waitForExistence(timeout: 5))
  }

  @MainActor func testBrowseJoinAndLeaveChannelPreservesDraft() throws {
    XCUIDevice.shared.orientation = .landscapeLeft
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing", "--reset-test-data"]
    app.launch()
    XCTAssertTrue(app.buttons["Browse channels"].waitForExistence(timeout: 15))
    app.buttons["Browse channels"].tap()
    XCTAssertTrue(app.buttons["Join watercooler"].waitForExistence(timeout: 10))
    let directory = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    directory.name = "Browse open channels"
    directory.lifetime = .keepAlways
    add(directory)
    app.buttons["Join watercooler"].tap()
    let gone = NSPredicate(format: "exists == false")
    expectation(for: gone, evaluatedWith: app.buttons["Join watercooler"])
    waitForExpectations(timeout: 10)
    app.buttons["Done"].tap()
    let channel = app.staticTexts["channel-watercooler"]
    XCTAssertTrue(channel.waitForExistence(timeout: 5))
    channel.tap()
    let composer = app.textFields["message-composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    composer.tap()
    composer.typeText("Keep my channel draft")
    app.buttons["Channel details"].tap()
    app.buttons["Leave channel"].tap()
    // UIKit exposes the popover action and its nested button with the same identifier.
    let confirm = app.buttons.matching(identifier: "confirm-leave-channel").firstMatch
    XCTAssertTrue(confirm.waitForExistence(timeout: 5))
    confirm.tap()
    expectation(for: gone, evaluatedWith: channel)
    waitForExpectations(timeout: 10)
    app.buttons["Browse channels"].tap()
    XCTAssertTrue(app.buttons["Join watercooler"].waitForExistence(timeout: 10))
    app.buttons["Join watercooler"].tap()
    expectation(for: gone, evaluatedWith: app.buttons["Join watercooler"])
    waitForExpectations(timeout: 10)
    app.buttons["Done"].tap()
    XCTAssertTrue(channel.waitForExistence(timeout: 5))
    channel.tap()
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    XCTAssertEqual(composer.value as? String, "Keep my channel draft")
  }

  @MainActor func testPairingEntryRejectsInvalidLinkAndAllowsRetry() throws {
    XCUIDevice.shared.orientation = .landscapeLeft
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing", "--signed-out", "--reset-test-data"]
    app.launch()
    XCTAssertTrue(app.buttons["connect-community"].waitForExistence(timeout: 15))
    app.buttons["connect-community"].tap()
    XCTAssertTrue(app.secureTextFields["identity-private-key"].waitForExistence(timeout: 5))
    let relayHost = NSPredicate(format: "label CONTAINS %@", "buzz.aitaco.co")
    XCTAssertTrue(app.descendants(matching: .any).matching(relayHost).firstMatch.exists)
    app.buttons["Pair with Desktop"].tap()
    let link = app.secureTextFields["Desktop pairing link"]
    XCTAssertTrue(link.waitForExistence(timeout: 5))
    app.buttons["Scan pairing QR code"].tap()
    XCTAssertTrue(app.staticTexts["Camera unavailable"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["Try camera again"].exists)
    let camera = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    camera.name = "Pairing camera fallback"
    camera.lifetime = .keepAlways
    add(camera)
    app.buttons["Paste a link instead"].tap()
    XCTAssertTrue(link.waitForExistence(timeout: 5))
    link.tap()
    link.typeText("not-a-pairing-link")
    app.buttons["Pair with desktop"].tap()
    XCTAssertTrue(app.staticTexts["pairing-error"].waitForExistence(timeout: 5))
    XCTAssertTrue(link.exists)
    XCTAssertFalse(app.staticTexts["pairing-code"].exists)
    link.tap()
    link.typeText("another-invalid-link")
    XCTAssertTrue(app.buttons["Pair with desktop"].isEnabled)
    app.buttons["Pair with desktop"].tap()
    XCTAssertTrue(app.staticTexts["pairing-error"].waitForExistence(timeout: 5))
  }

  /// The reported defect rendered a heading, a list and two paragraphs as one
  /// run-together line. Separate `staticTexts` are what proves the breaks are
  /// back: with the bug there is a single element holding the whole body.
  ///
  /// Order keeps the two halves apart. The preview is checked while nothing has
  /// been sent, and the message is checked once the draft — and so the preview —
  /// is empty, so neither assertion can be satisfied by the other surface.
  @MainActor func testAgentStyleMarkdownRendersItsBreaksInMessageAndPreview() throws {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing", "--reset-test-data"]
    app.launch()
    let general = app.staticTexts["general"]
    XCTAssertTrue(general.waitForExistence(timeout: 15))
    general.tap()

    let composer = app.textFields["message-composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 10))
    composer.tap()
    composer.typeText(
      "Opening paragraph.\n\n## Findings\n\n- first bullet\n- second bullet\n\n"
        + "Closing paragraph.\n\n```swift\nlet value = 1\n```")

    app.buttons["composer-preview-toggle"].tap()
    XCTAssertTrue(app.otherElements["composer-preview"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Findings"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["first bullet"].exists)
    XCTAssertTrue(app.staticTexts["second bullet"].exists)
    XCTAssertTrue(app.staticTexts["Closing paragraph."].exists)

    app.buttons["Send message"].tap()
    // Sending clears the draft, so the preview empties and every match below is
    // the rendered message.
    XCTAssertTrue(app.staticTexts["Nothing to preview yet."].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Opening paragraph."].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Findings"].exists)
    XCTAssertTrue(app.staticTexts["first bullet"].exists)
    XCTAssertTrue(app.staticTexts["second bullet"].exists)
    XCTAssertTrue(app.staticTexts["Closing paragraph."].exists)
    // The fenced block keeps its own path, so its chrome is still present.
    XCTAssertTrue(app.buttons["Copy code"].exists)
    add(screenshot(app, named: "message-markdown"))
  }

  /// The paste control is the only image-paste affordance, so its gating is the
  /// whole feature: it must not occupy the composer when there is nothing to
  /// paste, and it must appear as soon as there is.
  ///
  /// `UIPasteboard.general` is shared across processes on the simulator, so the
  /// runner can stage the pasteboard the app will read.
  @MainActor func testPasteControlAppearsOnlyWhileAnImageIsOnThePasteboard() throws {
    UIPasteboard.general.items = []
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing", "--reset-test-data"]
    app.launch()
    let general = app.staticTexts["general"]
    XCTAssertTrue(general.waitForExistence(timeout: 15))
    general.tap()
    XCTAssertTrue(app.textFields["message-composer"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.otherElements["paste-image"].exists)

    let swatch = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 9)).image { context in
      UIColor.systemPink.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 12, height: 9))
    }
    UIPasteboard.general.image = swatch
    // The app refreshes on foreground, which is what happens after a real
    // screenshot is copied in another app.
    XCUIDevice.shared.press(.home)
    app.activate()
    XCTAssertTrue(app.otherElements["paste-image"].waitForExistence(timeout: 10))
    add(screenshot(app, named: "composer-paste-control"))
    UIPasteboard.general.items = []
  }

  @MainActor private func screenshot(_ app: XCUIApplication, named name: String) -> XCTAttachment {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    return attachment
  }

  @MainActor func testComposeThreadSearchAndDurableDraft() throws {
    XCUIDevice.shared.orientation = .landscapeLeft
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing", "--reset-test-data"]
    app.launch()
    let general = app.staticTexts["general"]
    XCTAssertTrue(general.waitForExistence(timeout: 15))
    general.tap()
    let composer = app.textFields["message-composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 10))
    composer.tap()
    composer.typeText("A native iPad message")
    app.buttons["Send message"].tap()
    XCTAssertTrue(app.staticTexts["A native iPad message"].waitForExistence(timeout: 10))
    let threadButton = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'thread-' "))
      .firstMatch
    threadButton.tap()
    let reply = app.textFields["thread-composer"]
    XCTAssertTrue(reply.waitForExistence(timeout: 5))
    reply.tap()
    reply.typeText("And a native reply")
    app.buttons["Send reply"].tap()
    XCTAssertTrue(app.staticTexts["And a native reply"].waitForExistence(timeout: 5))
    composer.tap()
    composer.typeText("Draft survives restart")
    // Switching community/navigation and backgrounding await the same production draft writer.
    XCUIDevice.shared.press(.home)
    app.activate()
    app.terminate()
    app.launchArguments = ["--ui-testing"]
    app.launch()
    XCTAssertTrue(general.waitForExistence(timeout: 10))
    general.tap()
    XCTAssertTrue(composer.waitForExistence(timeout: 10))
    XCTAssertEqual(composer.value as? String, "Draft survives restart")
    XCTAssertTrue(app.staticTexts["A native iPad message"].exists)
    app.buttons["Search"].tap()
    let search = app.searchFields.firstMatch
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    search.tap()
    search.typeText("native iPad message")
    XCTAssertTrue(app.staticTexts["A native iPad message"].waitForExistence(timeout: 10))
    app.buttons["Done"].tap()
    XCUIDevice.shared.orientation = .portrait
    let portrait = NSPredicate { _, _ in app.frame.height > app.frame.width }
    expectation(for: portrait, evaluatedWith: app)
    waitForExpectations(timeout: 5)
    let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    screenshot.name = "Native iPad conversation"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }
}
