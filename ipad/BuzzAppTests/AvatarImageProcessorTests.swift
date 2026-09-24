import UIKit
import XCTest

@testable import Buzz

final class AvatarImageProcessorTests: XCTestCase {
  func testAvatarIsNormalizedToBoundedSquareJPEG() throws {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 800))
    let input = renderer.jpegData(withCompressionQuality: 1) { context in
      UIColor.systemBlue.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 1600, height: 800))
    }
    let output = try XCTUnwrap(AvatarImageProcessor.normalizedSquareJPEG(input, maxDimension: 512))
    let image = try XCTUnwrap(UIImage(data: output))
    XCTAssertEqual(image.size.width, 512, accuracy: 1)
    XCTAssertEqual(image.size.height, 512, accuracy: 1)
  }
}
