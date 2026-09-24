import CryptoKit
import Foundation
import Network
import Testing

@testable import BuzzCore

struct PairingSessionTests {
  @Test(.timeLimit(.minutes(1)), arguments: [false, true])
  func importsOverOpenAndAuthenticatedPairingRelays(authenticated: Bool) async throws {
    let source = try Identity(hex: String(repeating: "0", count: 63) + "2")
    let imported = try Identity(hex: String(repeating: "0", count: 63) + "3")
    let secret = Array(repeating: UInt8(7), count: 32)
    let options = NWProtocolWebSocket.Options()
    options.autoReplyPing = true
    let parameters = NWParameters.tcp
    parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
    let listener = try NWListener(using: parameters, on: .any)
    defer { listener.cancel() }
    let accepted = AsyncStream<NWConnection> { continuation in
      listener.newConnectionHandler = { connection in
        connection.start(queue: .global())
        continuation.yield(connection)
        continuation.finish()
      }
    }
    let port: NWEndpoint.Port = try await withCheckedThrowingContinuation { result in
      listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
          if let port = listener.port {
            result.resume(returning: port)
          } else {
            result.resume(throwing: BuzzError.invalidResponse)
          }
        case .failed(let error): result.resume(throwing: error)
        default: break
        }
      }
      listener.start(queue: .global())
    }
    listener.stateUpdateHandler = nil
    let relay = "ws://127.0.0.1:\(port.rawValue)"
    let invitation = try PairingInvitation(
      uri: "nostrpair://\(source.pubkey)?secret=\(Hex.encode(secret))&relay=\(relay)&v=1")
    let peerReady = AsyncStream<Void>.makeStream()
    let peer = Task {
      for await connection in accepted {
        let deadline = Task {
          try await Task.sleep(for: .seconds(15))
          connection.cancel()
        }
        defer {
          deadline.cancel()
          connection.cancel()
          peerReady.continuation.finish()
        }
        var authPubkey: String?
        if authenticated {
          try await LiveRelayTests.send(["AUTH", "pair-fixture"], connection)
          let authFrame = try await LiveRelayTests.receive(connection)
          #expect(authFrame[0] as? String == "AUTH")
          let auth = try Self.event(authFrame[1])
          #expect(auth.hasValidIDAndSignature())
          #expect(auth.kind == 22242)
          #expect(auth.tag("challenge") == "pair-fixture")
          #expect(auth.tag("relay") == relay)
          authPubkey = auth.pubkey
          try await LiveRelayTests.send(["OK", auth.id, true, ""], connection)
        }
        let req = try await LiveRelayTests.receive(connection)
        #expect(req[0] as? String == "REQ")
        let subscription = try #require(req[1] as? String)
        let filter = try #require(req[2] as? [String: Any])
        #expect(filter["kinds"] as? [Int] == [24134])
        let target = try #require((filter["#p"] as? [String])?.first)
        if authenticated { #expect(target == authPubkey) }
        #expect(target != imported.pubkey)
        let offerFrame = try await LiveRelayTests.receive(connection)
        #expect(offerFrame[0] as? String == "EVENT")
        let offer = try Self.event(offerFrame[1])
        #expect(offer.pubkey == target)
        #expect(offer.tag("p") == source.pubkey)
        #expect(offer.hasValidIDAndSignature())
        let key = try NIP44.conversationKey(identity: source, peer: target)
        let offerBody = try #require(
          JSONSerialization.jsonObject(
            with: Data(NIP44.decrypt(offer.content, key: key).utf8)) as? [String: Any])
        let sessionID = Self.derive(secret, salt: [], info: "nostr-pair-session-id")
        #expect(offerBody["session_id"] as? String == Hex.encode(sessionID))
        let sasInput = Self.derive(
          try source.sharedX(with: target), salt: secret, info: "nostr-pair-sas-v1")
        let sourceBytes = try #require(Hex.decode(source.pubkey))
        let targetBytes = try #require(Hex.decode(target))
        let transcript = Self.derive(
          sessionID + sourceBytes + targetBytes + sasInput,
          salt: secret, info: "nostr-pair-transcript-v1")
        func sendPeer(_ body: [String: Any]) async throws {
          let data = try JSONSerialization.data(withJSONObject: body)
          let event = try source.sign(
            kind: 24134,
            content: NIP44.encrypt(String(decoding: data, as: UTF8.self), key: key),
            tags: [["p", target]])
          try await LiveRelayTests.send(
            [
              "EVENT", subscription,
              JSONSerialization.jsonObject(with: JSONEncoder().encode(event)),
            ], connection)
        }
        try await sendPeer(["type": "sas-confirm", "transcript_hash": Hex.encode(transcript)])
        let payload = try JSONSerialization.data(withJSONObject: [
          "relayUrl": "wss://buzz.example", "pubkey": imported.pubkey, "nsec": imported.nsec(),
        ])
        try await sendPeer([
          "type": "payload", "payload_type": "custom",
          "payload": String(decoding: payload, as: UTF8.self),
        ])
        peerReady.continuation.yield(())
        let completed = try await LiveRelayTests.receive(connection)
        #expect(completed[0] as? String == "EVENT")
        let event = try Self.event(completed[1])
        #expect(event.hasValidIDAndSignature())
        let receipt = try #require(
          JSONSerialization.jsonObject(
            with: Data(NIP44.decrypt(event.content, key: key).utf8)) as? [String: Any])
        #expect(receipt["type"] as? String == "complete")
        #expect(receipt["success"] as? Bool == true)
        return
      }
      throw BuzzError.invalidResponse
    }
    let session = try PairingSession(invitation: invitation)
    var received = false
    do {
      for try await update in try await session.start() {
        switch update {
        case .compareCode(let code):
          #expect(code.count == 6)
          await #expect(throws: PairingError.ended) { try await session.validateImport() }
          for await _ in peerReady.stream { break }
          try await session.confirm()
        case .credentials(let payload):
          try await session.validateImport()
          #expect(payload.identity.pubkey == imported.pubkey)
          #expect(payload.community.id == "https://buzz.example")
          received = true
          try await session.complete()
        case .waitingForPeer: break
        }
      }
      try await peer.value
    } catch {
      await session.cancel()
      peer.cancel()
      throw error
    }
    #expect(received)
    await #expect(throws: PairingError.ended) { try await session.validateImport() }
  }

  private static func event(_ object: Any) throws -> Event {
    try JSONDecoder().decode(Event.self, from: JSONSerialization.data(withJSONObject: object))
  }

  private static func derive(_ data: [UInt8], salt: [UInt8], info: String) -> [UInt8] {
    HKDF<SHA256>.deriveKey(
      inputKeyMaterial: SymmetricKey(data: data), salt: salt,
      info: Array(info.utf8), outputByteCount: 32
    ).withUnsafeBytes { Array($0) }
  }
}
