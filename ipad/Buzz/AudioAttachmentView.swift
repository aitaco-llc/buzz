import AVFoundation
import SwiftUI

struct AudioAttachmentView: View {
  let url: URL
  @State private var player: AVPlayer?
  @State private var playing = false

  var body: some View {
    HStack(spacing: 10) {
      Button {
        if let player, playing {
          player.pause()
          playing = false
        } else {
          let next = player ?? AVPlayer(url: url)
          next.play()
          player = next
          playing = true
        }
      } label: {
        Label(
          playing ? "Pause audio attachment" : "Play audio attachment",
          systemImage: playing ? "pause.fill" : "play.fill")
      }
      .buttonStyle(.bordered)
      .accessibilityIdentifier("play-audio-\(url.absoluteString.hashValue)")
      Link(url.absoluteString, destination: url)
        .font(.caption).lineLimit(1)
    }
    .onDisappear {
      player?.pause()
      player = nil
      playing = false
    }
  }
}
