import BuzzCore
import XCTest

@testable import Buzz

final class ActivityProjectionTests: XCTestCase {
  func testProjectionIncludesMentionsRepliesAndReactionsButNotOwnEvents() throws {
    let me = try Identity(hex: String(repeating: "0", count: 63) + "1")
    let other = try Identity(hex: String(repeating: "0", count: 63) + "2")
    let mention = try other.sign(
      kind: 40002, content: "hello", tags: [["p", me.pubkey], ["h", "general"]], at: 10)
    let reply = try other.sign(
      kind: 40002, content: "reply",
      tags: [["e", "root", "", "root"], ["e", "parent", "", "reply"], ["h", "general"]], at: 20)
    let reaction = try other.sign(
      kind: 7, content: "❤️", tags: [["e", "root"], ["h", "general"]], at: 30)
    let own = try me.sign(kind: 40002, content: "mine", tags: [["p", other.pubkey]], at: 40)
    let items = ActivityProjection.items(
      events: [mention, reply, reaction, own], identity: me, channels: [])
    XCTAssertEqual(items.map(\.id), [reaction.id, reply.id, mention.id])
    let sender = String(other.pubkey.prefix(8)) + "…"
    XCTAssertEqual(items[0].title, "\(sender) reacted to a message")
    XCTAssertEqual(items[1].title, "\(sender) replied to a thread")
  }
}
