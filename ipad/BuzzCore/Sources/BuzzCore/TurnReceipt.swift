import Foundation

/// NIP-AR kind 44201: what one agent turn ran on, and what it spent.
///
/// The counts belong to the turn rather than to any one message it published,
/// so a receipt is folded onto a single message — the last one of that turn
/// this client actually holds — and never onto each of them.
public struct TurnReceipt: Identifiable, Equatable, Sendable {
  /// The receipt event's identifier; consumers deduplicate on it.
  public let id: String
  /// The agent that published both this receipt and the messages it annotates.
  public let pubkey: String
  /// The model the turn actually ran on, as the harness observed it.
  public let model: String
  /// Harness identifier, such as `claude-agent-acp`.
  public let harness: String
  /// Inclusive input-side total, absent when the harness reported none.
  public let inputTokens: UInt64?
  /// Output total, absent when the harness reported none.
  public let outputTokens: UInt64?
  /// Provider-reported total; never derived by summing the other counters.
  public let totalTokens: UInt64?
  /// Informational subset of the input total, absent when unobservable.
  public let cacheReadTokens: UInt64?
  /// Informational subset of the input total, absent when unobservable.
  public let cacheWriteTokens: UInt64?
  /// Estimated cost in US dollars. Advisory, never a billing record.
  public let costUsd: Double?
}

/// One reported token count, ready to display. A count the harness never
/// reported has no entry, because a zero would be a claim nobody made.
public struct TurnTokenCount: Identifiable, Equatable, Sendable {
  /// Short heading, such as `Input`.
  public let label: String
  /// The exact count, including values a double could not represent.
  public let value: UInt64
  /// Stable identity within one receipt's footer.
  public var id: String { label }
  /// Grouped decimal text in the reader's locale.
  public var formatted: String { value.formatted(.number) }
}

extension TurnReceipt {
  /// The counts this receipt actually reported, in reading order.
  public var reportedCounts: [TurnTokenCount] {
    [
      ("Input", inputTokens), ("Output", outputTokens),
      ("Cache read", cacheReadTokens), ("Cache write", cacheWriteTokens),
    ].compactMap { label, count in count.map { TurnTokenCount(label: label, value: $0) } }
  }

  /// The footer's visible text: the model, then whatever the harness counted.
  public var summary: String {
    ([model] + reportedCounts.map { "\($0.label) \($0.formatted)" }).joined(separator: " · ")
  }

  /// One sentence for VoiceOver, so the footer is heard as a claim about a
  /// turn rather than as a run of bare numbers.
  public var accessibilityDescription: String {
    let counts = reportedCounts.map { "\($0.formatted) \($0.label.lowercased()) tokens" }
    guard !counts.isEmpty else {
      return "Agent turn ran on \(model). No token counts were reported."
    }
    return "Agent turn ran on \(model), using " + counts.joined(separator: ", ") + "."
  }
}

/// Folds NIP-AR receipts onto the messages they annotate.
public enum TurnReceiptProjection {
  /// Indexes each turn's receipt under the last message of that turn this
  /// cache holds, so one turn's spend is shown once rather than multiplied by
  /// the number of messages the turn happened to split into. A receipt is a
  /// claim by its author about its author: one naming a message it did not
  /// write is discarded, never rendered as that author's usage.
  public static func index(events: [Event], authority: String? = nil) -> [String: TurnReceipt] {
    let byID = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let deletions = events.filter { [5, 9005].contains($0.kind) }
    var indexed: [String: (event: Event, receipt: TurnReceipt)] = [:]
    for event in events where event.kind == Projection.turnReceiptKind {
      guard event.tags.filter({ $0.first == "h" }).count == 1, let channelID = event.tag("h"),
        let receipt = receipt(event),
        !deletions.contains(where: {
          EventRelations.deletes($0, target: event, channelID: channelID, authority: authority)
        })
      else { continue }
      // A receipt annotates the messages it names; it does not reply to them,
      // so a marked reference means this is not the event it claims to be.
      let named = event.tags.filter { $0.count >= 2 && $0[0] == "e" }
      guard named.allSatisfy({ $0.count < 4 || $0[3].isEmpty }) else { continue }
      let messages = named.compactMap { byID[$0[1]] }.filter {
        Projection.messageKinds.contains($0.kind) && $0.tag("h") == channelID
      }
      // Anyone may name anyone's message, so every named message held here
      // must be the receipt author's before any of it is believed.
      guard let last = messages.last, messages.allSatisfy({ $0.pubkey == event.pubkey })
      else { continue }
      // Two receipts resolving to one message is a publisher error; resolve it
      // the same way regardless of the order the cache happened to yield.
      if let previous = indexed[last.id]?.event,
        (previous.createdAt, previous.id) > (event.createdAt, event.id)
      {
        continue
      }
      indexed[last.id] = (event, receipt)
    }
    return indexed.mapValues(\.receipt)
  }

  /// The receipt's `content`, as published. Unknown fields are ignored.
  private struct Payload: Decodable {
    let model: String
    let harness: String
    let turn: Counts

    struct Counts: Decodable {
      let inputTokens: ExactCount?
      let outputTokens: ExactCount?
      let totalTokens: ExactCount?
      let cacheReadTokens: ExactCount?
      let cacheWriteTokens: ExactCount?
      let costUsd: Double?
    }
  }

  /// A token count read without passing through a double. Counts may exceed
  /// 2^53, and publishers write them either as JSON numbers or, where their
  /// runtime has no exact integer, as decimal strings.
  private struct ExactCount: Decodable {
    let value: UInt64

    init(from decoder: any Decoder) throws {
      let container = try decoder.singleValueContainer()
      if let text = try? container.decode(String.self) {
        guard let exact = UInt64(text) else { throw BuzzError.invalidResponse }
        value = exact
      } else {
        value = try container.decode(UInt64.self)
      }
    }
  }

  /// Reads one receipt, or nothing at all. A receipt that cannot be read
  /// exactly is not read: a malformed one is dropped, never approximated.
  private static func receipt(_ event: Event) -> TurnReceipt? {
    guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(event.content.utf8)),
      !payload.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !payload.harness.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      // The tag exists so a reader can filter by model without opening every
      // body; a tag that disagrees with the body makes that filter a lie.
      event.tags.filter({ $0.first == "model" }).count == 1, event.tag("model") == payload.model,
      payload.turn.costUsd.map({ $0.isFinite && $0 >= 0 }) ?? true
    else { return nil }
    return TurnReceipt(
      id: event.id, pubkey: event.pubkey, model: payload.model, harness: payload.harness,
      inputTokens: payload.turn.inputTokens?.value,
      outputTokens: payload.turn.outputTokens?.value,
      totalTokens: payload.turn.totalTokens?.value,
      cacheReadTokens: payload.turn.cacheReadTokens?.value,
      cacheWriteTokens: payload.turn.cacheWriteTokens?.value,
      costUsd: payload.turn.costUsd)
  }
}
