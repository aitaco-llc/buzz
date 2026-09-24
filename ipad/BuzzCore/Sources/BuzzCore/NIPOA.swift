import CryptoKit
import Foundation
import P256K

/// NIP-OA (Owner Attestation) — the proof on a kind:0 profile that an owner key
/// authorized an agent key.
///
/// Tag:       ["auth", "<owner-pubkey-hex>", "<conditions>", "<sig-hex>"]
/// Preimage:  "nostr:agent-auth:" + agent_pubkey_hex + ":" + conditions
/// Signature: BIP-340 Schnorr over SHA256(preimage), by the owner key.
///
/// Ported from `mobile/lib/shared/crypto/nip_oa.dart`, which mirrors
/// `profile_valid_oa_owner_pubkey` in desktop. The signature is checked against
/// the profile event's own author, so an unsigned or copied marker cannot turn
/// a person into an agent — which is the whole point, since this is what
/// decides whether the UI draws a square agent tile or a round person avatar.
public enum NIPOA {
  /// The owner pubkey from the first auth tag that verifies, or nil.
  public static func verifiedOwnerPubkey(tags: [[String]], agentPubkey: String) -> String? {
    let agent = agentPubkey.lowercased()
    for tag in tags {
      guard tag.count == 4, tag[0] == "auth" else { continue }
      let owner = tag[1].lowercased()
      let conditions = tag[2]
      let signature = tag[3].lowercased()
      // Self-attestation proves nothing.
      guard owner != agent, owner.utf8.count == 64, signature.utf8.count == 128,
        validConditions(conditions), let ownerBytes = Hex.decode(owner),
        ownerBytes.count == 32, let signatureBytes = Hex.decode(signature),
        signatureBytes.count == 64
      else { continue }

      // The signed message is the raw 32-byte digest. `hash_preimage` in
      // `crates/buzz-sdk/src/nip_oa.rs` builds it with `Message::from_digest`,
      // so hex text here would verify nothing.
      let preimage = Data("nostr:agent-auth:\(agent):\(conditions)".utf8)
      var message = Array(SHA256.hash(data: preimage))
      guard
        let parsed = try? P256K.Schnorr.SchnorrSignature(dataRepresentation: Data(signatureBytes))
      else { continue }
      if P256K.Schnorr.XonlyKey(dataRepresentation: ownerBytes).isValid(parsed, for: &message) {
        return owner
      }
    }
    return nil
  }

  /// Empty, or `&`-joined `kind=<n>` / `created_at<<n>` / `created_at><n>`
  /// clauses with canonical decimals.
  static func validConditions(_ conditions: String) -> Bool {
    if conditions.isEmpty { return true }
    if conditions.contains(where: { $0.isWhitespace }) { return false }
    for clause in conditions.split(separator: "&", omittingEmptySubsequences: false) {
      let digits: Substring
      if clause.hasPrefix("kind=") {
        digits = clause.dropFirst("kind=".count)
      } else if clause.hasPrefix("created_at<") {
        digits = clause.dropFirst("created_at<".count)
      } else if clause.hasPrefix("created_at>") {
        digits = clause.dropFirst("created_at>".count)
      } else {
        return false
      }
      // Canonical decimal only: no sign, no padding, no empty run.
      guard !digits.isEmpty, digits.allSatisfy(\.isNumber),
        digits == "0" || !digits.hasPrefix("0"), let value = UInt64(digits), value <= 4_294_967_295
      else { return false }
      if clause.hasPrefix("kind="), value > 65535 { return false }
    }
    return true
  }
}
