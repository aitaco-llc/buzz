import BuzzCore
import SwiftUI

enum PulseProjection {
  static func notes(events: [Event], identity: Identity, mineOnly: Bool) -> [Event] {
    events.filter { !mineOnly || $0.pubkey == identity.pubkey }
      .sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
  }
}

struct PulseView: View {
  let workspace: Workspace
  @Environment(\.dismiss) private var dismiss
  @State private var draft = ""
  @State private var showingComposer = false
  @State private var mineOnly = false

  private var notes: [Event] {
    PulseProjection.notes(
      events: workspace.pulseEvents, identity: workspace.identity, mineOnly: mineOnly)
  }

  var body: some View {
    NavigationStack {
      Group {
        if workspace.pulseLoading && notes.isEmpty {
          ProgressView("Loading Pulse…")
        } else if notes.isEmpty {
          ContentUnavailableView(
            "No notes yet", systemImage: "waveform",
            description: Text("Share a note with your community."))
        } else {
          List {
            ForEach(notes, id: \.id) { note in
              Button {
                draft = note.content
                showingComposer = true
              } label: {
                VStack(alignment: .leading, spacing: 5) {
                  HStack(spacing: 8) {
                    Avatar(workspace: workspace, pubkey: note.pubkey, size: 24)
                    Text(workspace.name(note.pubkey)).font(.headline)
                    Spacer()
                    Text(
                      Date(timeIntervalSince1970: TimeInterval(note.createdAt)), style: .relative
                    )
                    .font(.caption).foregroundStyle(.tertiary)
                  }
                  Text(note.content).frame(maxWidth: .infinity, alignment: .leading)
                  if note.rootID != nil {
                    Label("Reply", systemImage: "arrowshape.turn.up.left").font(.caption)
                      .foregroundStyle(.secondary)
                  }
                  PulseReactionButton(workspace: workspace, note: note)
                }
              }
              .buttonStyle(.plain)
              .accessibilityIdentifier("pulse-note-\(note.id)")
            }
          }
        }
      }
      .navigationTitle("Pulse")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
        ToolbarItem(placement: .topBarLeading) {
          Toggle("Mine", isOn: $mineOnly).labelsHidden().accessibilityLabel("Show my notes only")
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button("New note", systemImage: "square.and.pencil") {
            draft = ""
            showingComposer = true
          }
        }
      }
      .refreshable { await workspace.loadPulse() }
      .task { await workspace.loadPulse() }
      .sheet(isPresented: $showingComposer) {
        NavigationStack {
          Form {
            TextEditor(text: $draft).frame(minHeight: 160).accessibilityIdentifier("pulse-composer")
          }
          .navigationTitle("New note")
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button("Cancel") { showingComposer = false }
            }
            ToolbarItem(placement: .confirmationAction) {
              Button("Post") {
                let text = draft
                Task {
                  if await workspace.postPulse(text: text) {
                    showingComposer = false
                    await workspace.loadPulse()
                  }
                }
              }.disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
          }
        }
        .presentationDetents([.medium, .large])
      }
    }
  }
}

private struct PulseReactionButton: View {
  @Bindable var workspace: Workspace
  let note: Event

  private var group: ReactionGroup? {
    workspace.reactions[note.id]?.first { $0.value == "❤️" }
  }

  var body: some View {
    let own = !(group?.ownedIDs(workspace.identity.pubkey) ?? []).isEmpty
    Button {
      Task { await workspace.react(to: note, value: "❤️", toggle: true) }
    } label: {
      Label("\(group?.count ?? 0)", systemImage: own ? "heart.fill" : "heart")
        .foregroundStyle(own ? .pink : .secondary)
    }
    .buttonStyle(.borderless)
    .accessibilityLabel(own ? "Remove heart reaction" : "Add heart reaction")
    .accessibilityIdentifier("pulse-heart-\(note.id)")
  }
}
