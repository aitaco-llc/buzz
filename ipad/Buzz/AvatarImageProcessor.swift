import UIKit

enum AvatarImageProcessor {
  static func normalizedSquareJPEG(_ data: Data, maxDimension: CGFloat = 1024) -> Data? {
    guard let source = UIImage(data: data), let normalized = normalized(source),
      let cgImage = normalized.cgImage
    else { return nil }
    let side = min(cgImage.width, cgImage.height)
    let origin = CGPoint(x: (cgImage.width - side) / 2, y: (cgImage.height - side) / 2)
    guard
      let cropped = cgImage.cropping(
        to: CGRect(origin: origin, size: CGSize(width: side, height: side)))
    else {
      return nil
    }
    let target = min(CGFloat(side), maxDimension)
    let image = UIImage(cgImage: cropped, scale: 1, orientation: .up)
    let rendered: UIImage
    if target < CGFloat(side) {
      let format = UIGraphicsImageRendererFormat.default()
      format.scale = 1
      let renderer = UIGraphicsImageRenderer(
        size: CGSize(width: target, height: target), format: format)
      rendered = renderer.image { _ in
        image.draw(in: CGRect(origin: .zero, size: CGSize(width: target, height: target)))
      }
    } else {
      rendered = image
    }
    guard let encoded = rendered.jpegData(compressionQuality: 0.85) else { return nil }
    // Same scrub the attachment path uses. An avatar takes the identical relay
    // validation on the way in, so it cannot be the one encoder that skips it.
    return try? MediaSanitizer.scrubJpeg(encoded)
  }

  private static func normalized(_ image: UIImage) -> UIImage? {
    guard image.imageOrientation != .up else { return image }
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = image.scale
    let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
    return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: image.size)) }
  }
}
