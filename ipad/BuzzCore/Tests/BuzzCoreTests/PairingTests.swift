import BuzzPushKit
import Foundation
import Testing

@testable import BuzzCore

private let one = String(repeating: "0", count: 63) + "1"
private let sourceSecret = "7f4c11a9c9d1e3b5a7f2e4d6c8b0a2f4e6d8c0b2a4f6e8d0c2b4a6f8e0d2c4b5"
private let targetSecret = "3a5b7c9d1e3f5a7b9c1d3e5f7a9b1c3d5e7f9a1b3c5d7e9f1a3b5c7d9e1f3a5b"
private let sessionSecret = "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2"
private let sourcePubkey = "199e64ca60662cb2d6e91d16cb065be51ad74a6ee5f8c5b0fdc53d246611ed9a"
private let uri =
  "nostrpair://\(sourcePubkey)?secret=\(sessionSecret)&relay=wss%3A%2F%2Fpair.example&v=1"

struct PairingTests {
  @Test func portableIdentityRoundTripAndStrictRejection() throws {
    let identity = try Identity(hex: one)
    let encoded = try identity.nsec()
    #expect(!String(describing: identity).contains(one))
    #expect(!String(reflecting: identity).contains(encoded))
    #expect(try Identity(encoded: " \n" + encoded + "\n").pubkey == identity.pubkey)
    #expect(try Identity(encoded: encoded.uppercased()).privateKeyHex == one)
    #expect(try Identity(encoded: one.uppercased()).privateKeyHex == one)
    let zero = try #require(NostrKeyEncoding.nsec(from: Array(repeating: 0, count: 32)))
    let npub = try #require(NostrKeyEncoding.npub(from: Array(repeating: 1, count: 32)))
    for invalid in [
      zero, npub, "N" + encoded.dropFirst(), String(encoded.dropLast()) + "x",
      encoded + "q", String(repeating: "f", count: 64),
    ] {
      #expect(throws: BuzzError.invalidKey) { try Identity(encoded: invalid) }
    }
    let generated = try Identity()
    #expect(try Identity(encoded: generated.nsec()).pubkey == generated.pubkey)
    #expect(try generated.sign(kind: 0, content: "{}", tags: []).hasValidIDAndSignature())
  }

  @Test func desktopNIP44Interoperability() throws {
    // Independent nostr-rs ciphertext also consumed by Flutter's nip44_interop_test.dart.
    let ciphertext =
      "Au0C/BZ3gT83RnPFiPYGr70BuEyKDlZrk1nEJUDZbkoNgpSjE7JUKRb3VRbegcQYUvNT2Qayf3DkfuSb1M6l70IDpsQ25y8xwDA+uEreyRxDdZ5tQF+C9iB3Qr0vinFQpbR9f0SIvUahwAzyHBMdZ1butlCHi9aqv0C1/w1MWMWeoGaPm4XtkhJSPawCGMuFVw1Z8r64bxMSI6EThc4HtR9p4Q=="
    let identity = try Identity(hex: one)
    let key = try NIP44.conversationKey(identity: identity, peer: identity.pubkey)
    let plaintext =
      "{\"version\":1,\"theme\":\"catppuccin-latte\",\"accent\":\"#f97316\",\"followSystem\":false}"
    #expect(try NIP44.decrypt(ciphertext, key: key) == plaintext)
    let data = try #require(Data(base64Encoded: ciphertext))
    #expect(try NIP44.encrypt(plaintext, key: key, nonce: Array(data[1..<33])) == ciphertext)
    for position in [1, 33, data.count - 1] {
      var altered = data
      altered[position] ^= 1
      #expect(throws: PairingError.invalidCiphertext) {
        try NIP44.decrypt(altered.base64EncodedString(), key: key)
      }
    }
  }

  @Test func encryptionLimitsAndPaddingBoundaries() throws {
    let key = Array(repeating: UInt8(1), count: 32)
    for count in [1, 32, 33, 64, 65, 255, 256, 257, 1024, 65535] {
      let plaintext = String(repeating: "x", count: count)
      #expect(try NIP44.decrypt(NIP44.encrypt(plaintext, key: key), key: key) == plaintext)
    }
    for plaintext in ["", String(repeating: "x", count: 65536)] {
      #expect(throws: PairingError.invalidPayload) { try NIP44.encrypt(plaintext, key: key) }
    }
    for ciphertext in [
      "", String(repeating: "A", count: 87473), String(repeating: "!", count: 132),
    ] {
      #expect(throws: PairingError.invalidCiphertext) { try NIP44.decrypt(ciphertext, key: key) }
    }
    #expect(throws: BuzzError.invalidKey) {
      try Identity(hex: one).sharedX(with: String(repeating: "f", count: 64))
    }
  }

  @Test func officialNIPABDerivationVectors() throws {
    let source = try Identity(hex: sourceSecret)
    let target = try Identity(hex: targetSecret)
    #expect(source.pubkey == sourcePubkey)
    #expect(target.pubkey == "89a9fa762105d0aee2b19678246fe7b823aabbc4f4bf691a1ce8a70fcd36d6e4")
    #expect(
      try Hex.encode(target.sharedX(with: source.pubkey))
        == "9b4b6d6990713d89d6d9982e506ee1bbcde6f05c54d9d2978696e8a7274d4408")
    let secrets = try PairingSecrets(invitation: PairingInvitation(uri: uri), target: target)
    #expect(
      Hex.encode(secrets.sessionID)
        == "fb357d0f8e8d5a5ba3b2a91cb18c119e1567b07ffa38cdebb73e68df78f5a380")
    #expect(secrets.sas == "863346")
    #expect(
      Hex.encode(secrets.transcriptHash)
        == "d662818ff8911fc60a2d025f8b8b4756107104e85888dd202d28db5ca2cf28d3")
  }

  @Test func invitationRejectsAmbiguityAndUnsupportedFormats() throws {
    #expect(try PairingInvitation(uri: uri).relays.first?.absoluteString == "wss://pair.example")
    for invalid in [
      uri + "&v=2", uri.replacingOccurrences(of: "v=1", with: "v=2"),
      uri + "&secret=\(sessionSecret)",
      uri.replacingOccurrences(of: sourcePubkey, with: sourcePubkey.uppercased()),
      uri.replacingOccurrences(of: sessionSecret, with: String(repeating: "0", count: 64)),
      uri.replacingOccurrences(of: sourcePubkey, with: String(repeating: "f", count: 64)),
      uri.replacingOccurrences(of: "wss%3A", with: "https%3A"),
      uri + "&mode=recover", uri + String(repeating: "x", count: 2048),
    ] {
      #expect(throws: PairingError.self) { try PairingInvitation(uri: invalid) }
    }
  }

  @Test func receiverRequiresDualConsentInEitherOrder() throws {
    for localFirst in [false, true] {
      let fixture = try PairingFixture()
      var receiver = try fixture.receiver()
      let offer = try receiver.offer()
      #expect(offer.hasValidIDAndSignature())
      #expect(offer.pubkey == fixture.target.pubkey)
      let decodedOffer = try fixture.decode(offer)
      #expect(decodedOffer["session_id"] as? String == Hex.encode(fixture.secrets.sessionID))
      #expect(throws: PairingError.invalidPayload) { try receiver.complete() }
      if localFirst { #expect(try receiver.confirm() == nil) }
      #expect(try receiver.receive(fixture.confirmation()) == nil)
      let payload = try fixture.payload()
      let imported: PairingImport?
      if localFirst {
        imported = try receiver.receive(payload)
      } else {
        #expect(receiver.phase == .awaitingConfirmation)
        #expect(try receiver.receive(payload) == nil)
        #expect(try receiver.receive(payload) == nil)
        #expect(receiver.phase == .awaitingConfirmation)
        imported = try receiver.confirm()
      }
      #expect(imported?.identity.privateKeyHex == one)
      #expect(imported?.community.id == "https://buzz.example")
      #expect(receiver.phase == .importing)
      #expect(try receiver.receive(payload) == nil)
      #expect(try receiver.confirm() == nil)
      let complete = try receiver.complete()
      #expect(try fixture.decode(complete)["success"] as? Bool == true)
      #expect(receiver.phase == .finished)
      #expect(throws: PairingError.ended) { try receiver.offer() }
    }
  }

  @Test func secretPayloadIsNotParsedBeforeLocalConsent() throws {
    let fixture = try PairingFixture()
    var receiver = try fixture.receiver()
    _ = try receiver.receive(fixture.confirmation())
    let invalidPayload = try fixture.peerMessage([
      "type": "payload", "payload_type": "custom", "payload": "not JSON or a private key",
    ])
    // Extracting or parsing the payload too early would throw here.
    #expect(try receiver.receive(invalidPayload) == nil)
    #expect(receiver.phase == .awaitingConfirmation)
    #expect(throws: PairingError.invalidPayload) { try receiver.confirm() }
  }

  @Test func mismatchDenialTimeoutAndOutOfOrderNeverReleaseSecrets() throws {
    let fixture = try PairingFixture()
    let payload = try fixture.payload()
    var receiver = try fixture.receiver()
    #expect(try receiver.receive(payload) == nil)
    #expect(receiver.phase == .confirming)
    _ = try receiver.confirm()
    let wrong = try fixture.peerMessage([
      "type": "sas-confirm", "transcript_hash": String(repeating: "0", count: 64),
    ])
    #expect(throws: PairingError.transcriptMismatch) { try receiver.receive(wrong) }
    #expect(throws: PairingError.ended) { try receiver.receive(fixture.confirmation()) }
    let aborted = try receiver.abort(mismatch: true)
    let abort = try #require(aborted)
    #expect(try fixture.decode(abort)["reason"] as? String == "sas_mismatch")
    #expect(try receiver.abort() == nil)

    receiver = try fixture.receiver()
    _ = try receiver.receive(fixture.confirmation())
    _ = try receiver.receive(payload)
    _ = try receiver.abort()
    #expect(throws: PairingError.ended) { try receiver.confirm() }
    let now = ContinuousClock.now
    receiver = try fixture.receiver(now: now)
    #expect(throws: PairingError.expired) {
      try receiver.active(now: now.advanced(by: .seconds(120)))
    }
    #expect(receiver.phase == .finished)

    receiver = try fixture.receiver()
    _ = try receiver.confirm()
    // Discarded out-of-order delivery must not poison deduplication for a valid retry.
    #expect(try receiver.receive(payload) == nil)
    _ = try receiver.receive(fixture.confirmation())
    #expect(try receiver.receive(payload)?.identity.privateKeyHex == one)
  }

  @Test func receiverRejectsWrongPeerRecipientAndTamperedEvents() throws {
    let fixture = try PairingFixture()
    var receiver = try fixture.receiver()
    let valid = try fixture.confirmation()
    let other = try Identity(hex: one)
    let wrongPeer = try other.sign(kind: 24134, content: valid.content, tags: valid.tags)
    let wrongRecipient = try fixture.source.sign(
      kind: 24134, content: valid.content, tags: [["p", other.pubkey]])
    let tampered = Event(
      id: valid.id, pubkey: valid.pubkey, createdAt: valid.createdAt,
      kind: valid.kind, tags: valid.tags, content: valid.content + "!", sig: valid.sig)
    for invalid in [wrongPeer, wrongRecipient, tampered] {
      #expect(try receiver.receive(invalid) == nil)
      #expect(receiver.phase == .confirming)
    }
    _ = try receiver.receive(valid)
    #expect(receiver.phase == .awaitingConfirmation)
    _ = try receiver.receive(valid)
    #expect(receiver.phase == .awaitingConfirmation)
    let wrongKey = try fixture.payload(pubkey: fixture.source.pubkey)
    _ = try receiver.confirm()
    #expect(throws: PairingError.invalidPayload) { try receiver.receive(wrongKey) }
  }
}

private struct PairingFixture {
  let source: Identity
  let target: Identity
  let invitation: PairingInvitation
  let secrets: PairingSecrets

  init() throws {
    source = try Identity(hex: sourceSecret)
    target = try Identity(hex: targetSecret)
    invitation = try PairingInvitation(uri: uri)
    secrets = try PairingSecrets(invitation: invitation, target: target)
  }

  func receiver(now: ContinuousClock.Instant = .now) throws -> PairingReceiver {
    try PairingReceiver(invitation: invitation, target: target, now: now)
  }

  func peerMessage(_ body: [String: Any]) throws -> Event {
    let data = try JSONSerialization.data(withJSONObject: body)
    return try source.sign(
      kind: 24134,
      content: NIP44.encrypt(String(decoding: data, as: UTF8.self), key: secrets.conversationKey),
      tags: [["p", target.pubkey]])
  }

  func confirmation() throws -> Event {
    try peerMessage(["type": "sas-confirm", "transcript_hash": Hex.encode(secrets.transcriptHash)])
  }

  func payload(pubkey: String? = nil) throws -> Event {
    let identity = try Identity(hex: one)
    let data = try JSONSerialization.data(withJSONObject: [
      "relayUrl": "wss://buzz.example", "pubkey": pubkey ?? identity.pubkey,
      "nsec": identity.nsec(),
    ])
    return try peerMessage([
      "type": "payload", "payload_type": "custom", "payload": String(decoding: data, as: UTF8.self),
    ])
  }

  func decode(_ event: Event) throws -> [String: Any] {
    let data = Data(try NIP44.decrypt(event.content, key: secrets.conversationKey).utf8)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }
}
