import Foundation

/// Bounded NIP-AB WebSocket exchange supporting open and NIP-42-authenticated relays.
public actor PairingSession {
  /// State changes emitted to the native pairing screen.
  public enum Update: Sendable {
    case compareCode(String)
    case waitingForPeer
    case credentials(PairingImport)
  }

  private var receiver: PairingReceiver
  private let relay: URL
  private let session: URLSession
  private let socket: URLSessionWebSocketTask
  private let subscription = UUID().uuidString
  private let stream: AsyncThrowingStream<Update, any Error>
  private let continuation: AsyncThrowingStream<Update, any Error>.Continuation
  private var reader: Task<Void, Never>?
  private var timeout: Task<Void, Never>?
  private var authTimer: Task<Void, Never>?
  private var authID: String?
  private var authCount = 0
  private var offer: Event?
  private var started = false
  private var exchangeStarted = false
  private var closed = false
  private var closing = false

  /// Uses a QR-advertised relay. Each retry must create a new session and ephemeral identity.
  public init(invitation: PairingInvitation, relayIndex: Int = 0) throws {
    guard invitation.relays.indices.contains(relayIndex) else {
      throw PairingError.invalidInvitation
    }
    receiver = try PairingReceiver(invitation: invitation)
    relay = invitation.relays[relayIndex]
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 10
    session = URLSession(configuration: configuration)
    socket = session.webSocketTask(with: relay)
    socket.maximumMessageSize = 100_000
    (stream, continuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(8))
  }

  /// Opens the transport once. The consumer must cancel the session when leaving its screen.
  public func start() throws -> AsyncThrowingStream<Update, any Error> {
    guard !started, !closed else { throw PairingError.ended }
    started = true
    continuation.onTermination = { [weak self] _ in
      Task { await self?.close(error: nil) }
    }
    socket.resume()
    timeout = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(120)) } catch { return }
      await self?.close(error: PairingError.expired)
    }
    // An open relay does not send AUTH. Give a challenged relay time to do so.
    authTimer = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(3)) } catch { return }
      await self?.openRelayReady()
    }
    reader = Task { [weak self] in await self?.read() }
    return stream
  }

  /// Called only by an explicit local "Codes match" action.
  public func confirm() throws {
    guard !closed, !closing else { throw PairingError.ended }
    if let imported = try receiver.confirm() {
      try emit(.credentials(imported))
    } else {
      try emit(.waitingForPeer)
    }
  }

  /// Called after relay validation and successful durable Keychain/account storage.
  public func complete() async throws {
    guard !closed, !closing else { throw PairingError.ended }
    let event = try receiver.complete()
    closing = true
    defer { close(error: nil) }
    try await sendEvent(event)
  }

  /// Fences a slow community check before the UI commits any transferred credentials.
  public func validateImport() throws {
    guard !closed, !closing, receiver.phase == .importing else { throw PairingError.ended }
    _ = try receiver.active(now: .now)
  }

  /// Cancels immediately at the protocol layer, with at most one second for a peer abort notice.
  public func cancel() async {
    await abort(mismatch: false, error: nil)
  }

  private func openRelayReady() async {
    guard !closed, !closing, authCount == 0 else { return }
    do { try await beginExchange() } catch { close(error: error) }
  }

  private func beginExchange() async throws {
    guard !closed, !closing else { throw PairingError.ended }
    let first = !exchangeStarted
    exchangeStarted = true
    if offer == nil { offer = try receiver.offer() }
    try await send([
      "REQ", subscription, ["kinds": [24134], "#p": [receiver.pubkey]],
    ])
    guard !closed, !closing, let offer else { throw PairingError.ended }
    try await sendEvent(offer)
    if first { try emit(.compareCode(receiver.code)) }
  }

  private func read() async {
    do {
      // A QR pairing is short-lived. A flooding peer must not create unbounded work.
      for _ in 0..<1024 {
        guard !closed, !closing else { return }
        let frame = try await socket.receive()
        guard !closed, !closing else { return }
        let data: Data
        switch frame {
        case .data(let value): data = value
        case .string(let value): data = Data(value.utf8)
        @unknown default: throw BuzzError.invalidResponse
        }
        guard let values = try JSONSerialization.jsonObject(with: data) as? [Any],
          let type = values.first as? String
        else { continue }
        switch type {
        case "AUTH":
          guard values.count == 2, let challenge = values[1] as? String, authCount < 2 else {
            throw BuzzError.rejected("Pairing relay authentication failed")
          }
          authCount += 1
          authTimer?.cancel()
          let event = try receiver.authenticate(challenge: challenge, relay: relay)
          authID = event.id
          authTimer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            await self?.close(error: BuzzError.rejected("Pairing relay authentication timed out"))
          }
          try await send(["AUTH", JSONSerialization.jsonObject(with: JSONEncoder().encode(event))])
        case "OK":
          guard values.count >= 3, let id = values[1] as? String else { continue }
          if id == authID {
            guard values[2] as? Bool == true else {
              throw BuzzError.rejected("Pairing relay authentication failed")
            }
            authID = nil
            authTimer?.cancel()
            try await beginExchange()
          } else if id == offer?.id, values[2] as? Bool != true {
            throw BuzzError.rejected("Pairing relay did not accept the offer")
          }
        case "EVENT":
          guard exchangeStarted, authID == nil, values.count == 3,
            values[1] as? String == subscription
          else { continue }
          // Invalid event envelopes are protocol noise, never user operations.
          guard let eventData = try? JSONSerialization.data(withJSONObject: values[2]),
            let event = try? JSONDecoder().decode(Event.self, from: eventData)
          else { continue }
          if let imported = try receiver.receive(event) { try emit(.credentials(imported)) }
        case "CLOSED":
          if values.count > 1, values[1] as? String == subscription {
            throw BuzzError.rejected("Pairing relay closed the subscription")
          }
        default: break
        }
      }
      throw BuzzError.responseTooLarge
    } catch PairingError.transcriptMismatch {
      await abort(mismatch: true, error: PairingError.transcriptMismatch)
    } catch { close(error: error) }
  }

  private func abort(mismatch: Bool, error: (any Error)?) async {
    guard !closed, !closing else { return }
    closing = true
    // Prevent a peer packet from being processed while abort delivery awaits the socket.
    let deadline = Task { [socket] in
      do { try await Task.sleep(for: .seconds(1)) } catch { return }
      socket.cancel(with: .goingAway, reason: nil)
    }
    defer {
      deadline.cancel()
      close(error: error)
    }
    do {
      if let event = try receiver.abort(mismatch: mismatch) { try await sendEvent(event) }
    } catch {
      // Abort delivery is advisory. Local termination is unconditional and already fenced.
    }
  }

  private func emit(_ update: Update) throws {
    switch continuation.yield(update) {
    case .enqueued: break
    case .dropped: throw BuzzError.responseTooLarge
    case .terminated: throw CancellationError()
    @unknown default: throw BuzzError.invalidResponse
    }
  }

  private func sendEvent(_ event: Event) async throws {
    try await send(["EVENT", JSONSerialization.jsonObject(with: JSONEncoder().encode(event))])
  }

  private func send(_ frame: [Any]) async throws {
    let data = try JSONSerialization.data(withJSONObject: frame, options: [.withoutEscapingSlashes])
    try await socket.send(.string(String(decoding: data, as: UTF8.self)))
  }

  private func close(error: (any Error)?) {
    guard !closed else { return }
    closed = true
    receiver.finish()
    reader?.cancel()
    timeout?.cancel()
    authTimer?.cancel()
    socket.cancel(with: .goingAway, reason: nil)
    session.invalidateAndCancel()
    if let error { continuation.finish(throwing: error) } else { continuation.finish() }
  }
}
