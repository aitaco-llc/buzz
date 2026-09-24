/// Strict NIP-19 encoding for portable Nostr identities.
public enum NostrKeyEncoding {
  /// Encodes exactly 32 bytes as an nsec. Does not validate the private scalar.
  public static func nsec(from bytes: [UInt8]) -> String? {
    guard bytes.count == 32,
      let values = Bech32.convertBits(bytes, fromBits: 8, toBits: 5, padding: true)
    else { return nil }
    return Bech32.encode(hrp: "nsec", values: values)
  }

  /// Decodes an nsec, checking its prefix, checksum, padding and exact byte length.
  public static func privateKeyBytes(from nsec: String) -> [UInt8]? {
    guard let decoded = Bech32.decode(nsec), decoded.hrp == "nsec",
      let bytes = Bech32.convertBits(decoded.values, fromBits: 5, toBits: 8, padding: false),
      bytes.count == 32
    else { return nil }
    return bytes
  }

  /// Encodes exactly 32 bytes as an npub.
  public static func npub(from bytes: [UInt8]) -> String? {
    Bech32.npub(from: bytes)
  }
}
