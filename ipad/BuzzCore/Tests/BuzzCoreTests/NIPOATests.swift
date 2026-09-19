import Foundation
import Testing

@testable import BuzzCore

/// This marker is what decides whether the UI draws an agent or a person, so a
/// verifier that accepted anything would let any profile claim to be an agent.
///
/// The vectors are BIP-340 signatures produced by an independent implementation
/// over `SHA256("nostr:agent-auth:<agent>:<conditions>")`, matching
/// `hash_preimage` in `crates/buzz-sdk/src/nip_oa.rs`.
@Suite struct NIPOATests {
  private let owner = "4f355bdcb7cc0af728ef3cceb9615d90684bb5b2ca5f859ab0f0b704075871aa"
  private let agent = String(repeating: "22", count: 32)
  private let bareSig =
    "9a5d503d2285832379ec58e776771688dcc38900f89cfa229b0922c17243bf96"
    + "a7a654eeca3d0d506139eeb06284e9f27887779217f9688c15a5b7ecf4462c7d"
  private let scopedSig =
    "9de9b4ea5ceaa7f9cb947bd7f0f79021561dc6c9975a1ba3c5df11300b5a935f"
    + "a6707ad298f765adfc77e707654bbae51342b8a74aef05194f8b11ac892830c7"

  @Test func acceptsASignatureFromTheOwnerOverTheAgentPreimage() {
    #expect(
      NIPOA.verifiedOwnerPubkey(tags: [["auth", owner, "", bareSig]], agentPubkey: agent) == owner)
    #expect(
      NIPOA.verifiedOwnerPubkey(
        tags: [["auth", owner, "kind=9&created_at>100", scopedSig]], agentPubkey: agent) == owner)
  }

  @Test func rejectsEveryWayTheMarkerCanBeFaked() {
    // A signature that is valid for different conditions must not carry over —
    // the conditions are inside the preimage.
    #expect(
      NIPOA.verifiedOwnerPubkey(
        tags: [["auth", owner, "kind=9&created_at>100", bareSig]], agentPubkey: agent) == nil)
    // Valid signature, but replayed onto a different agent.
    #expect(
      NIPOA.verifiedOwnerPubkey(
        tags: [["auth", owner, "", bareSig]], agentPubkey: String(repeating: "33", count: 32))
        == nil)
    // Self-attestation.
    #expect(
      NIPOA.verifiedOwnerPubkey(tags: [["auth", agent, "", bareSig]], agentPubkey: agent) == nil)
    // Unsigned or malformed markers.
    #expect(NIPOA.verifiedOwnerPubkey(tags: [["auth", owner, ""]], agentPubkey: agent) == nil)
    #expect(
      NIPOA.verifiedOwnerPubkey(
        tags: [["auth", owner, "", String(repeating: "0", count: 128)]], agentPubkey: agent) == nil)
    #expect(
      NIPOA.verifiedOwnerPubkey(tags: [["p", owner, "", bareSig]], agentPubkey: agent) == nil)
    #expect(NIPOA.verifiedOwnerPubkey(tags: [], agentPubkey: agent) == nil)
  }

  @Test func conditionsGrammarMatchesTheSpec() {
    for valid in ["", "kind=9", "created_at<100", "created_at>0", "kind=9&created_at>100"] {
      #expect(NIPOA.validConditions(valid), "should accept \(valid)")
    }
    for invalid in [
      "kind=9 ", "kind=09", "kind=65536", "created_at>4294967296", "kind=", "kind=9&",
      "created_at=100", "nonsense", "kind=-1",
    ] {
      #expect(!NIPOA.validConditions(invalid), "should reject \(invalid)")
    }
  }
}
