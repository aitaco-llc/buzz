import BuzzCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Public emoji assets use no account credentials and have bounded network/decoded sizes.
actor EmojiImages {
  static let shared = EmojiImages()
  private var cache: [URL: Data] = [:]
  private var order: [URL] = []
  private var active = 0
  private var waiting = 0
  private let configuration: URLSessionConfiguration

  init(configuration: URLSessionConfiguration = .ephemeral) { self.configuration = configuration }

  func thumbnail(_ url: URL) async throws -> Data {
    if let cached = cache[url] { return cached }
    guard waiting < 64 else { throw BuzzError.responseTooLarge }
    waiting += 1
    defer { waiting -= 1 }
    for _ in 0..<120 {
      try Task.checkCancellation()
      if active < 6 { break }
      try await Task.sleep(for: .milliseconds(25))
    }
    guard active < 6 else { throw BuzzError.responseTooLarge }
    active += 1
    defer { active -= 1 }
    guard let config = configuration.copy() as? URLSessionConfiguration else {
      throw BuzzError.invalidResponse
    }
    config.httpAdditionalHeaders = nil
    config.httpShouldSetCookies = false
    config.httpCookieStorage = nil
    config.urlCredentialStorage = nil
    config.timeoutIntervalForRequest = 10
    config.timeoutIntervalForResource = 15
    let session = URLSession(configuration: config, delegate: EmojiRedirects(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let (stream, response) = try await session.bytes(from: url)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200,
      response.expectedContentLength <= 1024 * 1024
    else { throw BuzzError.invalidResponse }
    var bytes = Data()
    for try await byte in stream {
      try Task.checkCancellation()
      guard bytes.count < 1024 * 1024 else { throw BuzzError.responseTooLarge }
      bytes.append(byte)
    }
    guard
      let source = CGImageSourceCreateWithData(
        bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      width > 0, height > 0, width <= 1024, height <= 1024,
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceThumbnailMaxPixelSize: 96,
          kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)
    else { throw BuzzError.invalidResponse }
    let output = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        output, UTType.png.identifier as CFString, 1, nil)
    else {
      throw BuzzError.invalidResponse
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw BuzzError.invalidResponse }
    let data = output as Data
    while !order.isEmpty
      && (order.count >= 64
        || cache.values.reduce(0, { $0 + $1.count }) + data.count > 2 * 1024 * 1024)
    {
      cache.removeValue(forKey: order.removeFirst())
    }
    cache[url] = data
    order.removeAll { $0 == url }
    order.append(url)
    return data
  }
}

private final class EmojiRedirects: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

struct ReactionGlyph: View {
  let value: String
  let url: URL?
  @State private var thumbnail: Data?
  @State private var imageError: String?

  var body: some View {
    Group {
      if let thumbnail, let image = UIImage(data: thumbnail) {
        Image(uiImage: image).resizable().scaledToFit().frame(width: 26, height: 26)
      } else {
        Text(value).font(value.hasPrefix(":") ? .caption : .title2).lineLimit(1).minimumScaleFactor(
          0.6)
      }
    }
    .overlay(alignment: .bottomTrailing) {
      if imageError != nil {
        Image(systemName: "exclamationmark.circle").font(.caption2).accessibilityHidden(true)
      }
    }
    .help(imageError ?? value)
    .task(id: url) {
      thumbnail = nil
      imageError = nil
      guard let url else { return }
      do {
        let data = try await EmojiImages.shared.thumbnail(url)
        try Task.checkCancellation()
        thumbnail = data
      } catch is CancellationError { return } catch { imageError = "Image unavailable. \(value)" }
    }
  }
}
