import CryptoKit
import Foundation

/// Validated credentials released only after both devices confirm the pairing code.
public struct PairingImport: Sendable {
  /// The community carried by the source's Buzz payload.
  public let community: Community
  /// The transferred identity, whose public key matches the payload.
  public let identity: Identity

  init(plaintext: Data) throws {
    struct Envelope: Decodable {
      let type: String
      let payloadType: String
      let payload: String
      enum CodingKeys: String, CodingKey {
        case type, payload
        case payloadType = "payload_type"
      }
    }
    struct Payload: Decodable {
      let relayUrl: String
      let pubkey: String
      let nsec: String
    }
    do {
      let envelope = try JSONDecoder().decode(Envelope.self, from: plaintext)
      guard envelope.type == "payload", envelope.payloadType == "custom" else {
        throw PairingError.invalidPayload
      }
      let payload = try JSONDecoder().decode(Payload.self, from: Data(envelope.payload.utf8))
      let identity = try Identity(encoded: payload.nsec)
      guard identity.pubkey == payload.pubkey else { throw PairingError.invalidPayload }
      self.identity = identity
      community = try Community(url: payload.relayUrl, name: "")
    } catch { throw PairingError.invalidPayload }
  }
}

/// NIP-AB receiving state machine. Its owner serializes calls and closes transport on termination.
public struct PairingReceiver: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  /// State-only diagnostics; ephemeral keys and buffered credentials remain private.
  public var description: String { "PairingReceiver(phase: \(phase))" }
  /// State-only debugger output.
  public var debugDescription: String { description }
  /// Progress through dual consent and durable credential import.
  public enum Phase: Sendable, Equatable {
    case confirming, awaitingConfirmation, transferring, importing, finished
  }

  /// State for the pairing UI. An importing state does not yet mean credentials are saved.
  public private(set) var phase: Phase = .confirming
  /// Six digits to compare visually on both devices before confirming.
  public let code: String
  /// Ephemeral subscription recipient, unrelated to the transferred identity.
  public let pubkey: String
  private var context: Context?
  private var userConfirmed = false
  private var transcriptVerified = false
  private var buffered: Event?
  private var processed: Set<String> = []
  private let deadline: ContinuousClock.Instant

  private struct Context: Sendable {
    let invitation: PairingInvitation
    let target: Identity
    let secrets: PairingSecrets
  }

  /// Starts a fresh, at most 120-second session with a newly generated ephemeral identity.
  public init(invitation: PairingInvitation) throws {
    try self.init(invitation: invitation, target: Identity(), now: .now)
  }

  init(invitation: PairingInvitation, target: Identity, now: ContinuousClock.Instant) throws {
    let secrets = try PairingSecrets(invitation: invitation, target: target)
    context = Context(invitation: invitation, target: target, secrets: secrets)
    code = secrets.sas
    pubkey = target.pubkey
    deadline = now.advanced(by: .seconds(120))
  }

  /// The initial signed offer proving possession of the one-time QR secret.
  public mutating func offer() throws -> Event {
    let context = try active()
    return try message(
      [
        "type": "offer", "version": 1, "session_id": Hex.encode(context.secrets.sessionID),
      ], context: context)
  }

  /// Answers NIP-42 with the ephemeral identity; the real identity never authenticates to this relay.
  public mutating func authenticate(challenge: String, relay: URL) throws -> Event {
    let context = try active()
    guard context.invitation.relays.contains(relay), challenge.utf8.count <= 4096 else {
      throw PairingError.invalidInvitation
    }
    return try context.target.sign(
      kind: 22242, content: "", tags: [["relay", relay.absoluteString], ["challenge", challenge]])
  }

  /// Records explicit local user consent. May release a ciphertext buffered after source consent.
  public mutating func confirm() throws -> PairingImport? {
    _ = try active()
    guard phase != .importing else { return nil }
    userConfirmed = true
    guard transcriptVerified else { return nil }
    phase = .transferring
    guard let event = buffered else { return nil }
    buffered = nil
    return try receive(event)
  }

  /// Verifies and processes a peer event. Invalid and out-of-order events are silently discarded.
  public mutating func receive(_ event: Event) throws -> PairingImport? {
    let context = try active()
    guard (132...87472).contains(event.content.utf8.count), event.kind == 24134,
      event.pubkey == context.invitation.sourcePubkey,
      event.tags.contains(where: { $0.count >= 2 && $0[0] == "p" && $0[1] == pubkey }),
      !processed.contains(event.id), event.hasValidIDAndSignature()
    else { return nil }

    // Only classify the envelope here. Do not decode/extract the payload field before dual consent.
    struct Header: Decodable {
      let type: String
      let transcriptHash: String?
      enum CodingKeys: String, CodingKey {
        case type
        case transcriptHash = "transcript_hash"
      }
    }
    var plaintext: Data
    let header: Header
    do {
      plaintext = try NIP44.decryptData(event.content, key: context.secrets.conversationKey)
    } catch { return nil }  // NIP-AB explicitly requires silently discarding invalid input.
    defer { plaintext.resetBytes(in: 0..<plaintext.count) }
    do { header = try JSONDecoder().decode(Header.self, from: plaintext) } catch { return nil }
    if header.type == "abort" {
      finish()
      throw PairingError.ended
    }
    switch (phase, header.type) {
    case (.confirming, "sas-confirm"):
      guard let hash = header.transcriptHash, hash.utf8.count == 64,
        let received = Hex.decode(hash)
      else { return nil }
      // SymmetricKey equality uses a constant-time comparison of key bytes.
      guard SymmetricKey(data: received) == SymmetricKey(data: context.secrets.transcriptHash)
      else {
        // The transport sends sas_mismatch using abort() before discarding context.
        buffered = nil
        phase = .finished
        throw PairingError.transcriptMismatch
      }
      processed.insert(event.id)
      transcriptVerified = true
      phase = userConfirmed ? .transferring : .awaitingConfirmation
    case (.awaitingConfirmation, "payload"):
      if buffered == nil { buffered = event }  // Keep at most one ciphertext; no secret extraction.
    case (.transferring, "payload"):
      let imported = try PairingImport(plaintext: plaintext)
      processed.insert(event.id)
      phase = .importing
      return imported
    default: break
    }
    return nil
  }

  /// Sends success only after the caller has validated relay access and durably stored credentials.
  public mutating func complete() throws -> Event {
    let context = try active()
    guard phase == .importing else { throw PairingError.invalidPayload }
    let event = try message(["type": "complete", "success": true], context: context)
    finish()
    return event
  }

  /// Terminates a session and constructs a best-effort peer notification without retaining secrets.
  public mutating func abort(mismatch: Bool = false) throws -> Event? {
    defer { finish() }
    guard let context else { return nil }
    return try message(
      [
        "type": "abort", "reason": mismatch ? "sas_mismatch" : "user_denied",
      ], context: context)
  }

  /// Discards buffered messages and session secrets on cancellation, timeout or transport failure.
  public mutating func finish() {
    phase = .finished
    context = nil
    buffered = nil
    processed.removeAll()
  }

  private mutating func active() throws -> Context {
    _ = try active(now: .now)
    guard let context else { throw PairingError.ended }
    return context
  }

  mutating func active(now: ContinuousClock.Instant) throws -> Bool {
    guard now < deadline else {
      finish()
      throw PairingError.expired
    }
    guard context != nil, phase != .finished else { throw PairingError.ended }
    return true
  }

  private func message(_ body: [String: Any], context: Context) throws -> Event {
    let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    let encrypted = try NIP44.encrypt(
      String(decoding: data, as: UTF8.self), key: context.secrets.conversationKey)
    return try context.target.sign(
      kind: 24134, content: encrypted, tags: [["p", context.invitation.sourcePubkey]],
      at: Int(Date().timeIntervalSince1970) - Int.random(in: 0...30))
  }
}
