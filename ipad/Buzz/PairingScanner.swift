import AVFoundation
import BuzzCore
import Observation

enum PairingCameraPermission: Sendable {
  case unknown, authorized, denied, restricted
}

@MainActor protocol PairingCameraPermissionProvider {
  var status: PairingCameraPermission { get }
  func isCameraAvailable() async -> Bool
  func request() async -> Bool
}

struct SystemPairingCameraPermission: PairingCameraPermissionProvider {
  var status: PairingCameraPermission {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .notDetermined: .unknown
    case .authorized: .authorized
    case .denied: .denied
    case .restricted: .restricted
    @unknown default: .restricted
    }
  }

  func request() async -> Bool { await AVCaptureDevice.requestAccess(for: .video) }

  func isCameraAvailable() async -> Bool {
    await Task.detached {
      AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil
    }.value
  }
}

@MainActor @Observable
final class PairingScanner {
  enum State: Equatable {
    case idle, requesting, scanning, denied, restricted, unavailable, paused, completed
  }
  private(set) var state: State = .idle
  private(set) var message: String?
  private(set) var result: String?
  private(set) var preview: PairingCameraPreviewSource?
  private let permission: any PairingCameraPermissionProvider
  private let makeCamera: @Sendable () -> any PairingCameraSource
  private let parse: @Sendable ([String]) async -> String?
  private var camera: (any PairingCameraSource)?
  private var work: Task<Void, Never>?
  private var generation = UUID()

  init(
    permission: any PairingCameraPermissionProvider = SystemPairingCameraPermission(),
    makeCamera: @escaping @Sendable () -> any PairingCameraSource = { PairingCamera() },
    parse: @escaping @Sendable ([String]) async -> String? = PairingScanner.parseCodes
  ) {
    self.permission = permission
    self.makeCamera = makeCamera
    self.parse = parse
  }

  func resume() {
    guard state != .requesting, state != .scanning, state != .completed else { return }
    cancel()
    let token = UUID()
    generation = token
    state = .requesting
    work = Task {
      let available = await permission.isCameraAvailable()
      guard generation == token, !Task.isCancelled else { return }
      guard available else {
        state = .unavailable
        message = "This device has no available camera. You can paste a pairing link instead."
        return
      }
      var status = permission.status
      if status == .unknown { status = await permission.request() ? .authorized : .denied }
      guard generation == token, !Task.isCancelled else { return }
      switch status {
      case .denied:
        state = .denied
        return
      case .restricted, .unknown:
        state = .restricted
        return
      case .authorized: break
      }
      let source = makeCamera()
      camera = source
      do {
        let events = try await source.start()
        guard generation == token, !Task.isCancelled else {
          await source.stop()
          return
        }
        preview = source.preview
        state = .scanning
        for await event in events {
          guard generation == token, !Task.isCancelled else { break }
          switch event {
          case .codes(let values):
            // Parsing includes curve-point validation and stays off the UI actor.
            let parsed = await parse(values)
            guard generation == token, !Task.isCancelled else { break }
            if let parsed {
              state = .completed
              await source.stop()
              guard generation == token, !Task.isCancelled else { return }
              preview = nil
              camera = nil
              result = parsed
              return
            }
            message =
              "This isn’t a supported aitaco pairing code. Scan a new code from your desktop app."
          case .interrupted, .failed:
            state = .unavailable
            message = "The camera stopped. Try again or paste a pairing link."
            await source.stop()
            if generation == token {
              preview = nil
              camera = nil
            }
            return
          }
        }
        if generation == token, !Task.isCancelled {
          state = .unavailable
          message = "The camera stopped. Try again or paste a pairing link."
        }
      } catch {
        if generation == token, !Task.isCancelled {
          state = .unavailable
          message = "Camera scanning is unavailable. You can paste a pairing link instead."
        }
      }
      await source.stop()
      if generation == token {
        preview = nil
        camera = nil
      }
    }
  }

  @discardableResult func pause() -> Task<Void, Never>? {
    let previous = cancel()
    state = .paused
    return previous
  }

  // Return the retired operation for callers that need to await complete teardown.
  @discardableResult func cancel() -> Task<Void, Never>? {
    generation = UUID()
    let previous = work
    work?.cancel()
    work = nil
    if let camera { Task { await camera.stop() } }
    camera = nil
    preview = nil
    result = nil
    message = nil
    state = .idle
    return previous
  }

  nonisolated private static func parseCodes(_ values: [String]) async -> String? {
    await Task.detached { () -> String? in
      for value in values.prefix(8) where value.utf8.count <= 2048 {
        if (try? PairingInvitation(uri: value)) != nil { return value }
      }
      return nil
    }.value
  }
}
