import BuzzCore
import SwiftUI

struct NewDirectMessageView: View {
  @Bindable var workspace: Workspace
  let onCreated: (Channel) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var search = ""
  @State private var selected = Set<String>()
  @State private var creating = false

  private var people: [MentionCandidate] {
    let candidates = workspace.events.filter {
      $0.kind == 0 && $0.pubkey != workspace.identity.pubkey
    }
    .reduce(into: [String: MentionCandidate]()) { result, event in
      result[event.pubkey] = MentionCandidate(
        pubkey: event.pubkey, name: workspace.name(event.pubkey))
    }.values
    return candidates.filter {
      search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || $0.name.localizedCaseInsensitiveContains(search)
        || $0.pubkey.localizedCaseInsensitiveContains(search)
    }.sorted { ($0.name.localizedLowercase, $0.pubkey) < ($1.name.localizedLowercase, $1.pubkey) }
  }

  var body: some View {
    NavigationStack {
      List {
        if !selected.isEmpty {
          Section("Recipients (\(selected.count)/8)") {
            ForEach(Array(selected).sorted(), id: \.self) { pubkey in
              HStack {
                Text(workspace.name(pubkey))
                Spacer()
                Button("Remove", systemImage: "minus.circle") { selected.remove(pubkey) }
                  .labelStyle(.iconOnly)
                  .accessibilityLabel("Remove \(workspace.name(pubkey))")
              }
            }
          }
        }
        Section("People") {
          ForEach(people, id: \.pubkey) { person in
            Button {
              if selected.contains(person.pubkey) {
                selected.remove(person.pubkey)
              } else if selected.count < 8 {
                selected.insert(person.pubkey)
              }
            } label: {
              HStack {
                Text(person.name)
                Spacer()
                if selected.contains(person.pubkey) {
                  Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                }
              }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("dm-person-\(person.pubkey)")
          }
          if people.isEmpty { Text("No matching people.").foregroundStyle(.secondary) }
        }
      }
      .searchable(text: $search, prompt: "Search people")
      .navigationTitle("New direct message")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Create") {
            creating = true
            Task {
              do {
                let channel = try await workspace.openDM(with: Array(selected))
                onCreated(channel)
              } catch {
                workspace.error = error.localizedDescription
              }
              creating = false
            }
          }
          .disabled(selected.isEmpty || creating)
        }
      }
      .overlay { if creating { ProgressView("Creating conversation…") } }
    }
  }
}
