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
  let loader: MediaLoader
  @Environment(\.dismiss) private var dismiss
  @State private var playable: URL?
  @State private var playbackFailed = false
  @State private var scale = 1.0
  @State private var committedScale = 1.0
  @State private var offset = CGSize.zero
  @State private var committedOffset = CGSize.zero

  var body: some View {
    NavigationStack {
      ZStack {
        Color.black.ignoresSafeArea()
        if item.kind == .video {
          // The relay requires read auth that `AVPlayer(url:)` cannot send, so
          // the blob is fetched to a local file first and played from there.
          if let playable {
            VideoPlayer(player: AVPlayer(url: playable))
              .accessibilityLabel(item.alt ?? "Video attachment")
          } else if playbackFailed {
            ContentUnavailableView("Video unavailable", systemImage: "video.slash")
              .foregroundStyle(.white)
          } else {
            ProgressView("Loading video…").tint(.white)
          }
        } else {
          MediaImage(url: item.url, loader: loader, maxPixel: 4096) {
            ProgressView("Loading media…").tint(.white)
          } failure: {
            ContentUnavailableView("Media unavailable", systemImage: "photo.badge.exclamationmark")
              .foregroundStyle(.white)
          }
          .scaledToFit()
          .scaleEffect(scale)
          .offset(offset)
          .gesture(zoomGesture)
          .accessibilityLabel(item.alt ?? "Image attachment")
        }
      }
      .task(id: item.url) {
        guard item.kind == .video else { return }
        playable = nil
        playbackFailed = false
        do {
          playable = try await loader.fileURL(for: item.url)
        } catch is CancellationError {
          return
        } catch {
          playbackFailed = true
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
