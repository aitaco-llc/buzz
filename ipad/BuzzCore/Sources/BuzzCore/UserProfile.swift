import Foundation

/// The parts of a kind:0 the UI draws: a name, an avatar, and whether this
/// identity is an agent.
///
/// Mirrors `mobile/lib/shared/profile/user_profile.dart`. Resolving these
/// together matters because the avatar and the agent marker come from different
/// places in the same event — `picture` from the JSON content, the owner from a
/// signed `auth` tag — and a row that reads one without the other draws an
/// agent as a person.
public struct UserProfile: Equatable, Sendable {
  public let pubkey: String
  public let displayName: String
  public let pictureURL: URL?
  /// The verified NIP-OA owner. Non-nil means this identity is an agent.
  public let ownerPubkey: String?

  public var isAgent: Bool { ownerPubkey != nil }

  /// The letter tile fallback, for a profile with no picture or a picture that
  /// fails to load.
  public var initial: String {
    let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    return String(trimmed.first.map(String.init)?.uppercased() ?? "?")
  }

  public init(pubkey: String, displayName: String, pictureURL: URL?, ownerPubkey: String?) {
    self.pubkey = pubkey
    self.displayName = displayName
    self.pictureURL = pictureURL
    self.ownerPubkey = ownerPubkey
  }
}

/// Resolves kind:0 events into drawable profiles, caching the NIP-OA check.
///
/// Verifying an owner attestation is a Schnorr verification. A conversation
/// redraws its rows constantly, so doing that per row would burn the CPU on a
/// result that only changes when the profile event does — the cache is keyed by
/// the profile event id for exactly that reason.
public final class ProfileIndex: @unchecked Sendable {
  private let lock = NSLock()
  private var owners: [String: String?] = [:]

  public init() {}

  public func profile(pubkey: String, events: [Event]) -> UserProfile {
    guard
      let event = events.filter({ $0.kind == 0 && $0.pubkey == pubkey })
        .max(by: { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) })
    else {
      return UserProfile(
        pubkey: pubkey, displayName: String(pubkey.prefix(12)), pictureURL: nil, ownerPubkey: nil)
    }
    return profile(event: event)
  }

  public func profile(event: Event) -> UserProfile {
    let fields: [String: Any] =
      event.content.data(using: .utf8)
      .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    let name =
      fields["display_name"] as? String ?? fields["name"] as? String
      ?? String(event.pubkey.prefix(12))
    // An empty or whitespace `picture` is common and is not a URL.
    let picture = (fields["picture"] as? String)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .flatMap { $0.isEmpty ? nil : URL(string: $0) }
    return UserProfile(
      pubkey: event.pubkey, displayName: name, pictureURL: picture,
      ownerPubkey: owner(of: event))
  }

  private func owner(of event: Event) -> String? {
    lock.lock()
    if let cached = owners[event.id] {
      lock.unlock()
      return cached
    }
    lock.unlock()
    let resolved = NIPOA.verifiedOwnerPubkey(tags: event.tags, agentPubkey: event.pubkey)
    lock.lock()
    // Bound the cache: a long session sees many profile revisions.
    if owners.count > 512 { owners.removeAll(keepingCapacity: true) }
    owners[event.id] = resolved
    lock.unlock()
    return resolved
  }
}
