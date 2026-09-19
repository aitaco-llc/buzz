import BuzzCore
import SwiftUI

struct ReactionRow: View {
  @Bindable var workspace: Workspace
  let message: Event
  let add: () -> Void
  @State private var people: ReactionPeople?
  private var groups: [ReactionGroup] { workspace.reactions[message.id] ?? [] }

  var body: some View {
    ViewThatFits(in: .horizontal) {
      pills
      ScrollView(.horizontal) { pills }
    }
    .sheet(item: $people) { selection in
      NavigationStack {
        List {
          if let group = groups.first(where: { $0.value == selection.id }) {
            ForEach(group.authors, id: \.self) { pubkey in
              Label(
                workspace.name(pubkey),
                systemImage: pubkey == workspace.identity.pubkey
                  ? "person.crop.circle.fill" : "person.crop.circle")
            }
          } else {
            Text("No reactions remain")
          }
        }
        .navigationTitle("People who reacted \(selection.id)")
        .toolbar { Button("Done") { people = nil } }
      }
    }
  }

  private var pills: some View {
    HStack(spacing: 8) {
      ForEach(groups) { group in
        let mine = !group.ownedIDs(workspace.identity.pubkey).isEmpty
        let imageURL =
          group.imageURL ?? workspace.customEmoji.first { $0.value == group.value }?.url
        Button {
          Task {
            await workspace.react(
              to: message, value: group.value, imageURL: imageURL, toggle: true)
          }
        } label: {
          HStack(spacing: 4) {
            ReactionGlyph(value: group.value, url: imageURL).accessibilityHidden(true)
            Text("\(group.count)").font(.callout)
          }
        }
        .buttonStyle(.bordered)
        .tint(mine ? .indigo : .secondary)
        .disabled(workspace.reactionBusy.contains(message.id))
        .accessibilityLabel(
          "\(mine ? "Remove your" : "Add") \(group.value) reaction, \(group.count) \(group.count == 1 ? "person" : "people")"
        )
        .accessibilityValue(mine ? "You reacted" : "")
        .accessibilityIdentifier("reaction-\(message.id)-\(group.value)")
        .accessibilityAction(named: "Who reacted") { people = ReactionPeople(id: group.value) }
        .contextMenu { Button("Who reacted") { people = ReactionPeople(id: group.value) } }
      }
      Button(action: add) { Image(systemName: "face.smiling") }
        .buttonStyle(.bordered)
        .accessibilityLabel("Add reaction")
        .accessibilityIdentifier("add-reaction-\(message.id)")
    }
  }
}

private struct ReactionPeople: Identifiable { let id: String }
