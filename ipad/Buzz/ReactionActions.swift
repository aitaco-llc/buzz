import BuzzCore
import Foundation

extension Workspace {
  /// Add from the picker is idempotent; only tapping an existing pill toggles it off.
  @discardableResult
  func react(to message: Event, value: String, imageURL: URL? = nil, toggle: Bool = false) async
    -> Bool
  {
    guard !reactionBusy.contains(message.id), let value = ReactionProjection.value(value)
    else { return false }
    reactionBusy.insert(message.id)
    defer { reactionBusy.remove(message.id) }
    do {
      await reload()
      let group = reactions[message.id]?.first { $0.value == value }
      let own = group?.ownedIDs(identity.pubkey) ?? []
      if !own.isEmpty && !toggle { return true }
      let identity = identity
      var tags = [[String]]()
      if let channelID = message.tag("h") { tags.append(["h", channelID]) }
      tags.append(["nonce", UUID().uuidString])
      let removing = !own.isEmpty
      if removing {
        tags += own.map { ["e", $0] }
        tags.append(["k", "7"])
      } else {
        tags += [["e", message.id], ["p", message.pubkey], ["k", String(message.kind)]]
        if let imageURL, let custom = CustomEmoji(shortcode: value, url: imageURL.absoluteString) {
          tags.append(["emoji", custom.shortcode, custom.url.absoluteString])
        }
      }
      let signedTags = tags
      let event = try await Task.detached {
        try identity.sign(kind: removing ? 5 : 7, content: removing ? "" : value, tags: signedTags)
      }.value
      try await store.enqueue(event, recordingReaction: removing ? nil : value)
      await reload()
      Task { await retry() }
      return true
    } catch {
      self.error = error.localizedDescription
      return false
    }
  }

  func refreshCustomEmoji() async {
    guard !emojiLoading else { return }
    emojiLoading = true
    defer { emojiLoading = false }
    emojiError = nil
    do {
      var cursor: EventCursor?
      for pageNumber in 0...100 {
        try Task.checkCancellation()
        let page = try await relay.query([
          EventFilter(
            kinds: [30030], tags: ["d": ["buzz:custom-emoji"]],
            until: cursor?.timestamp, beforeID: cursor?.eventID, limit: 100)
        ])
        try Task.checkCancellation()
        guard page.count <= 100,
          page.allSatisfy({
            $0.kind == 30030 && $0.tag("d") == "buzz:custom-emoji"
              && (cursor?.containsOlder($0) ?? true)
          })
        else { throw BuzzError.invalidResponse }
        if page.isEmpty { return }
        guard pageNumber < 100 else { throw BuzzError.historyLimit }
        try await store.ingest(page)
        await reload()
        cursor = page.sorted(by: EventCursor.relayOrder).last.map(EventCursor.init)
      }
    } catch is CancellationError { return } catch { emojiError = error.localizedDescription }
  }
}
