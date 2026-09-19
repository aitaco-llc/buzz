import AVFoundation
import BuzzCore
import Foundation
import Observation

/// Native client for the relay's dedicated Huddle WebSocket.
///
/// Nostr traffic and Huddle media intentionally use different sockets: the
/// former carries JSON arrays while this socket carries JSON control frames
/// and binary Opus v2 packets. The audio engine stays on the native side of
/// this boundary, so realtime PCM never crosses into SwiftUI.
@MainActor @Observable
final class NativeHuddleTransport {
  enum Phase: Equatable {
    case idle, connecting, authenticating, connected, closing, disconnected, failed
  }

  private struct AuthEnvelope: Encodable {
    let type: String
    let event: Event
    let parentChannelID: String
    let protocolVersion: Int

    enum CodingKeys: String, CodingKey {
      case type, event
      case parentChannelID = "parent_channel_id"
      case protocolVersion = "protocol_version"
    }
  }

  let workspace: Workspace
  let session: HuddleSessionInfo
  private(set) var phase: Phase = .idle
  private(set) var localPeerIndex: Int?
  private(set) var peers: [Int: String] = [:]
  private(set) var error: String?

  private var socket: URLSessionWebSocketTask?
  private var urlSession: URLSession?
  private var admission: CheckedContinuation<Void, Error>?
  private var engine: HuddleAudioEngine?
  private var receiveTask: Task<Void, Never>?
  private var sequence = 0

  init(workspace: Workspace, session: HuddleSessionInfo) {
    self.workspace = workspace
    self.session = session
  }

  func connectAndStartAudio() async throws {
    guard phase == .idle || phase == .disconnected || phase == .failed else { return }
    phase = .connecting
    error = nil
    let socketURL = try audioURL()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 10
    configuration.timeoutIntervalForResource = 20
    let session = URLSession(configuration: configuration)
    urlSession = session
    let task = session.webSocketTask(with: socketURL)
    socket = task
    task.resume()
    receiveTask = Task { [weak self] in await self?.receiveLoop() }

    do {
      let timeout = Task { @MainActor [weak self] in
        do { try await Task.sleep(for: .seconds(8)) } catch { return }
        self?.fail("Timed out waiting for Huddle room admission.")
      }
      defer { timeout.cancel() }
      try await withCheckedThrowingContinuation { continuation in
        admission = continuation
      }
      try configureAudioSession()
      let audio = try HuddleAudioEngine(
        onLocalPacket: { [weak self] packet in
          Task { @MainActor [weak self] in self?.send(packet: packet) }
        },
        onFailure: { [weak self] code, message in
          Task { @MainActor [weak self] in
            self?.fail("Audio (code): (message)")
          }
        },
        onDiagnostics: { _ in },
        diagnosticsEnabled: false
      )
      engine = audio
      try audio.start()
    } catch {
      fail(error.localizedDescription)
      await disconnect()
      throw error
    }
  }

  func disconnect() async {
    guard phase != .idle && phase != .disconnected else { return }
    phase = .closing
    if let admission, !admissionIsResolved {
      admission.resume(throwing: CancellationError())
      self.admission = nil
    }
    receiveTask?.cancel()
    receiveTask = nil
    engine?.stop()
    engine = nil
    socket?.cancel(with: .normalClosure, reason: nil)
    socket = nil
    urlSession?.invalidateAndCancel()
    urlSession = nil
    peers.removeAll()
    localPeerIndex = nil
    phase = .disconnected
  }

  func setMuted(_ muted: Bool) throws { try engine?.setMuted(muted) }

  private var admissionIsResolved: Bool { admission == nil }

  private func audioURL() throws -> URL {
    var components = URLComponents(
      url: workspace.account.community.origin, resolvingAgainstBaseURL: false)
    guard let scheme = components?.scheme else { throw BuzzError.invalidRelay }
    components?.scheme = scheme == "https" ? "wss" : "ws"
    components?.path = "/huddle/\(session.ephemeralChannelID)/audio"
    components?.query = nil
    components?.fragment = nil
    guard let url = components?.url else { throw BuzzError.invalidRelay }
    return url
  }

  private func configureAudioSession() throws {
    let audio = AVAudioSession.sharedInstance()
    try audio.setCategory(
      .playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
    try audio.setActive(true, options: [])
  }

  private func receiveLoop() async {
    guard let socket else { return }
    do {
      while !Task.isCancelled {
        let message = try await socket.receive()
        switch message {
        case .string(let value): handleControl(value)
        case .data(let data): handleAudio(data)
        @unknown default: throw BuzzError.invalidResponse
        }
      }
    } catch {
      guard !Task.isCancelled, phase != .closing, phase != .disconnected else { return }
      fail(error.localizedDescription)
      if let admission, !admissionIsResolved {
        admission.resume(throwing: error)
        self.admission = nil
      }
    }
  }

  private func handleControl(_ text: String) {
    guard let data = text.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let type = object["type"] as? String
    else {
      fail("Malformed Huddle control message.")
      return
    }

    switch type {
    case "challenge":
      guard phase == .connecting, let challenge = object["challenge"] as? String, !challenge.isEmpty
      else {
        fail("Unexpected Huddle challenge.")
        return
      }
      do {
        let event = try workspace.identity.sign(
          kind: 22242, content: "",
          tags: [
            ["relay", workspace.account.community.origin.absoluteString], ["challenge", challenge],
          ])
        let envelope = AuthEnvelope(
          type: "auth", event: event, parentChannelID: session.parentChannelID, protocolVersion: 2)
        let encoded = try JSONEncoder().encode(envelope)
        socket?.send(.string(String(decoding: encoded, as: UTF8.self))) { [weak self] error in
          if let error { Task { @MainActor [weak self] in self?.fail(error.localizedDescription) } }
        }
        phase = .authenticating
      } catch { fail("Unable to sign Huddle authentication.") }
    case "joined":
      guard let peer = object["peer_index"] as? Int, (0...255).contains(peer),
        let pubkey = object["pubkey"] as? String, !pubkey.isEmpty
      else {
        fail("Malformed Huddle admission.")
        return
      }
      localPeerIndex = peer
      peers[peer] = pubkey
      if let roster = object["peers"] as? [[String: Any]] { merge(roster) }
      phase = .connected
      if let admission, !admissionIsResolved {
        admission.resume()
        self.admission = nil
      }
    case "roster":
      if let roster = object["peers"] as? [[String: Any]] { merge(roster) }
    case "left":
      if let peer = object["peer_index"] as? Int {
        peers.removeValue(forKey: peer)
        engine?.removeRemotePeer(peer)
      }
    case "error":
      fail((object["message"] as? String) ?? "The Huddle relay rejected admission.")
    default:
      fail("Unknown Huddle control message.")
    }
  }

  private func merge(_ roster: [[String: Any]]) {
    for entry in roster {
      guard let peer = entry["peer_index"] as? Int, (0...255).contains(peer),
        let pubkey = entry["pubkey"] as? String
      else { continue }
      peers[peer] = pubkey
    }
  }

  private func handleAudio(_ data: Data) {
    guard data.count >= 10 else { return }
    let bytes = [UInt8](data)
    let peer = Int(bytes[0])
    let sequence = Int(bytes[1]) << 8 | Int(bytes[2])
    let timestamp =
      Int64(bytes[3]) << 24 | Int64(bytes[4]) << 16 | Int64(bytes[5]) << 8 | Int64(bytes[6])
    let level = Int(Int8(bitPattern: bytes[7]))
    let flags = Int(bytes[8])
    let opus = Data(bytes.dropFirst(9))
    guard !opus.isEmpty else { return }
    let packet = HuddleRemoteOpusPacket(
      peerIndex: peer, sequence: sequence, timestamp48k: timestamp,
      levelDbov: level, opus: opus)
    try? engine?.enqueueRemote(packet)
    _ = flags
  }

  private func send(packet: HuddleLocalOpusPacket) {
    guard phase == .connected else { return }
    var bytes = Data(capacity: 8 + packet.opus.count)
    bytes.append(UInt8((packet.sequence >> 8) & 0xff))
    bytes.append(UInt8(packet.sequence & 0xff))
    let timestamp = UInt32(truncatingIfNeeded: packet.timestamp48k)
    bytes.append(UInt8((timestamp >> 24) & 0xff))
    bytes.append(UInt8((timestamp >> 16) & 0xff))
    bytes.append(UInt8((timestamp >> 8) & 0xff))
    bytes.append(UInt8(timestamp & 0xff))
    bytes.append(UInt8(bitPattern: Int8(clamping: packet.levelDbov)))
    bytes.append(UInt8(packet.flags & 0xff))
    bytes.append(packet.opus)
    socket?.send(.data(bytes)) { [weak self] error in
      if let error { Task { @MainActor [weak self] in self?.fail(error.localizedDescription) } }
    }
    sequence = (sequence + 1) & 0xffff
  }

  private func fail(_ message: String) {
    error = message
    phase = .failed
    if let admission, !admissionIsResolved {
      admission.resume(throwing: BuzzError.rejected(message))
      self.admission = nil
    }
  }
}
