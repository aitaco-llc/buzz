import SwiftUI

struct PairingScannerView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.openURL) private var openURL
  @State private var scanner = PairingScanner()
  let onScan: (String) -> Void

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 20) {
          Text("Point your iPad’s camera at the pairing QR code on your desktop app.")
            .font(.title3).multilineTextAlignment(.center)
          if let preview = scanner.preview {
            PairingCameraPreview(source: preview)
              .frame(minHeight: 240, idealHeight: 380, maxHeight: 480)
              .clipShape(RoundedRectangle(cornerRadius: 16))
              .accessibilityHidden(true)
            Text("Scanning for an aitaco pairing code…")
          } else {
            Image(systemName: "qrcode.viewfinder").font(.largeTitle)
              .accessibilityHidden(true)
            cameraState
          }
          if let message = scanner.message {
            Text(message).foregroundStyle(.secondary)
              .accessibilityIdentifier("camera-message")
          }
          Button("Paste a link instead") {
            scanner.cancel()
            dismiss()
          }
          .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
      }
      .navigationTitle("Scan pairing code")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            scanner.cancel()
            dismiss()
          }
        }
      }
    }
    .task { if scenePhase == .active { scanner.resume() } }
    .onChange(of: scenePhase) { _, phase in
      if phase == .background { scanner.pause() }
      if phase == .active { scanner.resume() }
    }
    .onChange(of: scanner.result) { _, value in
      if let value {
        onScan(value)
        dismiss()
      }
    }
    .onDisappear { scanner.cancel() }
  }

  @ViewBuilder private var cameraState: some View {
    switch scanner.state {
    case .idle, .requesting: ProgressView("Preparing camera…")
    case .denied:
      Text("Allow camera access in Settings to scan your desktop’s pairing code.")
      Button("Open Settings") {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
      }
    case .restricted:
      Text("Camera access is restricted on this iPad. You can paste a pairing link instead.")
    case .unavailable:
      Text("Camera unavailable").font(.headline)
      Button("Try camera again") { scanner.resume() }
    case .paused:
      Text("Camera paused")
      Button("Resume camera") { scanner.resume() }
    case .scanning: Text("Scanning for an aitaco pairing code…")
    case .completed: ProgressView("Opening pairing…")
    }
  }
}
