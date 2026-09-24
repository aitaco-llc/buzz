import BuzzCore
import XCTest

@testable import Buzz

final class PulseProjectionTests: XCTestCase {
  func testMineFilterAndNewestOrdering() throws {
    let me = try Identity(hex: String(repeating: "0", count: 63) + "1")
    let other = try Identity(hex: String(repeating: "0", count: 63) + "2")
    let mine = try me.sign(kind: 1, content: "mine", tags: [], at: 10)
    let theirs = try other.sign(kind: 1, content: "theirs", tags: [], at: 20)
    XCTAssertEqual(
      PulseProjection.notes(events: [mine, theirs], identity: me, mineOnly: false).map(\.id),
      [theirs.id, mine.id])
    XCTAssertEqual(
      PulseProjection.notes(events: [mine, theirs], identity: me, mineOnly: true).map(\.id),
      [mine.id])
  }
}
