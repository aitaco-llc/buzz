import AVFoundation
import BuzzCore
import SwiftUI

struct AudioAttachmentView: View {
  let url: URL
  let loader: MediaLoader
  @State private var player: AVPlayer?
  @State private var playing = false
  @State private var preparing = false
  @State private var failure: String?

  var body: some View {
    HStack(spacing: 10) {
      Button {
        if let player, playing {
          player.pause()
          playing = false
        } else {
          Task { await play() }
        }
      } label: {
        Label(
          playing ? "Pause audio attachment" : "Play audio attachment",
          systemImage: playing ? "pause.fill" : "play.fill")
      }
      .buttonStyle(.bordered)
      .disabled(preparing)
      .accessibilityIdentifier("play-audio-\(url.absoluteString.hashValue)")
      if preparing { ProgressView().controlSize(.small) }
      if let failure {
        Label(failure, systemImage: "exclamationmark.circle")
          .font(.caption).foregroundStyle(.secondary)
      } else {
        Link(url.absoluteString, destination: url)
          .font(.caption).lineLimit(1)
      }
    }
    .onDisappear {
      player?.pause()
      player = nil
      playing = false
    }
  }

  /// The relay requires read auth on the blob, which `AVPlayer(url:)` does not
  /// send. Fetch it through the authenticated loader first, then play the file.
  private func play() async {
    if let player {
      player.play()
      playing = true
      return
    }
    preparing = true
    failure = nil
    defer { preparing = false }
    do {
      let file = try await loader.fileURL(for: url)
      let next = AVPlayer(url: file)
      next.play()
      player = next
      playing = true
    } catch is CancellationError {
      return
    } catch {
      failure = "Audio unavailable"
    }
  }
}
