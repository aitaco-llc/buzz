import CryptoKit
import CryptoSwift
import Darwin
import Foundation

/// Pairing failures contain no peer-supplied secret material.
public enum PairingError: LocalizedError, Equatable, Sendable {
  case invalidInvitation, unsupportedVersion, invalidCiphertext, invalidPayload
  case transcriptMismatch, expired, ended

  /// A recovery message safe to show on screen.
  public var errorDescription: String? {
    switch self {
    case .invalidInvitation: "This pairing code is invalid. Generate a new code on your desktop."
    case .unsupportedVersion: "This pairing format is not supported by this version of Buzz."
    case .invalidCiphertext: "The encrypted pairing message could not be verified."
    case .invalidPayload: "The other device did not send a valid Buzz identity and community."
    case .transcriptMismatch: "Pairing verification failed. Start again with a new code."
    case .expired: "Pairing expired. Generate a new code on your desktop."
    case .ended: "This pairing session has ended. Start again with a new code."
    }
  }
}

// NIP-AB intentionally retains the 65,535-byte limit even though newer NIP-44
// revisions allow larger plaintexts. This bounds unauthenticated input allocation.
enum NIP44 {
  static func conversationKey(identity: Identity, peer: String) throws -> [UInt8] {
    Array(
      CryptoKit.HMAC<CryptoKit.SHA256>.authenticationCode(
        for: try identity.sharedX(with: peer),
        using: SymmetricKey(data: Data("nip44-v2".utf8))))
  }

  static func encrypt(_ plaintext: String, key: [UInt8]) throws -> String {
    let nonce = SymmetricKey(size: .bits256).withUnsafeBytes { Array($0) }
    return try encrypt(plaintext, key: key, nonce: nonce)
  }

  // Deterministic nonce injection is internal and used only by interoperability tests.
  static func encrypt(_ plaintext: String, key: [UInt8], nonce: [UInt8]) throws -> String {
    let bytes = Array(plaintext.utf8)
    guard (1...65535).contains(bytes.count) else { throw PairingError.invalidPayload }
    let keys = try messageKeys(key: key, nonce: nonce)
    let padded =
      [UInt8(bytes.count >> 8), UInt8(bytes.count & 255)] + bytes
      + [UInt8](repeating: 0, count: paddedLength(bytes.count) - bytes.count)
    let encrypted = try ChaCha20(key: Array(keys[0..<32]), iv: Array(keys[32..<44]))
      .encrypt(padded)
    let mac = CryptoKit.HMAC<CryptoKit.SHA256>.authenticationCode(
      for: nonce + encrypted, using: SymmetricKey(data: keys[44..<76]))
    return Data([2] + nonce + encrypted + Array(mac)).base64EncodedString()
  }

  // The caller must verify the enclosing event signature before decrypting.
  static func decrypt(_ payload: String, key: [UInt8]) throws -> String {
    var bytes = try decryptData(payload, key: key)
    defer { bytes.resetBytes(in: 0..<bytes.count) }
    guard let text = String(data: bytes, encoding: .utf8) else {
      throw PairingError.invalidCiphertext
    }
    return text
  }

  static func decryptData(_ payload: String, key: [UInt8]) throws -> Data {
    guard (132...87472).contains(payload.utf8.count),
      let data = Data(base64Encoded: payload), data.count >= 99
    else { throw PairingError.invalidCiphertext }
    guard data[0] == 2 else { throw PairingError.unsupportedVersion }
    let nonce = Array(data[1..<33])
    let keys = try messageKeys(key: key, nonce: nonce)
    let ciphertext = Array(data[33..<(data.count - 32)])
    guard
      CryptoKit.HMAC<CryptoKit.SHA256>.isValidAuthenticationCode(
        data.suffix(32), authenticating: nonce + ciphertext,
        using: SymmetricKey(data: keys[44..<76]))
    else { throw PairingError.invalidCiphertext }
    var padded = try ChaCha20(key: Array(keys[0..<32]), iv: Array(keys[32..<44]))
      .decrypt(ciphertext)
    defer {
      padded.withUnsafeMutableBytes { buffer in
        if let address = buffer.baseAddress {
          _ = memset_s(address, buffer.count, 0, buffer.count)
        }
      }
    }
    let length = Int(padded[0]) * 256 + Int(padded[1])
    guard length > 0, length <= padded.count - 2,
      padded.count == 2 + paddedLength(length),
      padded[(length + 2)...].allSatisfy({ $0 == 0 })
    else { throw PairingError.invalidCiphertext }
    return Data(padded[2..<(length + 2)])
  }

  static func paddedLength(_ length: Int) -> Int {
    guard length > 32 else { return 32 }
    var power = 32
    while power < length { power *= 2 }
    let chunk = power <= 256 ? 32 : power / 8
    return ((length - 1) / chunk + 1) * chunk
  }

  private static func messageKeys(key: [UInt8], nonce: [UInt8]) throws -> [UInt8] {
    guard key.count == 32, nonce.count == 32 else { throw PairingError.invalidCiphertext }
    return CryptoKit.HKDF<CryptoKit.SHA256>.expand(
      pseudoRandomKey: Data(key), info: nonce, outputByteCount: 76
    ).withUnsafeBytes { Array($0) }
  }
}
