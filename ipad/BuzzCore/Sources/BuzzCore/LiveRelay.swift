import Foundation

/// A community-bound source of history and live events for a persistent subscription.
public protocol LiveEventTransport: Sendable {
  /// Delivers events until the subscription ends, fails, or its consumer cancels.
  func events(filter: EventFilter) -> AsyncThrowingStream<Event, any Error>
  /// Publishes an ephemeral event over an authenticated NIP-42 socket.
  func publishEphemeral(_ event: Event) async throws
}

extension LiveEventTransport {
  public func publishEphemeral(_ event: Event) async throws {
    throw BuzzError.invalidResponse
  }
}

/// NIP-42 authenticated history-plus-live subscriptions, with bounded buffers and lifetimes.
public struct LiveRelay: LiveEventTransport {
  private let community: Community
  private let identity: Identity

  /// Binds one community origin and identity for the lifetime of each subscription.
  public init(community: Community, identity: Identity) {
    self.community = community
    self.identity = identity
  }

  /// Keeps the REQ open after EOSE, so history and realtime delivery have no handoff gap.
  public func events(filter: EventFilter) -> AsyncThrowingStream<Event, any Error> {
    AsyncThrowingStream(bufferingPolicy: .bufferingOldest(512)) { continuation in
      let task = Task {
        do {
          try await receive(filter: filter, continuation: continuation)
          continuation.finish()
        } catch { continuation.finish(throwing: error) }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  public func publishEphemeral(_ event: Event) async throws {
    guard var components = URLComponents(url: community.origin, resolvingAgainstBaseURL: false)
    else { throw BuzzError.invalidRelay }
    components.scheme = components.scheme == "https" ? "wss" : "ws"
    guard let url = components.url else { throw BuzzError.invalidRelay }
    let session = URLSession(configuration: .ephemeral)
    let socket = session.webSocketTask(with: url)
    socket.maximumMessageSize = 1024 * 1024
    socket.resume()
    defer {
      socket.cancel(with: .goingAway, reason: nil)
      session.invalidateAndCancel()
    }
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        try await Task.sleep(for: .seconds(15))
        socket.cancel(with: .goingAway, reason: nil)
        throw BuzzError.http(408)
      }
      defer { group.cancelAll() }
      var authenticated = false
      while !Task.isCancelled {
        let frame = try await socket.receive()
        let data: Data
        switch frame {
        case .data(let bytes): data = bytes
        case .string(let text): data = Data(text.utf8)
        @unknown default: throw BuzzError.invalidResponse
        }
        guard let values = try JSONSerialization.jsonObject(with: data) as? [Any],
          let type = values.first as? String
        else { throw BuzzError.invalidResponse }
        switch type {
        case "AUTH":
          guard values.count == 2, let challenge = values[1] as? String else {
            throw BuzzError.invalidResponse
          }
          let auth = try identity.sign(
            kind: 22242, content: "",
            tags: [["relay", url.absoluteString], ["challenge", challenge]])
          try await send(
            ["AUTH", try JSONSerialization.jsonObject(with: JSONEncoder().encode(auth))],
            socket: socket)
        case "OK":
          guard values.count >= 3, let id = values[1] as? String, let accepted = values[2] as? Bool
          else { continue }
          if !authenticated {
            guard accepted else { throw BuzzError.rejected("Authentication failed") }
            authenticated = true
            try await send(
              ["EVENT", try JSONSerialization.jsonObject(with: JSONEncoder().encode(event))],
              socket: socket)
          } else if id == event.id {
            guard accepted else {
              throw BuzzError.rejected(
                values.count > 3 ? String(describing: values[3]) : "Event rejected")
            }
            return
          }
        case "NOTICE":
          continue
        default:
          continue
        }
      }
      throw BuzzError.http(408)
    }
  }

  private func receive(
    filter: EventFilter,
    continuation: AsyncThrowingStream<Event, any Error>.Continuation
  ) async throws {
    guard var components = URLComponents(url: community.origin, resolvingAgainstBaseURL: false)
    else {
      throw BuzzError.invalidRelay
    }
    components.scheme = components.scheme == "https" ? "wss" : "ws"
    guard let url = components.url else { throw BuzzError.invalidRelay }
    let session = URLSession(configuration: .ephemeral)
    let socket = session.webSocketTask(with: url)
    socket.maximumMessageSize = 1024 * 1024
    socket.resume()
    let deadline = Task {
      try await Task.sleep(for: .seconds(10))
      socket.cancel(with: .policyViolation, reason: nil)
    }
    let heartbeat = Task {
      while !Task.isCancelled {
        try await Task.sleep(for: .seconds(20))
        let pingDeadline = Task {
          try await Task.sleep(for: .seconds(10))
          socket.cancel(with: .goingAway, reason: nil)
        }
        defer { pingDeadline.cancel() }
        do {
          try await withCheckedThrowingContinuation {
            (result: CheckedContinuation<Void, any Error>) in
            socket.sendPing { error in
              if let error { result.resume(throwing: error) } else { result.resume() }
            }
          }
        } catch {
          socket.cancel(with: .goingAway, reason: nil)
          throw error
        }
      }
    }
    defer {
      deadline.cancel()
      heartbeat.cancel()
      socket.cancel(with: .goingAway, reason: nil)
      session.invalidateAndCancel()
    }
    try await withTaskCancellationHandler {
      var authID: String?
      var authenticated = false
      let subscription = UUID().uuidString
      while !Task.isCancelled {
        let frame = try await socket.receive()
        let data: Data
        switch frame {
        case .data(let bytes): data = bytes
        case .string(let text): data = Data(text.utf8)
        @unknown default: throw BuzzError.invalidResponse
        }
        guard let values = try JSONSerialization.jsonObject(with: data) as? [Any],
          let type = values.first as? String
        else { throw BuzzError.invalidResponse }
        switch type {
        case "AUTH":
          guard !authenticated, authID == nil, values.count == 2,
            let challenge = values[1] as? String
          else { throw BuzzError.invalidResponse }
          let auth = try identity.sign(
            kind: 22242, content: "",
            tags: [["relay", url.absoluteString], ["challenge", challenge]])
          authID = auth.id
          let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(auth))
          try await send(["AUTH", object], socket: socket)
        case "OK":
          guard !authenticated, values.count >= 3,
            let receivedID = values[1] as? String, let pendingID = authID,
            receivedID == pendingID
          else { continue }
          guard values[2] as? Bool == true else {
            throw BuzzError.rejected("Authentication failed")
          }
          authenticated = true
          authID = nil
          deadline.cancel()
          let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(filter))
          try await send(["REQ", subscription, object], socket: socket)
        case "EVENT":
          guard authenticated, values.count == 3, values[1] as? String == subscription else {
            throw BuzzError.invalidResponse
          }
          let event = try JSONDecoder().decode(
            Event.self, from: JSONSerialization.data(withJSONObject: values[2]))
          switch continuation.yield(event) {
          case .enqueued: break
          case .dropped: throw BuzzError.responseTooLarge
          case .terminated: return
          @unknown default: throw BuzzError.invalidResponse
          }
        case "CLOSED":
          throw BuzzError.rejected(
            values.count > 2 ? String(describing: values[2]) : "Subscription closed")
        case "EOSE", "NOTICE": break
        default: break
        }
      }
    } onCancel: {
      socket.cancel(with: .goingAway, reason: nil)
    }
  }

  private func send(_ frame: [Any], socket: URLSessionWebSocketTask) async throws {
    let data = try JSONSerialization.data(withJSONObject: frame, options: [.withoutEscapingSlashes])
    try await socket.send(.string(String(decoding: data, as: UTF8.self)))
  }
}
