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

  static func attributed(_ source: String) -> AttributedString? {
    guard !source.isEmpty else { return AttributedString("") }
    guard source.utf8.count <= maxSourceBytes else { return nil }
    return try? AttributedString(markdown: source)
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
          if let value = RichText.attributed(segment.text) {
            Text(value).textSelection(.enabled).tint(.indigo)
          } else {
            Text(segment.text).textSelection(.enabled)
          }
        case .code(let language):
          RichCodeBlock(language: language, source: segment.text)
        }
      }
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
