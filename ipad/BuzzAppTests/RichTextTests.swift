import XCTest

@testable import Buzz

final class RichTextTests: XCTestCase {
  func testEmptyAndOversizeSourcesProduceNoBlocksSoTheViewFallsBackToTheText() {
    // The view renders the signed source verbatim when there are no blocks, so
    // an empty result is the fallback path rather than dropped content.
    XCTAssertEqual(RichText.blocks(""), [])
    XCTAssertEqual(RichText.blocks(String(repeating: "a", count: 256 * 1024 + 1)), [])
  }

  func testFencedCodeIsSeparatedAndLanguageIsRetained() {
    let segments = RichText.segments("Before\n```swift\nlet value = 1\n```\nAfter")
    XCTAssertEqual(segments.map(\.text), ["Before\n", "let value = 1\n", "\nAfter"])
    XCTAssertEqual(segments.map(\.kind), [.markdown, .code(language: "swift"), .markdown])
  }

  func testAgentMessageKeepsParagraphsListAndHeadingOnSeparateBlocks() {
    // The reported defect: a heading, a list and two paragraphs arrived as one
    // wall of text because every block shared a single `Text`.
    let blocks = RichText.blocks(
      "First paragraph.\n\n## Heading\n\n- one\n- two\n\nLast paragraph.")
    XCTAssertEqual(
      blocks.map { String($0.text.characters) },
      ["First paragraph.", "Heading", "one", "two", "Last paragraph."])
    XCTAssertEqual(
      blocks.map(\.kind),
      [
        .paragraph,
        .heading(level: 2),
        .listItem(marker: "\u{2022}", depth: 1),
        .listItem(marker: "\u{2022}", depth: 1),
        .paragraph,
      ])
  }

  func testSoftBreakSurvivesAsALineBreakInsteadOfCollapsingToASpace() {
    let blocks = RichText.blocks("line one\nline two")
    XCTAssertEqual(blocks.count, 1)
    XCTAssertEqual(String(blocks[0].text.characters), "line one\nline two")
  }

  func testOrderedAndNestedListsCarryTheirMarkerAndIndent() {
    let blocks = RichText.blocks("1. first\n2. second\n   - nested")
    XCTAssertEqual(
      blocks.map(\.kind),
      [
        .listItem(marker: "1.", depth: 1),
        .listItem(marker: "2.", depth: 1),
        .listItem(marker: "\u{2022}", depth: 2),
      ])
  }

  func testQuotesAndThematicBreaksAreTheirOwnBlocks() {
    let blocks = RichText.blocks("> quoted\n\n---\n\nafter")
    XCTAssertEqual(blocks.map(\.kind), [.blockQuote, .thematicBreak, .paragraph])
    XCTAssertEqual(String(blocks[1].text.characters), "")
  }

  func testInlineMarkupAndLinksSurviveTheBlockSplit() {
    let blocks = RichText.blocks("a **bold** word and [docs](https://example.com)")
    XCTAssertEqual(blocks.count, 1)
    XCTAssertTrue(
      blocks[0].text.runs.contains {
        $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
      })
    XCTAssertTrue(blocks[0].text.runs.contains { $0.link == URL(string: "https://example.com") })
  }

  func testFencedCodeStaysOutOfTheBlockParserSoItIsNeverReinterpreted() {
    // Code is split off by `segments` first; the Markdown parser only ever sees
    // the prose around it, so a `#` inside a fence stays a `#`.
    let segments = RichText.segments("intro\n```\n# not a heading\n```")
    XCTAssertEqual(segments.map(\.kind), [.markdown, .code(language: "")])
    XCTAssertEqual(segments[1].text, "# not a heading\n")
    XCTAssertEqual(RichText.blocks(segments[0].text).map(\.kind), [.paragraph])
  }

  func testCodeHighlighterPreservesTextAndClassifiesCommonTokens() {
    let tokens = CodeHighlighter.tokens("let count = 42 // total", language: "swift")
    XCTAssertEqual(tokens.map(\.text).joined(), "let count = 42 // total")
    XCTAssertTrue(tokens.contains { $0.text == "let" && $0.role == .keyword })
    XCTAssertTrue(tokens.contains { $0.text == "42" && $0.role == .number })
    XCTAssertTrue(tokens.contains { $0.text.hasPrefix("//") && $0.role == .comment })
  }
}
