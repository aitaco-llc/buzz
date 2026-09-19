import Foundation
import SwiftUI

/// Bounded native Markdown parsing for message bodies. Invalid Markdown falls
/// back to the signed source text instead of dropping message content.
enum RichText {
  struct Segment: Equatable {
    enum Kind: Equatable {
      case markdown
      case code(language: String)
    }
    let kind: Kind
    let text: String
  }

  private static let maxSourceBytes = 256 * 1024
  private static let maxCodeBytes = 64 * 1024

  /// One Markdown block, with its inline markup intact.
  ///
  /// `AttributedString(markdown:)` records block structure in `presentationIntent`
  /// runs rather than in the text: parsing a heading, a list and two paragraphs
  /// yields one string whose characters run together, and `Text` has no way to
  /// put the breaks back. Splitting the runs into blocks here is what lets the
  /// view lay each one out on its own line.
  struct Block: Equatable {
    enum Kind: Equatable {
      case paragraph
      case heading(level: Int)
      case listItem(marker: String, depth: Int)
      case blockQuote
      case thematicBreak
    }
    let kind: Kind
    let text: AttributedString
  }

  /// Groups the parsed runs into blocks. Returns an empty array when the source
  /// is over budget or unparseable, which the view renders as the source text so
  /// a signed body is never dropped.
  static func blocks(_ source: String) -> [Block] {
    guard source.utf8.count <= maxSourceBytes,
      let parsed = try? AttributedString(
        markdown: source,
        options: .init(
          interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible))
    else { return [] }

    var result: [Block] = []
    var currentKey: Int?
    var currentIntent: PresentationIntent?
    var currentText = AttributedString()
    var started = false

    func flush() {
      guard started else { return }
      let kind = kind(for: currentIntent)
      if kind == .thematicBreak {
        result.append(Block(kind: kind, text: AttributedString()))
      } else {
        let trimmed = trimmingNewlinesAndSpaces(currentText)
        if !trimmed.characters.isEmpty { result.append(Block(kind: kind, text: trimmed)) }
      }
    }

    for run in parsed.runs {
      let key = run.presentationIntent?.components.first?.identity
      if !started || key != currentKey {
        flush()
        started = true
        currentKey = key
        currentIntent = run.presentationIntent
        currentText = AttributedString()
      }
      // A soft break arrives as a run holding a single space. Chat authors mean
      // a new line by it, so keep it as one rather than letting it collapse.
      if run.inlinePresentationIntent?.contains(.softBreak) == true {
        currentText.append(AttributedString("\n"))
      } else {
        currentText.append(AttributedString(parsed[run.range]))
      }
    }
    flush()
    return result
  }

  /// Block kinds arrive innermost-first, so a list item inside a quote inside a
  /// list reads as `[paragraph, listItem, unorderedList, ...]`. The first list
  /// marker wins and every enclosing list adds a level of indent.
  private static func kind(for intent: PresentationIntent?) -> Block.Kind {
    guard let intent else { return .paragraph }
    var listDepth = 0
    var ordinal: Int?
    var marker: String?
    var quoted = false
    for component in intent.components {
      switch component.kind {
      case .header(let level):
        return .heading(level: max(1, min(level, 6)))
      case .thematicBreak:
        return .thematicBreak
      case .listItem(let value):
        if marker == nil, ordinal == nil { ordinal = value }
      case .unorderedList:
        listDepth += 1
        if marker == nil { marker = "\u{2022}" }
      case .orderedList:
        listDepth += 1
        if marker == nil { marker = "\(ordinal ?? 1)." }
      case .blockQuote:
        quoted = true
      default:
        break
      }
    }
    if let marker { return .listItem(marker: marker, depth: listDepth) }
    return quoted ? .blockQuote : .paragraph
  }

  private static func trimmingNewlinesAndSpaces(_ value: AttributedString) -> AttributedString {
    var value = value
    while let first = value.characters.first, first == "\n" || first == " " {
      value.removeSubrange(value.startIndex..<value.index(afterCharacter: value.startIndex))
    }
    while let last = value.characters.last, last == "\n" || last == " " {
      value.removeSubrange(value.index(beforeCharacter: value.endIndex)..<value.endIndex)
    }
    return value
  }

  /// Splits fenced code blocks before Markdown parsing, so code is displayed
  /// literally and never interpreted as links or formatting.
  static func segments(_ source: String) -> [Segment] {
    guard source.utf8.count <= maxSourceBytes else {
      return [Segment(kind: .markdown, text: source)]
    }
    let pattern = "```([A-Za-z0-9_+.-]{0,32})?[ \\t]*\\n([\\s\\S]*?)```"
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      return [Segment(kind: .markdown, text: source)]
    }
    let fullRange = NSRange(source.startIndex..., in: source)
    var result: [Segment] = []
    var cursor = source.startIndex
    for match in regex.matches(in: source, range: fullRange) {
      guard let matchRange = Range(match.range, in: source),
        let codeRange = Range(match.range(at: 2), in: source)
      else { continue }
      let before = String(source[cursor..<matchRange.lowerBound])
      if !before.isEmpty { result.append(Segment(kind: .markdown, text: before)) }
      let code = String(source[codeRange])
      if code.utf8.count <= maxCodeBytes {
        let language = Range(match.range(at: 1), in: source).map { String(source[$0]) } ?? ""
        result.append(Segment(kind: .code(language: language), text: code))
      } else {
        result.append(Segment(kind: .markdown, text: String(source[matchRange])))
      }
      cursor = matchRange.upperBound
    }
    let trailing = String(source[cursor...])
    if !trailing.isEmpty { result.append(Segment(kind: .markdown, text: trailing)) }
    return result.isEmpty ? [Segment(kind: .markdown, text: source)] : result
  }
}

enum CodeTokenRole: Equatable { case plain, keyword, string, number, comment }

struct CodeToken: Equatable {
  let text: String
  let role: CodeTokenRole
}

enum CodeHighlighter {
  private static let keywords = Set(
    "actor async await break case catch class const continue def defer else enum extension fallthrough false final for func guard if import in init let mutating nil private protocol public repeat return self static struct switch throw throws true try typealias var while async await"
      .split(separator: " ").map(String.init))

  static func tokens(_ source: String, language: String) -> [CodeToken] {
    guard !source.isEmpty else { return [] }
    let pattern =
      #"//[^\n]*|#[^\n]*|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|\b\d+(?:\.\d+)?\b|\b[A-Za-z_][A-Za-z0-9_]*\b"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      return [CodeToken(text: source, role: .plain)]
    }
    var result: [CodeToken] = []
    var cursor = source.startIndex
    for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
      guard let range = Range(match.range, in: source) else { continue }
      if range.lowerBound > cursor {
        result.append(CodeToken(text: String(source[cursor..<range.lowerBound]), role: .plain))
      }
      let text = String(source[range])
      let role: CodeTokenRole
      if text.hasPrefix("//") || text.hasPrefix("#") {
        role = .comment
      } else if text.hasPrefix("\"") || text.hasPrefix("'") {
        role = .string
      } else if Double(text) != nil {
        role = .number
      } else if keywords.contains(text) {
        role = .keyword
      } else {
        role = .plain
      }
      result.append(CodeToken(text: text, role: role))
      cursor = range.upperBound
    }
    if cursor < source.endIndex {
      result.append(CodeToken(text: String(source[cursor...]), role: .plain))
    }
    return result.isEmpty ? [CodeToken(text: source, role: .plain)] : result
  }
}

struct RichMessageText: View {
  let source: String

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(RichText.segments(source).enumerated()), id: \.offset) { _, segment in
        switch segment.kind {
        case .markdown:
          RichMarkdownBlocks(source: segment.text)
        case .code(let language):
          RichCodeBlock(language: language, source: segment.text)
        }
      }
    }
  }
}

/// Lays out one Markdown segment a block at a time, which is what keeps
/// paragraphs, lists and headings on separate lines.
private struct RichMarkdownBlocks: View {
  let source: String

  var body: some View {
    let blocks = RichText.blocks(source)
    if blocks.isEmpty {
      Text(source).textSelection(.enabled)
    } else {
      VStack(alignment: .leading, spacing: 6) {
        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
          RichBlockView(block: block)
        }
      }
    }
  }
}

private struct RichBlockView: View {
  let block: RichText.Block

  var body: some View {
    switch block.kind {
    case .paragraph:
      body(for: block.text)
    case .heading(let level):
      body(for: block.text).font(headingFont(level)).padding(.top, 2)
    case .listItem(let marker, let depth):
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(marker).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        body(for: block.text).frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.leading, CGFloat(max(0, depth - 1)) * 16)
    case .blockQuote:
      HStack(alignment: .top, spacing: 8) {
        RoundedRectangle(cornerRadius: 1.5)
          .fill(Color.secondary.opacity(0.4))
          .frame(width: 3)
        body(for: block.text).foregroundStyle(.secondary)
      }
      .fixedSize(horizontal: false, vertical: true)
    case .thematicBreak:
      Divider()
    }
  }

  private func body(for value: AttributedString) -> some View {
    Text(value).textSelection(.enabled).tint(Aitaco.accent)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func headingFont(_ level: Int) -> Font {
    switch level {
    case 1: return .title2.bold()
    case 2: return .title3.bold()
    case 3: return .headline
    default: return .subheadline.bold()
    }
  }
}

private struct RichCodeBlock: View {
  let language: String
  let source: String
  @State private var copied = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text(language.isEmpty ? "Code" : language)
          .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        Spacer()
        Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
          UIPasteboard.general.string = source
          copied = true
          Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
          }
        }
        .font(.caption)
        .accessibilityLabel(copied ? "Code copied" : "Copy code")
      }
      .padding(.horizontal, 10).padding(.vertical, 7)
      ScrollView(.horizontal, showsIndicators: true) {
        highlightedCode.font(.system(.callout, design: .monospaced))
          .textSelection(.enabled).padding(10)
      }
    }
    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    .accessibilityElement(children: .contain)
  }

  private var highlightedCode: Text {
    CodeHighlighter.tokens(source, language: language).reduce(Text("")) { result, token in
      result + Text(token.text).foregroundColor(color(for: token.role))
    }
  }

  private func color(for role: CodeTokenRole) -> Color {
    switch role {
    case .plain: return .primary
    case .keyword: return .purple
    case .string: return .green
    case .number: return .orange
    case .comment: return .secondary
    }
  }
}
