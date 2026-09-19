import BuzzCore
import PhotosUI
import SwiftUI

struct SearchView: View {
  @Bindable var workspace: Workspace
  let open: (Event) -> Void
  @State private var query = ""
  @State private var channelID: String?
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        if workspace.searching { ProgressView("Searching community…") }
        if let error = workspace.searchError {
          ContentUnavailableView(
            "Search unavailable", systemImage: "wifi.exclamationmark", description: Text(error))
        } else if !workspace.searching && !query.isEmpty && workspace.searchResults.isEmpty {
          ContentUnavailableView.search(text: query)
        }
        ForEach(workspace.searchResults, id: \.id) { event in
          Button {
            open(event)
            dismiss()
          } label: {
            VStack(alignment: .leading, spacing: 6) {
              Text(workspace.name(event.pubkey)).font(.headline)
              Text(event.content).lineLimit(4).foregroundStyle(.primary)
              Text(Date(timeIntervalSince1970: Double(event.createdAt)), style: .date)
                .font(.caption).foregroundStyle(.secondary)
            }.padding(.vertical, 4)
          }
        }
        if workspace.searchHasMore && !workspace.searchResults.isEmpty {
          Button("Load more results", systemImage: "arrow.down.circle") {
            Task { await workspace.loadMoreSearch() }
          }
          .disabled(workspace.searching)
          .frame(maxWidth: .infinity, alignment: .center)
          .accessibilityIdentifier("search-load-more")
        }
      }
      .navigationTitle("Search")
      .searchable(text: $query, prompt: "Search your community")
      .task(id: "\(query)|\(channelID ?? "all")") {
        await workspace.search(query, channelID: channelID)
      }
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Menu {
            Button("All channels") { channelID = nil }
            ForEach(workspace.channels.filter { !$0.archived }) { channel in
              Button(workspace.channelName(channel)) { channelID = channel.id }
            }
          } label: {
            Label(
              channelID.flatMap { id in
                workspace.channels.first { $0.id == id }.map(workspace.channelName)
              } ?? "All channels", systemImage: "line.3.horizontal.decrease.circle")
          }
          .accessibilityLabel("Search scope")
        }
        ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
      }
    }
  }
}

struct SettingsView: View {
  @Bindable var workspace: Workspace
  @Bindable var preferences: NativePreferences
  @Environment(\.dismiss) private var dismiss
  @State private var displayName = ""
  @State private var about = ""
  @State private var saving = false
  @State private var statusText = ""
  @State private var statusEmoji = ""
  @State private var savingStatus = false
  @State private var presence = "offline"
  @State private var avatarItem: PhotosPickerItem?
  @State private var uploadingAvatar = false

  var body: some View {
    NavigationStack {
      Form {
        Section("Profile") {
          PhotosPicker(selection: $avatarItem, matching: .images) {
            Label(
              uploadingAvatar ? "Uploading avatar…" : "Choose profile picture",
              systemImage: "person.crop.circle.badge.plus")
          }
          .disabled(uploadingAvatar)
          .accessibilityIdentifier("choose-avatar")
          TextField("Display name", text: $displayName)
          TextField("About you", text: $about, axis: .vertical)
          Button("Save profile") {
            saving = true
            Task {
              do {
                // Preserve fields this editor does not own, such as avatar and NIP-05.
                let profile = workspace.events.filter {
                  $0.kind == 0 && $0.pubkey == workspace.identity.pubkey
                }
                .max { $0.createdAt < $1.createdAt }
                var object: [String: Any] = [:]
                if let profile, let data = profile.content.data(using: .utf8) {
                  object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                }
                object["display_name"] = displayName
                object["about"] = about
                let data = try JSONSerialization.data(
                  withJSONObject: object, options: [.sortedKeys])
                await workspace.action(
                  kind: 0, content: String(decoding: data, as: UTF8.self), tags: [])
              } catch { workspace.error = error.localizedDescription }
              saving = false
            }
          }.disabled(saving || displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        Section("Status") {
          TextField("What are you working on?", text: $statusText)
          TextField("Emoji (optional)", text: $statusEmoji)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
          HStack {
            Button("Save status") {
              savingStatus = true
              Task {
                _ = await workspace.setStatus(text: statusText, emoji: statusEmoji)
                savingStatus = false
              }
            }
            .disabled(savingStatus)
            Button("Clear", role: .destructive) {
              savingStatus = true
              Task {
                _ = await workspace.setStatus(text: "", emoji: "")
                statusText = ""
                statusEmoji = ""
                savingStatus = false
              }
            }
            .disabled(savingStatus || (statusText.isEmpty && statusEmoji.isEmpty))
          }
          Text("Status is shared with your community and can be cleared at any time.")
            .font(.footnote).foregroundStyle(.secondary)
        }
        Section("Presence") {
          Picker("Availability", selection: $presence) {
            Text("Online").tag("online")
            Text("Away").tag("away")
            Text("Offline").tag("offline")
          }
          .onChange(of: presence) { _, value in Task { await workspace.setPresence(value) } }
          Text("Presence is temporary and is not stored in your message history.")
            .font(.footnote).foregroundStyle(.secondary)
        }
        Section("Appearance") {
          Picker(
            "Color scheme",
            selection: Binding(
              get: { preferences.scheme }, set: { preferences.setScheme($0) })
          ) {
            ForEach(NativePreferences.Scheme.allCases) { scheme in
              Text(scheme.label).tag(scheme)
            }
          }
          Picker(
            "Accent color",
            selection: Binding(
              get: { preferences.accent }, set: { preferences.setAccent($0) })
          ) {
            ForEach(NativePreferences.Accent.allCases) { accent in
              Label(accent.label, systemImage: "circle.fill").foregroundStyle(accent.color).tag(
                accent)
            }
          }
          Text("Appearance is stored only on this iPad.")
            .font(.footnote).foregroundStyle(.secondary)
        }
        Section("Notifications") {
          let push = NativePushStatus.shared
          LabeledContent("Authorization", value: push.authorizationLabel)
          if let token = push.deviceToken {
            Text("APNs registered").foregroundStyle(.secondary)
              .accessibilityLabel("APNs device registered")
            Text(String(token.prefix(16)) + "…")
              .font(.caption.monospaced()).foregroundStyle(.secondary)
          } else if let error = push.registrationError {
            Text(error).font(.footnote).foregroundStyle(.red)
          }
          Button("Request notification permission", systemImage: "bell.badge") {
            Task { await push.request() }
          }
          Button("Open iOS notification settings", systemImage: "gear") {
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
          }
        }
        Section("Community") {
          LabeledContent("Name", value: workspace.account.community.name)
          LabeledContent("Relay", value: workspace.account.community.id)
          Text(workspace.identity.pubkey).font(.caption.monospaced()).textSelection(.enabled)
            .accessibilityLabel("Public key: \(workspace.identity.pubkey)")
          NavigationLink {
            InviteCreateView(workspace: workspace)
          } label: {
            Label("Invite to community", systemImage: "person.badge.plus")
          }
        }
        Section("Local data") {
          LabeledContent("Pending actions", value: String(workspace.intents.pending.count))
          LabeledContent(
            "Saved drafts",
            value: String(workspace.intents.drafts.filter { !$0.value.isEmpty }.count))
          Text(
            "Drafts and pending actions are kept on this iPad, separately from downloaded conversations."
          )
          .font(.footnote).foregroundStyle(.secondary)
        }
      }
      .navigationTitle("Settings")
      .toolbar { Button("Done") { dismiss() } }
      .task {
        await NativePushStatus.shared.refresh()
        await workspace.loadStatus()
        presence = workspace.presence
        displayName = workspace.name(workspace.identity.pubkey)
        if let event = workspace.events.filter({
          $0.kind == 0 && $0.pubkey == workspace.identity.pubkey
        }).max(by: { $0.createdAt < $1.createdAt }),
          let data = event.content.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
          about = object["about"] as? String ?? ""
        }
        if let status = workspace.userStatus,
          let expiration = status.tag("expiration").flatMap(Int.init),
          expiration <= Int(Date().timeIntervalSince1970)
        {
          statusText = ""
          statusEmoji = ""
        } else if let status = workspace.userStatus {
          statusText = status.content
          statusEmoji = status.tag("emoji") ?? ""
        }
      }
      .onChange(of: avatarItem) { _, item in
        guard let item else { return }
        uploadingAvatar = true
        Task {
          defer {
            uploadingAvatar = false
            avatarItem = nil
          }
          do {
            guard let source = try await item.loadTransferable(type: Data.self),
              let data = AvatarImageProcessor.normalizedSquareJPEG(source)
            else { throw BuzzError.invalidResponse }
            _ = await workspace.setAvatar(data)
          } catch { workspace.error = error.localizedDescription }
        }
      }
    }
  }
}
