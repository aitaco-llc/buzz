import UIKit
import XCTest

@testable import Buzz

/// `MediaSanitizer.forUpload` is what stands between the photo picker and a 422
/// from the relay, which rejects any metadata channel structurally and allows
/// only jpeg/png/gif/webp.
final class MediaSanitizerUploadTests: XCTestCase {
  private func swatch(_ size: CGSize = CGSize(width: 8, height: 6)) -> UIImage {
    UIGraphicsImageRenderer(size: size).image { context in
      UIColor.systemTeal.setFill()
      context.fill(CGRect(origin: .zero, size: size))
    }
  }

  func testCameraHeicBecomesAJpegBecauseTheRelayAllowlistHasNoHeic() throws {
    let source = try XCTUnwrap(swatch().pngData())
    let upload = try MediaSanitizer.forUpload(data: source, mimeType: "image/heic")
    XCTAssertEqual(upload.mimeType, "image/jpeg")
    XCTAssertEqual(Array(upload.data.prefix(2)), [0xFF, 0xD8])
  }

  func testScreenshotPngStaysAPngAndCarriesNoDisallowedAncillaryChunks() throws {
    let source = try XCTUnwrap(swatch().pngData())
    let upload = try MediaSanitizer.forUpload(data: source, mimeType: "image/png")
    XCTAssertEqual(upload.mimeType, "image/png")
    XCTAssertEqual(
      Array(upload.data.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    XCTAssertFalse(chunkTypes(in: upload.data).contains("tEXt"))
    XCTAssertFalse(chunkTypes(in: upload.data).contains("iTXt"))
    XCTAssertTrue(chunkTypes(in: upload.data).contains("IHDR"))
  }

  func testPhotoJpegKeepsItsTypeAndLosesTheExifSegment() throws {
    let source = try XCTUnwrap(swatch().jpegData(compressionQuality: 0.9))
    let upload = try MediaSanitizer.forUpload(
      data: withExifAppSegment(source), mimeType: "image/jpeg")
    XCTAssertEqual(upload.mimeType, "image/jpeg")
    XCTAssertFalse(hasApp1Segment(upload.data), "APP1 is what the relay 422s on")
  }

  func testWebpIsReRenderedAsPngBecauseUIKitCannotEncodeWebp() throws {
    let source = try XCTUnwrap(swatch().pngData())
    let upload = try MediaSanitizer.forUpload(data: source, mimeType: "image/webp")
    XCTAssertEqual(upload.mimeType, "image/png")
  }

  func testAnimatedGifPassesThroughUntouchedSoItKeepsItsFrames() throws {
    // A re-render would flatten a GIF to one frame, so its bytes go up as they
    // are and the relay validates them on its side.
    let source = Data("GIF89a-not-a-real-gif".utf8)
    let upload = try MediaSanitizer.forUpload(data: source, mimeType: "image/gif")
    XCTAssertEqual(upload.mimeType, "image/gif")
    XCTAssertEqual(upload.data, source)
  }

  func testUndecodableBytesThrowRatherThanUploadingGarbage() {
    XCTAssertThrowsError(
      try MediaSanitizer.forUpload(data: Data("not an image".utf8), mimeType: "image/png"))
  }

  private func chunkTypes(in png: Data) -> [String] {
    var types: [String] = []
    var offset = 8
    while offset + 12 <= png.count {
      let length =
        Int(png[offset]) << 24 | Int(png[offset + 1]) << 16 | Int(png[offset + 2]) << 8
        | Int(png[offset + 3])
      guard let type = String(bytes: png[(offset + 4)..<(offset + 8)], encoding: .ascii) else {
        break
      }
      types.append(type)
      offset += length + 12
      if type == "IEND" { break }
    }
    return types
  }

  private func hasApp1Segment(_ jpeg: Data) -> Bool {
    var offset = 2
    while offset + 4 <= jpeg.count {
      guard jpeg[offset] == 0xFF else { return false }
      let marker = jpeg[offset + 1]
      if marker == 0xDA || marker == 0xD9 { return false }
      if marker == 0xE1 { return true }
      offset += 2 + (Int(jpeg[offset + 2]) << 8 | Int(jpeg[offset + 3]))
    }
    return false
  }

  /// Splices a minimal EXIF APP1 segment in after SOI, standing in for what a
  /// Photos asset arrives with.
  private func withExifAppSegment(_ jpeg: Data) -> Data {
    var payload = Data("Exif\0\0".utf8)
    payload.append(contentsOf: [0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00])
    let length = payload.count + 2
    var output = Data([0xFF, 0xD8, 0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 0xFF)])
    output.append(payload)
    output.append(jpeg.dropFirst(2))
    return output
  }
}
