import CryptoKit
import Foundation
import P256K

/// A validated NIP-AB QR invitation. Contains a one-time secret; never log it.
public struct PairingInvitation: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  /// The source device's ephemeral public key, not its user's identity.
  public let sourcePubkey: String
  /// The relay URLs explicitly selected by the source device.
  public let relays: [URL]
  let secret: [UInt8]

  /// Redacts the QR secret and relay query parameters from diagnostic output.
  public var description: String { "PairingInvitation(source: \(sourcePubkey))" }
  /// Redacts the QR secret from debugger output.
  public var debugDescription: String { description }

  /// Validates the URI, protocol version, source curve point and session secret.
  public init(uri: String) throws {
    guard uri.utf8.count <= 2048, uri.hasPrefix("nostrpair://"),
      let parts = URLComponents(string: uri), let host = parts.host,
      parts.user == nil, parts.password == nil, parts.port == nil,
      parts.path.isEmpty, parts.fragment == nil,
      host == host.lowercased(), host.utf8.count == 64,
      let sourceBytes = Hex.decode(host), let query = parts.queryItems
    else { throw PairingError.invalidInvitation }
    func single(_ name: String) throws -> String? {
      let values = query.filter { $0.name == name }
      guard values.count <= 1 else { throw PairingError.invalidInvitation }
      if let first = values.first, first.value == nil { throw PairingError.invalidInvitation }
      return values.first?.value
    }
    if let version = try single("v"), version != "1" {
      throw PairingError.unsupportedVersion
    }
    if let mode = try single("mode"), mode != "pair" {
      throw PairingError.unsupportedVersion
    }
    guard let secretHex = try single("secret"), secretHex.utf8.count == 64,
      secretHex == secretHex.lowercased(), let secret = Hex.decode(secretHex),
      secret.contains(where: { $0 != 0 })
    else { throw PairingError.invalidInvitation }
    do {
      _ = try P256K.KeyAgreement.PublicKey(dataRepresentation: [2] + sourceBytes)
    } catch { throw PairingError.invalidInvitation }
    let urls = try query.filter { $0.name == "relay" }.map { item -> URL in
      guard let value = item.value, let url = URL(string: value),
        let host = url.host, !host.isEmpty, ["wss", "ws"].contains(url.scheme),
        url.user == nil, url.password == nil, url.fragment == nil
      else { throw PairingError.invalidInvitation }
      return url
    }
    guard !urls.isEmpty else { throw PairingError.invalidInvitation }
    sourcePubkey = host
    self.secret = secret
    relays = urls
  }
}

struct PairingSecrets: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  var description: String { "PairingSecrets(redacted)" }
  var debugDescription: String { description }
  let sessionID: [UInt8]
  let sas: String
  let transcriptHash: [UInt8]
  let conversationKey: [UInt8]

  init(invitation: PairingInvitation, target: Identity) throws {
    let shared = try target.sharedX(with: invitation.sourcePubkey)
    sessionID = Self.derive(invitation.secret, salt: [], info: "nostr-pair-session-id")
    let sasInput = Self.derive(shared, salt: invitation.secret, info: "nostr-pair-sas-v1")
    let number = sasInput.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    sas = String(format: "%06u", number % 1_000_000)
    guard let sourceBytes = Hex.decode(invitation.sourcePubkey),
      let targetBytes = Hex.decode(target.pubkey)
    else { throw PairingError.invalidInvitation }
    transcriptHash = Self.derive(
      sessionID + sourceBytes + targetBytes + sasInput,
      salt: invitation.secret, info: "nostr-pair-transcript-v1")
    conversationKey = try NIP44.conversationKey(identity: target, peer: invitation.sourcePubkey)
  }

  private static func derive(_ bytes: [UInt8], salt: [UInt8], info: String) -> [UInt8] {
    HKDF<CryptoKit.SHA256>.deriveKey(
      inputKeyMaterial: SymmetricKey(data: bytes), salt: salt, info: Array(info.utf8),
      outputByteCount: 32
    ).withUnsafeBytes { Array($0) }
  }
}
