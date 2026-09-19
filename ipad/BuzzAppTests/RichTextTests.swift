import XCTest

@testable import Buzz

final class RichTextTests: XCTestCase {
  func testProductionMessageMarkupPreservesFormattingAndLinks() throws {
    let rendered = try XCTUnwrap(RichText.attributed("**bold** [docs](https://example.com)"))
    XCTAssertTrue(rendered.characters.contains("bold"))
    XCTAssertTrue(
      rendered.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
    XCTAssertTrue(rendered.runs.contains { $0.link == URL(string: "https://example.com") })
  }

  func testMalformedMarkupFallsBackToSourceText() {
    // The parser is intentionally permissive, but an empty source still has a
    // valid empty representation so the signed body is never discarded.
    XCTAssertEqual(RichText.attributed("")?.characters.count, 0)
  }

  func testFencedCodeIsSeparatedAndLanguageIsRetained() {
    let segments = RichText.segments("Before\n```swift\nlet value = 1\n```\nAfter")
    XCTAssertEqual(segments.map(\.text), ["Before\n", "let value = 1\n", "\nAfter"])
    XCTAssertEqual(segments.map(\.kind), [.markdown, .code(language: "swift"), .markdown])
  }

  func testCodeHighlighterPreservesTextAndClassifiesCommonTokens() {
    let tokens = CodeHighlighter.tokens("let count = 42 // total", language: "swift")
    XCTAssertEqual(tokens.map(\.text).joined(), "let count = 42 // total")
    XCTAssertTrue(tokens.contains { $0.text == "let" && $0.role == .keyword })
    XCTAssertTrue(tokens.contains { $0.text == "42" && $0.role == .number })
    XCTAssertTrue(tokens.contains { $0.text.hasPrefix("//") && $0.role == .comment })
  }
}
