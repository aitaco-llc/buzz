import BuzzCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// An image loaded through the workspace's authenticated media loader.
///
/// `AsyncImage` cannot carry a header, and the relay requires Blossom `t=get`
/// auth on every `/media/` read, so every `AsyncImage(url:)` in this app
/// rendered its failure branch. Use this instead — for relay blobs it signs the
/// read, and for a third-party host it fetches without credentials.
struct MediaImage<Placeholder: View, Failure: View>: View {
  let url: URL?
  let loader: MediaLoader
  /// Decoded size cap. Downsampling at decode keeps a 4000px avatar from
  /// costing 64 MB of backing store for a 36pt tile.
  var maxPixel: CGFloat = 1024
  @ViewBuilder var placeholder: () -> Placeholder
  @ViewBuilder var failure: () -> Failure

  @State private var image: UIImage?
  @State private var failed = false

  var body: some View {
    Group {
      if let image {
        Image(uiImage: image).resizable()
      } else if failed || url == nil {
        failure()
      } else {
        placeholder()
      }
    }
    .task(id: url) {
      image = nil
      failed = false
      guard let url else { return }
      do {
        let data = try await loader.data(for: url)
        let pixel = maxPixel
        let decoded = await Task.detached(priority: .userInitiated) {
          MediaImage.decode(data, maxPixel: pixel)
        }.value
        try Task.checkCancellation()
        if let decoded { image = decoded } else { failed = true }
      } catch is CancellationError {
        return
      } catch {
        failed = true
      }
    }
  }

  /// Decodes with ImageIO rather than `UIImage(data:)` so the thumbnail is
  /// built at the target size instead of after a full-resolution decode.
  nonisolated static func decode(_ data: Data, maxPixel: CGFloat) -> UIImage? {
    guard
      let source = CGImageSourceCreateWithData(
        data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
      let thumbnail = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceThumbnailMaxPixelSize: maxPixel,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    else { return nil }
    return UIImage(cgImage: thumbnail)
  }
}

extension MediaImage where Failure == EmptyView {
  init(
    url: URL?, loader: MediaLoader, maxPixel: CGFloat = 1024,
    @ViewBuilder placeholder: @escaping () -> Placeholder
  ) {
    self.init(
      url: url, loader: loader, maxPixel: maxPixel, placeholder: placeholder,
      failure: { EmptyView() })
  }
}
