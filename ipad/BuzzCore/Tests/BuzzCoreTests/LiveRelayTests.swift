import Foundation
import Network
import Testing

@testable import BuzzCore

struct LiveRelayTests {
  @Test(.timeLimit(.minutes(1)))
  func authenticatesAndReceivesHistoryThenLiveOnSameSubscription() async throws {
    let identity = try Identity(hex: String(repeating: "0", count: 63) + "1")
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
    let community = try Community(url: "http://127.0.0.1:\(port.rawValue)", name: "Fixture")
    let history = try identity.sign(kind: 9, content: "history", tags: [["h", "c"]], at: 1)
    let live = try identity.sign(kind: 9, content: "live", tags: [["h", "c"]], at: 2)
    let server = Task {
      for await connection in accepted {
        // Keep the peer alive until the client cancels its stream after both events.
        try await Self.send(["AUTH", "fixture-challenge"], connection)
        let authFrame = try await Self.receive(connection)
        #expect(authFrame[0] as? String == "AUTH")
        let auth = try JSONDecoder().decode(
          Event.self, from: JSONSerialization.data(withJSONObject: authFrame[1]))
        #expect(auth.hasValidIDAndSignature())
        #expect(auth.kind == 22242)
        #expect(auth.tag("challenge") == "fixture-challenge")
        #expect(auth.tag("relay") == "ws://127.0.0.1:\(port.rawValue)")
        try await Self.send(["OK", auth.id, true, ""], connection)
        let request = try await Self.receive(connection)
        #expect(request[0] as? String == "REQ")
        let subscription = try #require(request[1] as? String)
        let filter = try #require(request[2] as? [String: Any])
        #expect(filter["#h"] as? [String] == ["c"])
        #expect(filter["kinds"] as? [Int] == [9])
        try await Self.send(
          [
            "EVENT", subscription,
            JSONSerialization.jsonObject(with: JSONEncoder().encode(history)),
          ], connection)
        try await Self.send(["EOSE", subscription], connection)
        try await Self.send(
          ["EVENT", subscription, JSONSerialization.jsonObject(with: JSONEncoder().encode(live))],
          connection)
        return connection
      }
      throw BuzzError.invalidResponse
    }
    let client = LiveRelay(community: community, identity: identity)
    var received: [String] = []
    for try await event in client.events(filter: EventFilter(kinds: [9], tags: ["h": ["c"]])) {
      #expect(event.hasValidIDAndSignature())
      received.append(event.content)
      if received.count == 2 { break }
    }
    let connection = try await server.value
    connection.cancel()
    #expect(received == ["history", "live"])
  }

  static func send(_ value: [Any], _ connection: NWConnection) async throws {
    let data = try JSONSerialization.data(withJSONObject: value)
    let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
    let context = NWConnection.ContentContext(identifier: UUID().uuidString, metadata: [metadata])
    try await withCheckedThrowingContinuation { (result: CheckedContinuation<Void, any Error>) in
      connection.send(
        content: data, contentContext: context, isComplete: true,
        completion: .contentProcessed { error in
          if let error { result.resume(throwing: error) } else { result.resume() }
        })
    }
  }

  static func receive(_ connection: NWConnection) async throws -> [Any] {
    let data: Data = try await withCheckedThrowingContinuation { result in
      connection.receiveMessage { data, _, _, error in
        if let error {
          result.resume(throwing: error)
        } else if let data {
          result.resume(returning: data)
        } else {
          result.resume(throwing: BuzzError.invalidResponse)
        }
      }
    }
    return try #require(JSONSerialization.jsonObject(with: data) as? [Any])
  }
}
