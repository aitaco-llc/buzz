import BuzzCore
import SwiftUI

struct HuddleView: View {
  @Bindable var workspace: Workspace
  let channel: Channel
  @Environment(\.dismiss) private var dismiss
  @State private var session: HuddleSessionInfo?
  @State private var transport: NativeHuddleTransport?
  @State private var busy = false
  @State private var reaction = ""

  var body: some View {
    NavigationStack {
      VStack(spacing: 20) {
        Image(systemName: "waveform.and.person.filled").font(.system(size: 52))
          .accessibilityHidden(true)
        if let session {
          Text("Huddle active").font(.title2.weight(.semibold))
          Text("Room: \(session.ephemeralChannelID.prefix(8))…")
            .multilineTextAlignment(.center).foregroundStyle(.secondary)
          if let transport {
            Label(
              transport.phase == .connected
                ? "Audio connected"
                : transport.phase == .connecting || transport.phase == .authenticating
                  ? "Connecting audio…" : "Audio unavailable",
              systemImage: transport.phase == .connected ? "waveform" : "exclamationmark.triangle"
            )
            .foregroundStyle(transport.phase == .connected ? .green : .secondary)
            if let error = transport.error { Text(error).font(.footnote).foregroundStyle(.red) }
            if transport.phase == .connected {
              Button("Mute microphone", systemImage: "mic.slash") {
                try? transport.setMuted(true)
              }.buttonStyle(.bordered)
            }
          }
          HStack {
            TextField("Reaction", text: $reaction)
              .textFieldStyle(.roundedBorder).accessibilityLabel("Huddle reaction")
            Button("Send", systemImage: "face.smiling") {
              let value = reaction
              reaction = ""
              Task { _ = await workspace.sendHuddleReaction(value, in: session) }
            }
            .disabled(reaction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
          Button("End huddle", systemImage: "phone.down.fill", role: .destructive) {
            busy = true
            Task {
              await transport?.disconnect()
              _ = await workspace.endHuddle(session)
              busy = false
              dismiss()
            }
          }
          .buttonStyle(.borderedProminent).disabled(busy)
        } else {
          Text("Start a huddle in \(workspace.channelName(channel))")
            .font(.title2.weight(.semibold)).multilineTextAlignment(.center)
          Text(
            "Starting publishes a signed lifecycle event. Microphone admission is unavailable until the room transport connects."
          )
          .multilineTextAlignment(.center).foregroundStyle(.secondary)
          Button("Start huddle", systemImage: "phone.fill") {
            busy = true
            Task {
              guard let started = await workspace.startHuddle(in: channel) else {
                busy = false
                return
              }
              session = started
              let nextTransport = NativeHuddleTransport(workspace: workspace, session: started)
              transport = nextTransport
              do {
                try await nextTransport.connectAndStartAudio()
              } catch {
                _ = await workspace.endHuddle(started)
              }
              busy = false
            }
          }
          .buttonStyle(.borderedProminent).disabled(busy)
        }
      }
      .padding(32).frame(maxWidth: 560)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .navigationTitle("Huddle")
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
      .task {
        guard let existing = workspace.activeHuddle(for: channel.id) else { return }
        session = existing
        let nextTransport = NativeHuddleTransport(workspace: workspace, session: existing)
        transport = nextTransport
        try? await nextTransport.connectAndStartAudio()
      }
    }
  }
}
