import AVKit
import BuzzCore
import SwiftUI

struct MediaViewerItem: Identifiable {
  let id = UUID()
  let url: URL
  let kind: MessageMediaKind
  let alt: String?
}

/// Full-screen native media presentation for message attachments.
struct MediaViewer: View {
  let item: MediaViewerItem
  @Environment(\.dismiss) private var dismiss
  @State private var scale = 1.0
  @State private var committedScale = 1.0
  @State private var offset = CGSize.zero
  @State private var committedOffset = CGSize.zero

  var body: some View {
    NavigationStack {
      ZStack {
        Color.black.ignoresSafeArea()
        if item.kind == .video {
          VideoPlayer(player: AVPlayer(url: item.url))
            .accessibilityLabel(item.alt ?? "Video attachment")
        } else {
          AsyncImage(url: item.url) { phase in
            switch phase {
            case .success(let image):
              image.resizable().scaledToFit()
                .scaleEffect(scale)
                .offset(offset)
                .gesture(zoomGesture)
                .accessibilityLabel(item.alt ?? "Image attachment")
            case .failure:
              ContentUnavailableView(
                "Media unavailable", systemImage: "photo.badge.exclamationmark"
              )
              .foregroundStyle(.white)
            default:
              ProgressView("Loading media…").tint(.white)
            }
          }
        }
      }
      .navigationTitle(item.kind == .video ? "Video" : "Image")
      .navigationBarTitleDisplayMode(.inline)
      .toolbarColorScheme(.dark, for: .navigationBar)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done", systemImage: "xmark") { dismiss() }
            .accessibilityLabel("Close media viewer")
        }
        ToolbarItem(placement: .confirmationAction) {
          ShareLink(item: item.url) {
            Label("Share media", systemImage: "square.and.arrow.up")
          }
        }
      }
    }
  }

  private var zoomGesture: some Gesture {
    SimultaneousGesture(
      MagnificationGesture()
        .onChanged { value in scale = min(max(committedScale * value, 1), 6) }
        .onEnded { _ in committedScale = scale },
      DragGesture()
        .onChanged { value in
          offset = CGSize(
            width: committedOffset.width + value.translation.width,
            height: committedOffset.height + value.translation.height)
        }
        .onEnded { _ in committedOffset = offset }
    )
  }
}
