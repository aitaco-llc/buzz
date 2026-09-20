import Foundation
import Testing

@testable import BuzzCore

struct TurnReceiptTests {
  @Test func oneTurnsUsageAppearsOnceUnderTheLastMessageItPublished() throws {
    let f = try ReceiptFixture()
    let turn = try (0..<3).map { try f.message(by: f.agent, at: 10 + $0, text: "part \($0)") }
    let receipt = try f.receipt(naming: turn, by: f.agent, at: 20)
    let index = TurnReceiptProjection.index(events: turn + [receipt])
    #expect(index.count == 1)
    #expect(index[turn[2].id]?.id == receipt.id)
    #expect(index[turn[2].id]?.model == "opus[1m]")
    #expect(index[turn[0].id] == nil)
    #expect(index[turn[1].id] == nil)
    // Holding only the middle message moves the footer there rather than
    // dropping it; holding none of them renders nothing at all.
    let partial = TurnReceiptProjection.index(events: [turn[0], turn[1], receipt])
    #expect(partial.map(\.key) == [turn[1].id])
    #expect(TurnReceiptProjection.index(events: [receipt]).isEmpty)
  }

  @Test func aReceiptFromAnyoneOtherThanTheMessageAuthorIsNeverRendered() throws {
    let f = try ReceiptFixture()
    let message = try f.message(by: f.agent, at: 10)
    let forged = try f.receipt(naming: [message], by: f.impostor, at: 11)
    #expect(TurnReceiptProjection.index(events: [message, forged]).isEmpty)
    // Naming one honest message of its own does not let an impostor annotate
    // somebody else's message in the same receipt.
    let own = try f.message(by: f.impostor, at: 12)
    let mixed = try f.receipt(naming: [own, message], by: f.impostor, at: 13)
    #expect(TurnReceiptProjection.index(events: [message, own, mixed]).isEmpty)
    let honest = try f.receipt(naming: [own], by: f.impostor, at: 14)
    #expect(TurnReceiptProjection.index(events: [own, honest]).map(\.key) == [own.id])
  }

  @Test func aCountTheHarnessNeverReportedIsAbsentRatherThanZero() throws {
    let f = try ReceiptFixture()
    let message = try f.message(by: f.agent, at: 10)
    let sparse = try f.receipt(
      naming: [message], by: f.agent, at: 11,
      turn: "{\"inputTokens\":191261,\"outputTokens\":683,\"totalTokens\":null,"
        + "\"costUsd\":null,\"cacheReadTokens\":122407}")
    let receipt = try #require(TurnReceiptProjection.index(events: [message, sparse])[message.id])
    #expect(receipt.cacheWriteTokens == nil)
    #expect(receipt.totalTokens == nil)
    #expect(receipt.costUsd == nil)
    #expect(receipt.reportedCounts.map(\.label) == ["Input", "Output", "Cache read"])
    #expect(!receipt.summary.contains("Cache write"))
    #expect(!receipt.accessibilityDescription.contains("cache write"))
    // A turn the harness could not count at all still names its model, and
    // still says nothing about counts it never received.
    let silent = try f.receipt(naming: [message], by: f.agent, at: 12, turn: "{}")
    let quiet = try #require(TurnReceiptProjection.index(events: [message, silent])[message.id])
    #expect(quiet.reportedCounts.isEmpty)
    #expect(quiet.summary == "opus[1m]")
    #expect(
      quiet.accessibilityDescription == "Agent turn ran on opus[1m]. No token counts were reported."
    )
  }

  @Test func aMalformedReceiptIsDroppedWithoutFailingTheConversation() throws {
    let f = try ReceiptFixture()
    let message = try f.message(by: f.agent, at: 10)
    let good = try f.receipt(naming: [message], by: f.agent, at: 11)
    let broken = [
      try f.agent.sign(
        kind: Projection.turnReceiptKind, content: "not json",
        tags: [["h", "c"], ["e", message.id], ["model", "opus[1m]"]], at: 12),
      try f.receipt(naming: [message], by: f.agent, at: 13, model: ""),
      try f.receipt(naming: [message], by: f.agent, at: 14, harness: ""),
      try f.receipt(naming: [message], by: f.agent, at: 15, modelTag: "haiku"),
      try f.receipt(
        naming: [message], by: f.agent, at: 16, turn: "{\"costUsd\":-0.01}"),
      try f.receipt(
        naming: [message], by: f.agent, at: 17, turn: "{\"inputTokens\":\"not a number\"}"),
      try f.agent.sign(
        kind: Projection.turnReceiptKind, content: f.content(),
        tags: [["h", "c"], ["h", "other"], ["e", message.id], ["model", "opus[1m]"]], at: 18),
      // An `e` tag carrying a NIP-10 marker would make the receipt a reply.
      try f.agent.sign(
        kind: Projection.turnReceiptKind, content: f.content(),
        tags: [["h", "c"], ["e", message.id, "", "reply"], ["model", "opus[1m]"]], at: 19),
    ]
    for bad in broken {
      #expect(TurnReceiptProjection.index(events: [message, bad]).isEmpty, "\(bad.content)")
      #expect(
        TurnReceiptProjection.index(events: [message, bad, good])[message.id]?.id == good.id,
        "\(bad.content)")
    }
    let deletion = try f.agent.sign(kind: 5, content: "", tags: [["e", good.id]], at: 20)
    #expect(TurnReceiptProjection.index(events: [message, good, deletion]).isEmpty)
  }

  @Test func tokenCountsStayExactPastWhatADoubleCanHold() throws {
    let f = try ReceiptFixture()
    let message = try f.message(by: f.agent, at: 10)
    let huge = try f.receipt(
      naming: [message], by: f.agent, at: 11,
      turn: "{\"inputTokens\":9007199254740993,\"outputTokens\":\"18446744073709551615\"}")
    let receipt = try #require(TurnReceiptProjection.index(events: [message, huge])[message.id])
    #expect(receipt.inputTokens == 9_007_199_254_740_993)
    #expect(receipt.outputTokens == UInt64.max)
    let overflow = try f.receipt(
      naming: [message], by: f.agent, at: 12,
      turn: "{\"inputTokens\":\"18446744073709551616\"}")
    #expect(TurnReceiptProjection.index(events: [message, overflow]).isEmpty)
  }

  @Test func aReceiptRidesItsHistoryPageAndAnUnboundOneLeavesThePageIntact() throws {
    let f = try ReceiptFixture()
    let row = try f.message(by: f.agent, at: 10)
    let receipt = try f.receipt(naming: [row], by: f.agent, at: 11)
    let page = try ConversationPage.window(
      [row, receipt, f.bounds()], channelID: "c", authority: f.relay.pubkey, after: nil)
    #expect(page.rows == [row])
    #expect(page.events.map(\.id) == [row.id, receipt.id])
    let absent = try f.message(by: f.agent, at: 5, text: "an earlier page")
    let stray = try f.receipt(naming: [absent], by: f.agent, at: 12)
    let intact = try ConversationPage.window(
      [row, stray, f.bounds()], channelID: "c", authority: f.relay.pubkey, after: nil)
    #expect(intact.events == [row])
    let retraction = try f.agent.sign(kind: 5, content: "", tags: [["e", stray.id]], at: 13)
    let withDeletion = try ConversationPage.window(
      [row, stray, retraction, f.bounds()], channelID: "c", authority: f.relay.pubkey, after: nil)
    #expect(withDeletion.events.map(\.id) == [row.id, retraction.id])
  }
}

private struct ReceiptFixture {
  let relay: Identity
  let agent: Identity
  let impostor: Identity

  init() throws {
    relay = try Identity(hex: String(repeating: "0", count: 63) + "1")
    agent = try Identity(hex: String(repeating: "0", count: 63) + "2")
    impostor = try Identity(hex: String(repeating: "0", count: 63) + "3")
  }

  func message(by signer: Identity, at timestamp: Int, text: String = "message") throws -> Event {
    try signer.sign(kind: 9, content: text, tags: [["h", "c"]], at: timestamp)
  }

  func content(
    model: String = "opus[1m]", harness: String = "claude-agent-acp",
    turn: String = "{\"inputTokens\":191261,\"outputTokens\":683,\"totalTokens\":191944,"
      + "\"costUsd\":0.42,\"cacheReadTokens\":122407,\"cacheWriteTokens\":4096}"
  ) -> String {
    "{\"model\":\"\(model)\",\"harness\":\"\(harness)\",\"turn\":\(turn)}"
  }

  func receipt(
    naming messages: [Event], by signer: Identity, at timestamp: Int,
    model: String = "opus[1m]", harness: String = "claude-agent-acp", modelTag: String? = nil,
    turn: String = "{\"inputTokens\":191261,\"outputTokens\":683,\"totalTokens\":191944,"
      + "\"costUsd\":0.42,\"cacheReadTokens\":122407,\"cacheWriteTokens\":4096}"
  ) throws -> Event {
    try signer.sign(
      kind: Projection.turnReceiptKind,
      content: content(model: model, harness: harness, turn: turn),
      tags: [["h", "c"]] + messages.map { ["e", $0.id] } + [["model", modelTag ?? model]],
      at: timestamp)
  }

  func bounds() throws -> Event {
    try relay.sign(
      kind: 39006, content: "{\"has_more\":false,\"next_cursor\":null}",
      tags: [["h", "c"], ["d", "c:head"]], at: 200)
  }
}
