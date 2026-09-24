import BuzzCore
import XCTest

@testable import Buzz

final class PairingScannerTests: XCTestCase {
  @MainActor func testPermissionAndUnavailableCameraKeepRecoveryAvailable() async throws {
    for (permissionState, expected) in [
      (PairingCameraPermission.denied, PairingScanner.State.denied),
      (.restricted, .restricted),
    ] {
      let permission = FakeCameraPermission(status: permissionState)
      let camera = FakePairingCamera()
      let scanner = PairingScanner(permission: permission, makeCamera: { camera })
      scanner.resume()
      try await eventually { scanner.state == expected }
      let starts = await camera.starts
      XCTAssertEqual(starts, 0)
      XCTAssertEqual(permission.requests, 0)
      scanner.cancel()
    }
    let permission = FakeCameraPermission(status: .unknown, available: false)
    let camera = FakePairingCamera()
    let scanner = PairingScanner(permission: permission, makeCamera: { camera })
    scanner.resume()
    try await eventually { scanner.state == .unavailable }
    XCTAssertEqual(permission.requests, 0)
    XCTAssertNotNil(scanner.message)
    scanner.cancel()
  }

  @MainActor func testAuthorizationResponseAfterCancellationCannotStartCamera() async throws {
    let permission = FakeCameraPermission(status: .unknown)
    let camera = FakePairingCamera()
    let scanner = PairingScanner(permission: permission, makeCamera: { camera })
    scanner.resume()
    try await eventually { permission.pending != nil }
    let retired = scanner.cancel()
    permission.answer(true)
    // The saved continuation resolves a real in-flight production permission request.
    try await eventually { permission.completed }
    await retired?.value
    XCTAssertEqual(scanner.state, .idle)
    XCTAssertNil(scanner.result)
    let starts = await camera.starts
    XCTAssertEqual(starts, 0)
  }

  @MainActor func testGrantedPermissionStartsCameraAndDenialDoesNot() async throws {
    for granted in [false, true] {
      let permission = FakeCameraPermission(status: .unknown)
      let camera = FakePairingCamera()
      let scanner = PairingScanner(permission: permission, makeCamera: { camera })
      scanner.resume()
      try await eventually { permission.pending != nil }
      permission.answer(granted)
      try await eventually { scanner.state == (granted ? .scanning : .denied) }
      let starts = await camera.starts
      XCTAssertEqual(starts, granted ? 1 : 0)
      scanner.cancel()
    }
  }

  @MainActor func testLateCameraStartIsStoppedAfterBackgrounding() async throws {
    let permission = FakeCameraPermission(status: .authorized)
    let camera = FakePairingCamera(holdStart: true)
    let scanner = PairingScanner(permission: permission, makeCamera: { camera })
    scanner.resume()
    try await eventually { await camera.startPending != nil }
    let retired = scanner.pause()
    await camera.releaseStart()
    await retired?.value
    try await eventually { await camera.stops > 0 }
    XCTAssertEqual(scanner.state, .paused)
    XCTAssertNil(scanner.preview)
    XCTAssertNil(scanner.result)
  }

  @MainActor func testInvalidCodeDoesNotCloseScannerAndValidCodeIsAcceptedOnce() async throws {
    let permission = FakeCameraPermission(status: .authorized)
    let camera = FakePairingCamera()
    let scanner = PairingScanner(permission: permission, makeCamera: { camera })
    scanner.resume()
    try await eventually { scanner.state == .scanning }
    await camera.send(.codes(["https://example.com", String(repeating: "x", count: 2049)]))
    try await eventually { scanner.message != nil }
    XCTAssertEqual(scanner.state, .scanning)
    XCTAssertNil(scanner.result)
    let valid = try invitation()
    await camera.send(.codes(["not a pairing code", valid, valid]))
    try await eventually { scanner.result != nil }
    XCTAssertEqual(scanner.result, valid)
    XCTAssertEqual(scanner.state, .completed)
    let stops = await camera.stops
    XCTAssertEqual(stops, 1)
    await camera.send(.codes([valid]))
    scanner.resume()
    let starts = await camera.starts
    XCTAssertEqual(starts, 1)
    scanner.cancel()
    XCTAssertNil(scanner.result)
  }

  @MainActor func testValidationCompletionAfterCancelCannotDeliverPairingLink() async throws {
    let permission = FakeCameraPermission(status: .authorized)
    let camera = FakePairingCamera()
    let parser = SuspendedQRParser()
    let scanner = PairingScanner(
      permission: permission, makeCamera: { camera },
      parse: { values in
        await parser.parse(values)
      })
    scanner.resume()
    try await eventually { scanner.state == .scanning }
    let valid = try invitation()
    await camera.send(.codes([valid]))
    try await eventually { await parser.pending != nil }
    let retired = scanner.cancel()
    await parser.finish(valid)
    await retired?.value
    try await eventually { await camera.stops > 0 }
    XCTAssertNil(scanner.result)
    XCTAssertEqual(scanner.state, .idle)
  }

  @MainActor func testCameraInterruptionStopsCaptureAndAllowsPermissionRecheck() async throws {
    let permission = FakeCameraPermission(status: .authorized)
    let camera = FakePairingCamera()
    let scanner = PairingScanner(permission: permission, makeCamera: { camera })
    scanner.resume()
    try await eventually { scanner.state == .scanning }
    await camera.send(.interrupted)
    try await eventually { scanner.state == .unavailable }
    try await eventually { await camera.stops > 0 }
    permission.status = .denied
    scanner.resume()
    try await eventually { scanner.state == .denied }
    let starts = await camera.starts
    XCTAssertEqual(starts, 1)
    scanner.cancel()
  }

  @MainActor private func eventually(_ predicate: @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !(await predicate()) {
      guard ContinuousClock.now < deadline else {
        XCTFail("The scanner did not reach the expected state")
        throw PairingCameraError.unavailable
      }
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  private func invitation() throws -> String {
    let source = try Identity(hex: String(repeating: "0", count: 63) + "1")
    return
      "nostrpair://\(source.pubkey)?secret=\(String(repeating: "a", count: 64))&relay=wss://pair.example&v=1"
  }
}

@MainActor private final class FakeCameraPermission: PairingCameraPermissionProvider {
  var status: PairingCameraPermission
  let available: Bool
  var requests = 0
  var completed = false
  var pending: CheckedContinuation<Bool, Never>?

  init(status: PairingCameraPermission, available: Bool = true) {
    self.status = status
    self.available = available
  }

  func isCameraAvailable() async -> Bool { available }

  func request() async -> Bool {
    requests += 1
    let value = await withCheckedContinuation { pending = $0 }
    completed = true
    return value
  }

  func answer(_ granted: Bool) {
    pending?.resume(returning: granted)
    pending = nil
  }
}

private actor FakePairingCamera: PairingCameraSource {
  nonisolated let preview: PairingCameraPreviewSource? = nil
  var starts = 0
  var stops = 0
  var startPending: CheckedContinuation<Void, Never>?
  private let holdStart: Bool
  private let stream: AsyncStream<PairingCameraEvent>
  private let continuation: AsyncStream<PairingCameraEvent>.Continuation

  init(holdStart: Bool = false) {
    self.holdStart = holdStart
    (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(4))
  }

  func start() async -> AsyncStream<PairingCameraEvent> {
    starts += 1
    if holdStart { await withCheckedContinuation { startPending = $0 } }
    return stream
  }

  func releaseStart() {
    startPending?.resume()
    startPending = nil
  }
  func send(_ event: PairingCameraEvent) { continuation.yield(event) }

  func stop() {
    stops += 1
    continuation.finish()
  }
}

private actor SuspendedQRParser {
  var pending: CheckedContinuation<String?, Never>?
  func parse(_ values: [String]) async -> String? {
    await withCheckedContinuation { pending = $0 }
  }
  func finish(_ value: String) {
    pending?.resume(returning: value)
    pending = nil
  }
}
