import BuzzCore
import Foundation
import Observation

/// One view's cursor chain. Network completion cannot mutate a retired conversation.
@MainActor @Observable
final class ConversationHistory {
  let workspace: Workspace
  let channelID: String
  let rootID: String?
  private(set) var loading = false
  private(set) var hasMore = true
  private(set) var error: String?
  private(set) var loaded = false
  /// Counts completed head reloads. A reset load replaces the whole row set:
  /// rows the relay's window no longer carries leave, and rows this device has
  /// never seen arrive. The conversation view watches this so it can re-anchor
  /// on the new newest row, instead of holding a scroll offset that belongs to
  /// the rows that left. Loading an older page does not count.
  private(set) var reloads = 0
  private var cursor: EventCursor?
  private var mode: ConversationPage.Mode?
  private var rowIDs = Set<String>()
  private var baselineIDs = Set<String>()
  private var pages = 0
  private var retryFromHead = false
  private var generation = UUID()
  private var operation: Task<Void, Never>?

  init(workspace: Workspace, channelID: String, rootID: String?) {
    self.workspace = workspace
    self.channelID = channelID
    self.rootID = rootID
  }

  var messages: [Event] {
    let messages = Projection.messages(
      events: workspace.visibleEvents, channelID: channelID, rootID: rootID,
      windowRowIDs: mode == .window ? rowIDs : nil)
    guard loaded else { return messages }
    let pending = Set(workspace.intents.pending.map(\.id))
    return messages.filter {
      $0.id == rootID || rowIDs.contains($0.id) || !baselineIDs.contains($0.id)
        || pending.contains($0.id)
    }
  }

  func refresh() async { _ = await load(reset: true) }
  @discardableResult func loadMore() async -> Bool { await load(reset: !loaded || retryFromHead) }

  func cancel() {
    generation = UUID()
    operation?.cancel()
    operation = nil
    loading = false
  }

  private func load(reset: Bool) async -> Bool {
    guard reset || (!loading && hasMore) else { return false }
    if reset { operation?.cancel() }
    let token = UUID()
    generation = token
    loading = true
    error = nil
    let baseline = Set(workspace.events.map(\.id))
    let hadCachedMessages = !Projection.messages(
      events: workspace.visibleEvents, channelID: channelID, rootID: rootID
    ).isEmpty
    let nextCursor = reset ? nil : cursor
    let nextMode = reset ? nil : mode
    let task = Task {
      defer {
        if generation == token {
          loading = false
          operation = nil
        }
      }
      do {
        guard reset || pages < 100 else {
          throw BuzzError.historyLimit
        }
        let authority: String
        if let cached = await workspace.store.relayAuthority() {
          authority = cached
        } else {
          authority = try await workspace.relay.authority()
          try await workspace.store.setRelayAuthority(authority)
        }
        let page = try await ConversationPage.fetch(
          relay: workspace.relay, channelID: channelID, rootID: rootID,
          authority: authority, after: nextCursor, mode: nextMode)
        try Task.checkCancellation()
        guard generation == token else { return }
        if reset, page.mode == .standard, page.events.isEmpty, hadCachedMessages {
          throw BuzzError.historyUnavailable
        }
        try await workspace.store.ingest(page.events, requiring: Set(page.events.map(\.id)))
        try Task.checkCancellation()
        guard generation == token else { return }
        let retained = Set(await workspace.store.cachedEvents().map(\.id))
        guard Set(page.events.map(\.id)).isSubset(of: retained) else {
          throw BuzzError.storage(
            "This history page could not fit in the local cache. Refresh to return to recent messages."
          )
        }
        guard generation == token else { return }
        if reset {
          rowIDs = []
          baselineIDs = baseline
          pages = 0
        }
        rowIDs.formUnion(page.rows.map(\.id))
        cursor = page.next
        mode = page.mode
        hasMore = page.next != nil
        loaded = true
        retryFromHead = false
        pages += 1
        await workspace.reload()
        if reset { reloads += 1 }
        await workspace.hydrateProfiles(for: page.rows)
      } catch is CancellationError { return } catch {
        guard generation == token else { return }
        retryFromHead = reset
        self.error = error.localizedDescription
        await workspace.reload()
      }
    }
    operation = task
    await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }
    return generation == token && !task.isCancelled && loaded && error == nil
  }
}
