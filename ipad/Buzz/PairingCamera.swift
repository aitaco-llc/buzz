@preconcurrency import AVFoundation
import SwiftUI

enum PairingCameraEvent: Sendable {
  case codes([String])
  case interrupted
  case failed
}

protocol PairingCameraSource: Sendable {
  var preview: PairingCameraPreviewSource? { get }
  func start() async throws -> AsyncStream<PairingCameraEvent>
  func stop() async
}

enum PairingCameraError: Error { case unavailable }

// AVCaptureSession configuration and start/stop remain confined to this actor's
// serial executor. The preview source exposes only attachment to Apple's preview
// layer, following AVFoundation's AVCam source/target pattern.
actor PairingCamera: PairingCameraSource {
  private let queue = DispatchSerialQueue(label: "co.aitaco.buzz.pairing-camera")
  nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
  nonisolated let preview: PairingCameraPreviewSource?
  private let capture = AVCaptureSession()
  private let stream: AsyncStream<PairingCameraEvent>
  private let continuation: AsyncStream<PairingCameraEvent>.Continuation
  private var delegate: QRMetadataDelegate?
  private var observers: [NSObjectProtocol] = []
  private var stopped = false

  init() {
    preview = PairingCameraPreviewSource(session: capture)
    (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(4))
  }

  func start() throws -> AsyncStream<PairingCameraEvent> {
    guard !stopped, delegate == nil,
      AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
      let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    else { throw PairingCameraError.unavailable }
    do {
      try configure(device)
      let continuation = continuation
      for (name, event) in [
        (AVCaptureSession.wasInterruptedNotification, PairingCameraEvent.interrupted),
        (AVCaptureSession.runtimeErrorNotification, PairingCameraEvent.failed),
      ] {
        observers.append(
          NotificationCenter.default.addObserver(
            forName: name, object: capture, queue: nil
          ) { _ in continuation.yield(event) })
      }
      capture.startRunning()
      guard capture.isRunning else { throw PairingCameraError.unavailable }
      return stream
    } catch {
      stop()
      throw PairingCameraError.unavailable
    }
  }

  private func configure(_ device: AVCaptureDevice) throws {
    capture.beginConfiguration()
    defer { capture.commitConfiguration() }
    if capture.canSetSessionPreset(.high) { capture.sessionPreset = .high }
    let input = try AVCaptureDeviceInput(device: device)
    guard capture.canAddInput(input) else { throw PairingCameraError.unavailable }
    capture.addInput(input)
    let output = AVCaptureMetadataOutput()
    guard capture.canAddOutput(output) else { throw PairingCameraError.unavailable }
    capture.addOutput(output)
    guard output.availableMetadataObjectTypes.contains(.qr) else {
      throw PairingCameraError.unavailable
    }
    let delegate = QRMetadataDelegate(continuation: continuation)
    self.delegate = delegate
    output.setMetadataObjectsDelegate(delegate, queue: queue)
    output.metadataObjectTypes = [.qr]
  }

  func stop() {
    stopped = true
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers.removeAll()
    if capture.isRunning { capture.stopRunning() }
    for output in capture.outputs {
      (output as? AVCaptureMetadataOutput)?.setMetadataObjectsDelegate(nil, queue: nil)
    }
    delegate = nil
    continuation.finish()
  }
}

private final class QRMetadataDelegate: NSObject, AVCaptureMetadataOutputObjectsDelegate {
  private let continuation: AsyncStream<PairingCameraEvent>.Continuation

  init(continuation: AsyncStream<PairingCameraEvent>.Continuation) {
    self.continuation = continuation
  }

  func metadataOutput(
    _ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
    from connection: AVCaptureConnection
  ) {
    let codes = metadataObjects.prefix(8).compactMap { object -> String? in
      guard let code = object as? AVMetadataMachineReadableCodeObject, code.type == .qr,
        let value = code.stringValue, value.utf8.count <= 2048
      else { return nil }
      return value
    }
    if !codes.isEmpty { continuation.yield(.codes(codes)) }
  }
}

struct PairingCameraPreviewSource: Sendable {
  private let session: AVCaptureSession

  init(session: AVCaptureSession) { self.session = session }

  @MainActor func attach(to layer: AVCaptureVideoPreviewLayer) -> AVCaptureDevice
    .RotationCoordinator?
  {
    layer.session = session
    // Inputs are fixed before this source is exposed to the UI. Use the actual
    // capture device so Apple's coordinator accounts for each iPad's sensor orientation.
    guard let input = session.inputs.first as? AVCaptureDeviceInput else { return nil }
    return AVCaptureDevice.RotationCoordinator(device: input.device, previewLayer: layer)
  }
}

struct PairingCameraPreview: UIViewRepresentable {
  let source: PairingCameraPreviewSource

  func makeUIView(context: Context) -> PreviewView {
    let view = PreviewView()
    view.attach(source)
    return view
  }

  func updateUIView(_ view: PreviewView, context: Context) { view.setNeedsLayout() }

  static func dismantleUIView(_ view: PreviewView, coordinator: ()) {
    view.detach()
  }

  final class PreviewView: UIView {
    let cameraLayer = AVCaptureVideoPreviewLayer()
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?

    init() {
      super.init(frame: .zero)
      backgroundColor = .black
      cameraLayer.videoGravity = .resizeAspectFill
      layer.addSublayer(cameraLayer)
      isAccessibilityElement = false
      accessibilityElementsHidden = true
    }

    required init?(coder: NSCoder) { nil }

    func attach(_ source: PairingCameraPreviewSource) {
      rotation = source.attach(to: cameraLayer)
      rotationObservation = rotation?.observe(
        \.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]
      ) { [weak self] _, change in
        guard let angle = change.newValue else { return }
        Task { @MainActor [weak self] in
          guard let self, rotation != nil, let connection = cameraLayer.connection,
            connection.isVideoRotationAngleSupported(angle)
          else { return }
          connection.videoRotationAngle = angle
        }
      }
    }

    func detach() {
      rotationObservation?.invalidate()
      rotationObservation = nil
      rotation = nil
      cameraLayer.session = nil
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      cameraLayer.frame = bounds
    }
  }
}
