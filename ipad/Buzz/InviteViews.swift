import SwiftUI

struct InviteCreateView: View {
  @Bindable var workspace: Workspace
  @Environment(\.dismiss) private var dismiss
  @State private var ttlDays = 3
  @State private var maxUses = "none"
  @State private var invite: InviteLink?
  @State private var busy = false
  @State private var errorMessage: String?

  var body: some View {
    Form {
      Picker("Expires after", selection: $ttlDays) {
        Text("1 day").tag(1)
        Text("3 days").tag(3)
        Text("7 days").tag(7)
        Text("30 days").tag(30)
      }
      Picker("Uses", selection: $maxUses) {
        Text("No limit").tag("none")
        Text("1 use").tag("1")
        Text("3 uses").tag("3")
        Text("5 uses").tag("5")
        Text("10 uses").tag("10")
        Text("25 uses").tag("25")
      }
      Button(busy ? "Creating…" : "Create invite link") { create() }.disabled(busy)
      if let invite {
        Text(invite.shareURL.absoluteString).textSelection(.enabled)
        ShareLink(item: invite.shareURL) { Text("Share invite") }
        Button("Copy invite link") {
          UIPasteboard.general.string = invite.shareURL.absoluteString
        }
      }
      if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
    }
    .navigationTitle("Invite to community")
    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
  }

  private func create() {
    busy = true
    errorMessage = nil
    let uses = Int(maxUses)
    Task {
      defer { busy = false }
      do { invite = try await workspace.mintInvite(ttlDays: ttlDays, maxUses: uses) } catch {
        errorMessage = error.localizedDescription
      }
    }
  }
}

struct InviteJoinView: View {
  @Bindable var model: AppModel
  let invite: InviteLink
  @Environment(\.dismiss) private var dismiss
  @State private var busy = false
  @State private var errorMessage: String?

  var body: some View {
    Form {
      Label("Join this Buzz community?", systemImage: "person.badge.plus")
        .font(.headline)
      LabeledContent("Relay", value: invite.host)
      Text(
        "A new identity will be generated and stored in this iPad’s Keychain after the relay accepts the invite."
      )
      .font(.footnote).foregroundStyle(.secondary)
      if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
      Button(busy ? "Joining…" : "Join community") { join() }.disabled(busy)
    }
    .navigationTitle("Community invite")
    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
  }

  private func join() {
    busy = true
    errorMessage = nil
    Task {
      defer { busy = false }
      do {
        let account = try await model.claim(invite: invite)
        await model.open(account)
        dismiss()
      } catch { errorMessage = error.localizedDescription }
    }
  }
}
