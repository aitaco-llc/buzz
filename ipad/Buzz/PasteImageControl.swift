import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The system paste button, wired to hand image bytes back to the composer.
///
/// Tapping it is explicit user intent, so iOS releases the pasteboard without
/// the "Allow Paste?" alert that a direct read of `UIPasteboard.general.image`
/// puts up. The detection that decides whether to show it at all
/// (`UIPasteboard.general.hasImages`) is exempt from that alert too, so the
/// button can appear without costing the user a prompt.
struct PasteImageControl: UIViewRepresentable {
  /// Called on the main actor with the pasted bytes and the MIME type they
  /// actually are, which is not always what the pasteboard advertises.
  let onPaste: (Data, String) -> Void

  /// Preference order matches `AppDelegate.clipboardImageData`: original bytes
  /// where the pasteboard carries them, so nothing is re-encoded twice.
  static let readableTypes: [(type: UTType, mime: String)] = [
    (.png, "image/png"),
    (.jpeg, "image/jpeg"),
    (.gif, "image/gif"),
    (.webP, "image/webp"),
    (.heic, "image/heic"),
    (.heif, "image/heif"),
  ]

  func makeUIView(context: Context) -> PasteTargetView {
    let view = PasteTargetView()
    view.onPaste = onPaste
    let control = UIPasteControl(
      configuration: {
        let configuration = UIPasteControl.Configuration()
        configuration.displayMode = .iconOnly
        configuration.cornerStyle = .capsule
        // Left at its defaults the glyph inherits the app tint and disappears
        // into the teal composer chrome — the control renders as a blank block.
        // These match the bare paperclip and mic it sits between.
        configuration.baseBackgroundColor = .clear
        configuration.baseForegroundColor = .label
        return configuration
      }())
    control.target = view
    control.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(control)
    NSLayoutConstraint.activate([
      control.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      control.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      control.topAnchor.constraint(equalTo: view.topAnchor),
      control.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    view.accessibilityIdentifier = "paste-image"
    return view
  }

  func updateUIView(_ view: PasteTargetView, context: Context) {
    view.onPaste = onPaste
  }
}

/// `UIPasteControl` delivers through `paste(itemProviders:)` on its target
/// rather than through a closure, so the target has to be a responder.
/// `UIView` already conforms to `UIPasteConfigurationSupporting`.
final class PasteTargetView: UIView {
  var onPaste: ((Data, String) -> Void)?

  override func paste(itemProviders: [NSItemProvider]) {
    guard
      let match = PasteImageControl.readableTypes.lazy.compactMap({ candidate in
        itemProviders.first { $0.hasItemConformingToTypeIdentifier(candidate.type.identifier) }
          .map { (provider: $0, mime: candidate.mime, type: candidate.type) }
      }).first
    else { return }

    // Bound separately: the tuple holds a non-Sendable `NSItemProvider`, so
    // reaching through it inside the handler would capture the provider too.
    let mime = match.mime
    match.provider.loadDataRepresentation(forTypeIdentifier: match.type.identifier) {
      data, _ in
      guard let data, !data.isEmpty else { return }
      Task { @MainActor [weak self] in self?.onPaste?(data, mime) }
    }
  }
}
