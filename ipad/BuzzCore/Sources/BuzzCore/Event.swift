import BuzzPushKit
import CryptoKit
import Foundation
import P256K

/// The canonical signed Nostr wire event, shared with the iOS notification extension.
public typealias Event = VerifiedNostrEvent

extension VerifiedNostrEvent {
  /// First value of a named Nostr tag.
  public func tag(_ name: String) -> String? {
    tags.first { $0.count >= 2 && $0[0] == name }?[1]
  }

  /// Direct parent. Unmarked references are not thread relationships.
  public var parentID: String? {
    tags.first { $0.count >= 4 && $0[0] == "e" && $0[3] == "reply" }?[1]
  }

  /// Containing thread root, following the shared mobile reply convention.
  public var rootID: String? {
    guard let parentID else { return nil }
    return tags.first { $0.count >= 4 && $0[0] == "e" && $0[3] == "root" }?[1] ?? parentID
  }
}

/// Validation and transport failures that can be presented without exposing credentials.
public enum BuzzError: LocalizedError, Equatable, Sendable {
  case invalidKey, invalidRelay, invalidEvent, responseTooLarge, invalidResponse
  case rejected(String)
  case http(Int)
  case storage(String)
  case capacity
  case historyLimit
  case historyUnavailable

  /// Safe text for a user-facing recovery message.
  public var errorDescription: String? {
    switch self {
    case .invalidKey: "Enter a valid nsec or 64-character hexadecimal private key."
    case .invalidRelay: "Enter an HTTPS or WSS community URL without a path, credentials, or query."
    case .invalidEvent: "The relay returned an event with an invalid signature."
    case .responseTooLarge: "The relay response exceeded the size limit. Narrow the request."
    case .invalidResponse: "The relay returned an unexpected response."
    case .rejected(let reason): "The relay declined this action: \(reason)"
    case .http(let code): "The relay returned HTTP \(code)."
    case .storage(let reason): "Local data could not be saved: \(reason)"
    case .capacity:
      "The pending-action or draft storage limit was reached. Resolve pending actions first."
    case .historyLimit:
      "The history limit for this view was reached. Refresh to return to recent messages."
    case .historyUnavailable:
      "The relay returned no usable history. Cached messages are still available; try again."
    }
  }
}

/// Signs Nostr events with the same secp256k1 implementation as BuzzPushKit.
public struct Identity: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  private let bytes: [UInt8]
  /// The public, x-only Schnorr identity.
  public let pubkey: String

  /// A safe description that never includes secret key bytes.
  public var description: String { "Identity(pubkey: \(pubkey))" }
  /// A safe debugger description that never includes secret key bytes.
  public var debugDescription: String { description }

  /// Imports a private key; private material is never included in descriptions.
  public init(hex: String) throws {
    guard hex.utf8.count == 64, let bytes = Hex.decode(hex), bytes.count == 32 else {
      throw BuzzError.invalidKey
    }
    do {
      let key = try P256K.Schnorr.PrivateKey(dataRepresentation: bytes)
      self.bytes = bytes
      pubkey = Hex.encode(key.xonly.bytes)
    } catch { throw BuzzError.invalidKey }
  }

  /// Imports an nsec or hexadecimal private key, allowing surrounding whitespace.
  public init(encoded: String) throws {
    let value = encoded.trimmingCharacters(in: .whitespacesAndNewlines)
    if let bytes = NostrKeyEncoding.privateKeyBytes(from: value) {
      try self.init(hex: Hex.encode(bytes))
    } else {
      try self.init(hex: value)
    }
  }

  /// Creates a fresh identity using the system cryptographic random generator.
  public init() throws {
    let key = try P256K.Schnorr.PrivateKey()
    try self.init(hex: Hex.encode(key.dataRepresentation))
  }

  /// Private material for explicit Keychain storage or user-authorized export only.
  public var privateKeyHex: String { Hex.encode(bytes) }

  /// Portable secret for explicit user-authorized export only. Never log this value.
  public func nsec() throws -> String {
    guard let encoded = NostrKeyEncoding.nsec(from: bytes) else { throw BuzzError.invalidKey }
    return encoded
  }

  // NIP-44 uses the raw shared point's x coordinate, not its SHA-256 digest.
  func sharedX(with pubkey: String) throws -> [UInt8] {
    guard pubkey.utf8.count == 64, let peerBytes = Hex.decode(pubkey) else {
      throw BuzzError.invalidKey
    }
    do {
      let key = try P256K.KeyAgreement.PrivateKey(dataRepresentation: bytes)
      let peer = try P256K.KeyAgreement.PublicKey(dataRepresentation: [2] + peerBytes)
      return key.sharedSecretFromKeyAgreement(with: peer, format: .compressed)
        .withUnsafeBytes { Array($0.dropFirst()) }
    } catch { throw BuzzError.invalidKey }
  }

  /// Signs exactly one event. Retry delivery using this event, never a newly signed copy.
  public func sign(
    kind: Int, content: String, tags: [[String]],
    at timestamp: Int = Int(Date().timeIntervalSince1970)
  ) throws -> Event {
    guard (0...65535).contains(kind), timestamp >= 0 else { throw BuzzError.invalidEvent }
    let key = try P256K.Schnorr.PrivateKey(dataRepresentation: bytes)
    let canonical = try JSONSerialization.data(
      withJSONObject: [0, pubkey, timestamp, kind, tags, content],
      options: [.withoutEscapingSlashes])
    var digest = Array(SHA256.hash(data: canonical))
    let id = Hex.encode(digest)
    let signature = try key.signature(message: &digest, auxiliaryRand: nil)
    return Event(
      id: id, pubkey: pubkey, createdAt: timestamp, kind: kind,
      tags: tags, content: content, sig: Hex.encode(signature.dataRepresentation))
  }

  /// NIP-98 authorization with a nonce to avoid replay rejection of rapid identical requests.
  public func authorization(url: URL, body: Data) throws -> String {
    let event = try sign(
      kind: 27235, content: "",
      tags: [
        ["u", url.absoluteString], ["method", "POST"],
        ["payload", Hex.encode(SHA256.hash(data: body))], ["nonce", UUID().uuidString],
      ])
    return "Nostr " + (try JSONEncoder().encode(event)).base64EncodedString()
  }
}

enum Hex {
  static func encode(_ bytes: some Sequence<UInt8>) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
  }

  static func decode(_ value: String) -> [UInt8]? {
    let characters = Array(value.utf8)
    guard characters.count.isMultiple(of: 2),
      characters.allSatisfy({
        (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
      })
    else { return nil }
    return stride(from: 0, to: characters.count, by: 2).compactMap {
      UInt8(String(decoding: characters[$0..<$0 + 2], as: UTF8.self), radix: 16)
    }
  }
}
