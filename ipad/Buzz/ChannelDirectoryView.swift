import BuzzCore
import SwiftUI

extension Workspace {
  @discardableResult
  func addMember(channel: Channel, pubkey: String, role: String = "member") async -> Bool {
    let normalized = pubkey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard normalized.count == 64,
      normalized.unicodeScalars.allSatisfy({
        $0.isASCII && ($0.value >= 48 && $0.value <= 57 || $0.value >= 97 && $0.value <= 102)
      })
    else { return false }
    do {
      let event = try identity.sign(
        kind: 9000, content: "",
        tags: [["h", channel.id], ["p", normalized], ["role", role]])
      try await store.enqueue(event)
      await reload()
      Task { await retry() }
      return true
    } catch {
      self.error = error.localizedDescription
      return false
    }
  }

  @discardableResult
  func updateChannel(_ channel: Channel, name: String, about: String) async -> Bool {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else { return false }
    do {
      var tags = [["h", channel.id], ["name", trimmedName]]
      let description = about.trimmingCharacters(in: .whitespacesAndNewlines)
      if !description.isEmpty { tags.append(["about", description]) }
      let event = try identity.sign(kind: 9002, content: "", tags: tags)
      try await store.enqueue(event)
      await reload()
      Task { await retry() }
      return true
    } catch {
      self.error = error.localizedDescription
      return false
    }
  }

  @discardableResult
  func archiveChannel(_ channel: Channel, archived: Bool) async -> Bool {
    do {
      let event = try identity.sign(
        kind: 9002, content: "", tags: [["h", channel.id], ["archived", String(archived)]])
      try await store.enqueue(event)
      await reload()
      Task { await retry() }
      return true
    } catch {
      self.error = error.localizedDescription
      return false
    }
  }

  @discardableResult
  func deleteChannel(_ channel: Channel) async -> Bool {
    do {
      let event = try identity.sign(kind: 9008, content: "", tags: [["h", channel.id]])
      try await store.enqueue(event)
      await reload()
      Task { await retry() }
      return true
    } catch {
      self.error = error.localizedDescription
      return false
    }
  }

  /// Queues a NIP-29 create-group command so creation survives a transient relay failure.
  @discardableResult
  func createChannel(name: String, type: String, about: String, isPublic: Bool) async -> Bool {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, ["stream", "forum"].contains(type) else { return false }
    do {
      let channelID = UUID().uuidString.lowercased()
      var tags = [
        ["h", channelID], ["name", trimmed], ["visibility", isPublic ? "public" : "private"],
        ["channel_type", type],
      ]
      let description = about.trimmingCharacters(in: .whitespacesAndNewlines)
      if !description.isEmpty { tags.append(["about", description]) }
      let event = try identity.sign(kind: 9007, content: "", tags: tags)
      try await store.enqueue(event)
      await reload()
      Task { await retry() }
      return true
    } catch {
      self.error = error.localizedDescription
      return false
    }
  }

  func loadDirectory(reset: Bool = false) async {
    guard !directoryLoading else { return }
    directoryLoading = true
    defer { directoryLoading = false }
    if reset {
      directoryCursor = nil
      directoryPages = 0
      directoryHasMore = true
    }
    do {
      guard directoryPages < 100 else { throw BuzzError.capacity }
      let authority = try await relay.authority()
      try await store.setRelayAuthority(authority)
      let page = try await DirectoryPage.fetch(
        relay: relay, authority: authority, after: directoryCursor)
      try Task.checkCancellation()
      try await store.ingest(page.events)
      directoryCursor = page.next
      directoryHasMore = page.next != nil
      directoryPages += 1
      directoryError = nil
      await reload()
    } catch is CancellationError { return } catch { directoryError = error.localizedDescription }
  }

  func requestMembership(channel: Channel, joining: Bool, replacing: String? = nil) async {
    await requestMembership(
      channelID: channel.id, channelName: channel.name, joining: joining, replacing: replacing)
  }

  func retryMembership(_ request: MembershipRequest) async {
    await requestMembership(
      channelID: request.channelID, channelName: request.channelName,
      joining: request.joining, replacing: request.id)
  }

  private func requestMembership(
    channelID: String, channelName: String, joining: Bool, replacing: String?
  ) async {
    guard !membershipBusy else { return }
    membershipBusy = true
    defer { membershipBusy = false }
    error = nil
    do {
      let identity = identity
      let event = try await Task.detached {
        try identity.sign(
          kind: joining ? 9021 : 9022, content: "",
          tags: [["h", channelID], ["nonce", UUID().uuidString]])
      }.value
      try await store.saveMembership(
        MembershipRequest(channelID: channelID, channelName: channelName, event: event),
        replacing: replacing)
      await reload()
      try await membershipManager.synchronize()
      await reload()
    } catch {
      self.error = error.localizedDescription
      await reload()
    }
  }

  func checkMemberships() async {
    guard !membershipBusy else { return }
    membershipBusy = true
    defer { membershipBusy = false }
    do { try await membershipManager.synchronize() } catch {
      self.error = error.localizedDescription
    }
    await reload()
  }

  func dismissMembership(_ request: MembershipRequest) async {
    guard !membershipBusy else { return }
    do {
      try await store.removeMembership(id: request.id)
      await reload()
    } catch { self.error = error.localizedDescription }
  }
}

struct ChannelDirectoryView: View {
  @Bindable var workspace: Workspace
  @Environment(\.dismiss) private var dismiss
  @State private var search = ""
  @State private var dismissRequest: MembershipRequest?
  @State private var retryRequest: MembershipRequest?
  @State private var showCreate = false

  private var available: [Channel] {
    let joined = Set(workspace.channels.map(\.id))
    return workspace.directory.filter {
      !joined.contains($0.id)
        && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
          || $0.about.localizedCaseInsensitiveContains(search))
    }
  }

  var body: some View {
    NavigationStack {
      List {
        if let error = workspace.error {
          Section("Unable to complete request") { Text(error).foregroundStyle(.red) }
        }
        if !workspace.intents.memberships.isEmpty {
          Section("Membership requests") {
            ForEach(workspace.intents.memberships) { request in
              VStack(alignment: .leading, spacing: 8) {
                Text("\(request.joining ? "Join" : "Leave") \(request.channelName)").font(.headline)
                Text(request.failure ?? "Waiting for membership confirmation.").font(.callout)
                HStack {
                  Button("Check status") { Task { await workspace.checkMemberships() } }
                  if request.phase == .checking {
                    Button("Send again") { retryRequest = request }
                  }
                  Button("Dismiss") { dismissRequest = request }
                }.buttonStyle(.bordered).disabled(workspace.membershipBusy)
              }
              .accessibilityElement(children: .contain)
            }
          }
        }
        Section("Open channels") {
          ForEach(available) { channel in
            HStack {
              VStack(alignment: .leading, spacing: 4) {
                Label(channel.name, systemImage: channel.type == "forum" ? "text.bubble" : "number")
                if !channel.about.isEmpty {
                  Text(channel.about).font(.caption).foregroundStyle(.secondary)
                }
              }
              Spacer()
              Button("Join") {
                Task { await workspace.requestMembership(channel: channel, joining: true) }
              }
              .buttonStyle(.bordered)
              .accessibilityLabel("Join \(channel.name)")
              .disabled(
                workspace.membershipBusy
                  || workspace.intents.memberships.contains { $0.channelID == channel.id })
            }
          }
          if available.isEmpty, !workspace.directoryLoading {
            Text("No open channels in the loaded results.").foregroundStyle(.secondary)
          }
          if workspace.directoryLoading { ProgressView("Loading channels…") }
          if let error = workspace.directoryError {
            Text(error).foregroundStyle(.red)
            Button("Retry loading channels") { Task { await workspace.loadDirectory() } }
          } else if workspace.directoryHasMore, !workspace.directoryLoading {
            Button("Load more channels") { Task { await workspace.loadDirectory() } }
          }
        }
      }
      .searchable(text: $search, prompt: "Filter loaded channels")
      .navigationTitle("Browse channels")
      .toolbar { Button("Done") { dismiss() } }
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Create", systemImage: "plus") { showCreate = true }
        }
      }
      .task { await workspace.loadDirectory(reset: true) }
      .refreshable { await workspace.loadDirectory(reset: true) }
      .confirmationDialog(
        "Dismiss this membership request?",
        isPresented: Binding(
          get: { dismissRequest != nil }, set: { if !$0 { dismissRequest = nil } })
      ) {
        if let request = dismissRequest {
          Button("Dismiss request", role: .destructive) {
            Task { await workspace.dismissMembership(request) }
          }
        }
      } message: {
        Text(
          "A submitted request may still take effect on the relay. Dismissing stops local status checks."
        )
      }
      .sheet(isPresented: $showCreate) { CreateChannelView(workspace: workspace) }
      .confirmationDialog(
        "Send a new membership request?",
        isPresented: Binding(
          get: { retryRequest != nil }, set: { if !$0 { retryRequest = nil } })
      ) {
        if let request = retryRequest {
          Button("Send new request") {
            Task {
              await workspace.retryMembership(request)
            }
          }
        }
      } message: {
        Text(
          "This is a new request to join or leave now, even if an earlier request reached the relay."
        )
      }
    }
  }
}

private struct CreateChannelView: View {
  @Bindable var workspace: Workspace
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var about = ""
  @State private var type = "stream"
  @State private var isPublic = true
  @State private var saving = false

  var body: some View {
    NavigationStack {
      Form {
        Section("Channel") {
          TextField("Name", text: $name)
          TextField("Description", text: $about, axis: .vertical).lineLimit(2...4)
          Picker("Type", selection: $type) {
            Text("Channel").tag("stream")
            Text("Forum").tag("forum")
          }
          Toggle("Public", isOn: $isPublic)
        }
        Section {
          Button {
            saving = true
            Task {
              if await workspace.createChannel(
                name: name, type: type, about: about, isPublic: isPublic)
              {
                dismiss()
              }
              saving = false
            }
          } label: {
            if saving { ProgressView("Creating…") } else { Text("Create channel") }
          }
          .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
      .navigationTitle("New channel")
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }
    .presentationDetents([.medium, .large])
  }
}

struct EditChannelView: View {
  @Bindable var workspace: Workspace
  let channel: Channel
  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var about: String
  @State private var saving = false

  init(workspace: Workspace, channel: Channel) {
    self.workspace = workspace
    self.channel = channel
    _name = State(initialValue: channel.name)
    _about = State(initialValue: channel.about)
  }

  var body: some View {
    NavigationStack {
      Form {
        TextField("Name", text: $name)
        TextField("Description", text: $about, axis: .vertical).lineLimit(2...4)
        Button {
          saving = true
          Task {
            if await workspace.updateChannel(channel, name: name, about: about) { dismiss() }
            saving = false
          }
        } label: {
          if saving { ProgressView("Saving…") } else { Text("Save changes") }
        }
        .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      .navigationTitle("Edit channel")
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }
  }
}

struct AddMemberView: View {
  @Bindable var workspace: Workspace
  let channel: Channel
  @Environment(\.dismiss) private var dismiss
  @State private var pubkey = ""
  @State private var saving = false
  @State private var invalid = false

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("64-character public key", text: $pubkey)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .accessibilityIdentifier("member-pubkey")
          if invalid {
            Text("Enter a valid 64-character hexadecimal public key.").foregroundStyle(.red)
          }
        } footer: {
          Text("The member receives access after the relay accepts the signed request.")
        }
        Button {
          saving = true
          Task {
            let added = await workspace.addMember(channel: channel, pubkey: pubkey)
            invalid = !added
            saving = false
            if added { dismiss() }
          }
        } label: {
          if saving { ProgressView("Adding…") } else { Text("Add member") }
        }
        .disabled(saving || pubkey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      .navigationTitle("Add member")
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }
  }
}
