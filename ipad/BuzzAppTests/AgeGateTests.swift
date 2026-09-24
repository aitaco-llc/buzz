import XCTest

@testable import Buzz

final class AgeGateTests: XCTestCase {
  func testOnlyExplicitUnder18UpperBoundsRestrict() {
    XCTAssertTrue(ageGateRestricts(upperBound: 17))
    XCTAssertTrue(ageGateRestricts(upperBound: 0))
    XCTAssertFalse(ageGateRestricts(upperBound: 18))
    XCTAssertFalse(ageGateRestricts(upperBound: nil))
    XCTAssertFalse(ageGateRestricts(upperBound: -1))
  }
}
