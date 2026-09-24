import BuzzCore
import BuzzPushKit
import Foundation

/// Exports the verified native workspace state consumed by NotificationService.
/// The extension never reads the app's private cache directly; this bounded
/// snapshot is the sole app-group presentation surface.
@MainActor
enum NativePushBridge {
  static let appGroupIdentifier = "group.co.aitaco.buzz"

  static func refresh(workspace: Workspace) async {
    guard
      let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    else { return }
    let pubkey = workspace.account.pubkey
    guard !pubkey.isEmpty else { return }
    let relayOrigin = workspace.account.community.origin.absoluteString
    let muted = NativePreferences().mutedChannels
    let activeChannelIDs = workspace.channels
      .filter { !muted.contains($0.id) }
      .map(\.id)
    let channelFilter = workspace.channels.isEmpty ? nil : activeChannelIDs
    let community = PushLeaseCommunity(
      id: workspace.account.community.id,
      name: workspace.account.community.name,
      relayUrl: relayOrigin,
      relayMetadataPubkey: await workspace.store.relayAuthority(),
      pubkey: pubkey,
      policies: [
        PushResolutionPolicy(
          filter: PushLeaseFilter(
            kinds: [9, 40002, 45001, 45003], pTags: [pubkey], hTags: channelFilter))
      ])
    let store = BuzzPushPresentationCacheStore(containerURL: container)
    do {
      try store.replaceCommunities([community])
      let authority = await workspace.store.relayAuthority()
      let profileEvents = workspace.events.filter { $0.kind == 0 }
      try store.updateProfiles(
        communityID: workspace.account.community.id,
        relayOrigin: relayOrigin,
        updates: profileEvents.map { BuzzPushProfileCacheUpdate(event: $0) })
      let metadata = workspace.events.filter {
        $0.kind == 39000 && (authority == nil || $0.pubkey == authority)
      }
      let membership = workspace.events.filter {
        $0.kind == 39002 && (authority == nil || $0.pubkey == authority)
      }
      if let authority {
        try store.updateChannels(
          communityID: workspace.account.community.id,
          relayOrigin: relayOrigin,
          relayMetadataPubkey: authority,
          metadataEvents: metadata,
          membershipEvents: membership)
      }
    } catch {
      // Push enrichment is recoverable; it must not block relay access.
    }
  }
}
