import Foundation

/// The media presentation selected for a message attachment.
public enum MessageMediaKind: Equatable, Sendable {
  case image
  case video
  case audio
}

/// A bounded subset of NIP-92 `imeta` metadata used by native clients.
public struct ImetaEntry: Equatable, Sendable {
  public let url: String
  public let mimeType: String?
  public let dimensions: String?
  public let thumb: String?
  public let image: String?
  public let alt: String?
  public let duration: Double?
  public let filename: String?
  public let size: Int?

  public init(
    url: String, mimeType: String? = nil, dimensions: String? = nil,
    thumb: String? = nil, image: String? = nil, alt: String? = nil,
    duration: Double? = nil, filename: String? = nil, size: Int? = nil
  ) {
    self.url = url
    self.mimeType = mimeType
    self.dimensions = dimensions
    self.thumb = thumb
    self.image = image
    self.alt = alt
    self.duration = duration
    self.filename = filename
    self.size = size
  }

  public var isVideo: Bool { mimeType?.hasPrefix("video/") == true }
  public var isAudio: Bool { mimeType?.hasPrefix("audio/") == true }
  public var posterURL: URL? { URL(string: image ?? thumb ?? "") }

  public var aspectRatio: Double? {
    guard let dimensions else { return nil }
    let parts = dimensions.split(separator: "x", maxSplits: 1).compactMap { Double($0) }
    guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
    return parts[0] / parts[1]
  }
}

public enum MessageMedia {
  /// Parses NIP-92 tags. Invalid entries are ignored and duplicate URLs use the last tag.
  public static func parseImetaTags(_ tags: [[String]]) -> [String: ImetaEntry] {
    var result: [String: ImetaEntry] = [:]
    for tag in tags where tag.first == "imeta" {
      var values: [String: String] = [:]
      for part in tag.dropFirst() {
        guard let separator = part.firstIndex(of: " "), separator > part.startIndex else {
          continue
        }
        let key = String(part[..<separator])
        let value = String(part[part.index(after: separator)...])
        values[key] = value
      }
      guard let url = values["url"], !url.isEmpty else { continue }
      let duration = values["duration"].flatMap(Double.init).flatMap {
        $0.isFinite && $0 >= 0 ? $0 : nil
      }
      let size = values["size"].flatMap(Int.init).flatMap { $0 >= 0 ? $0 : nil }
      result[url] = ImetaEntry(
        url: url, mimeType: values["m"], dimensions: values["dim"], thumb: values["thumb"],
        image: values["image"], alt: values["alt"], duration: duration,
        filename: values["filename"], size: size)
    }
    return result
  }

  /// Uses authoritative `imeta` MIME data, then a conservative extension fallback.
  public static func classify(_ url: String, imeta: ImetaEntry? = nil) -> MessageMediaKind? {
    if let mime = imeta?.mimeType?.lowercased() {
      if mime.hasPrefix("video/") { return .video }
      if mime.hasPrefix("image/") { return .image }
      if mime.hasPrefix("audio/") { return .audio }
    }
    let path = (URL(string: url)?.path ?? url).lowercased()
    if [".jpg", ".jpeg", ".png", ".webp", ".bmp", ".heic", ".heif", ".avif"].contains(
      where: path.hasSuffix)
    {
      return .image
    }
    if path.hasSuffix(".mp4") || path.hasSuffix(".mov") || path.hasSuffix(".m4v") { return .video }
    if [".m4a", ".aac", ".mp3", ".wav", ".caf"].contains(where: path.hasSuffix) { return .audio }
    return nil
  }

  /// Extracts at most four valid HTTP(S) URLs from message text.
  public static func urls(in text: String) -> [String] {
    let pattern = #"https?://[^\s<>\"']+"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(text.startIndex..., in: text)
    var seen = Set<String>()
    return regex.matches(in: text, range: range).compactMap { match in
      guard let matchRange = Range(match.range, in: text) else { return nil }
      let raw = String(text[matchRange]).trimmingCharacters(in: .punctuationCharacters)
      guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased()),
        seen.insert(raw).inserted
      else { return nil }
      return raw
    }.prefix(4).map { $0 }
  }
}
