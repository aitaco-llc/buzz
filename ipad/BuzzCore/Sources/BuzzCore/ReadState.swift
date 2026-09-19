import Foundation

/// The encrypted read-state payload shared with the Flutter client.
public struct ReadStateBlob: Codable, Equatable, Sendable {
  public let version: Int
  public let clientID: String
  public let contexts: [String: Int]

  public init(clientID: String, contexts: [String: Int]) {
    version = 1
    self.clientID = clientID
    self.contexts = contexts
  }

  private enum CodingKeys: String, CodingKey {
    case version = "v"
    case clientID = "client_id"
    case contexts
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    guard try values.decode(Int.self, forKey: .version) == 1 else {
      throw BuzzError.invalidResponse
    }
    let client = try values.decode(String.self, forKey: .clientID)
    let contexts = try values.decode([String: Int].self, forKey: .contexts)
    guard !client.isEmpty, client.utf8.count <= 64, contexts.count <= 10_000,
      contexts.keys.allSatisfy({ $0.utf8.count <= 256 }),
      contexts.values.allSatisfy({ (0...4_294_967_295).contains($0) })
    else { throw BuzzError.invalidResponse }
    version = 1
    clientID = client
    self.contexts = contexts
  }
}

/// Read markers derived from verified, self-authored encrypted events.
public enum ReadStateProjection {
  public static let kind = 30078
  public static let dTag = "read-state:default"

  public static func contexts(events: [Event], identity: Identity) -> [String: Int] {
    var result: [String: Int] = [:]
    let key: [UInt8]
    do { key = try NIP44.conversationKey(identity: identity, peer: identity.pubkey) } catch {
      return result
    }
    let candidates = events.filter {
      $0.kind == kind && $0.pubkey == identity.pubkey && $0.tag("d") == dTag
        && $0.tags.filter({ $0.count >= 2 && $0[0] == "t" && $0[1] == "read-state" }).count == 1
    }.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    for event in candidates {
      guard let data = try? NIP44.decrypt(event.content, key: key),
        let blob = try? JSONDecoder().decode(ReadStateBlob.self, from: Data(data.utf8))
      else { continue }
      for (context, timestamp) in blob.contexts where timestamp > (result[context] ?? 0) {
        result[context] = timestamp
      }
    }
    return result
  }

  public static func contextKey(channelID: String) -> String { channelID }
  public static func messageKey(_ messageID: String) -> String { "msg:\(messageID)" }
  public static func threadKey(_ rootID: String) -> String { "thread:\(rootID)" }
}

/// The self-encryption helper used by the app's read-state writer.
public enum ReadStateCrypto {
  public static func encrypt(_ plaintext: String, identity: Identity) throws -> String {
    try NIP44.encrypt(
      plaintext, key: NIP44.conversationKey(identity: identity, peer: identity.pubkey))
  }
}
