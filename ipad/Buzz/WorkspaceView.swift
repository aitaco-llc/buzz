import BuzzCore
import SwiftUI

struct WorkspaceView: View {
  @Bindable var model: AppModel
  @Bindable var workspace: Workspace
  @Bindable var preferences: NativePreferences
  @State private var selection: String?
  @State private var thread: Event?
  @State private var showSearch = false
  @State private var showConnection = false
  @State private var showSettings = false
  @State private var showDirectory = false
  @State private var showNewDM = false
  @State private var showActivity = false
  @State private var showPulse = false
  @Environment(\.scenePhase) private var scenePhase

  private var channel: Channel? { workspace.channels.first { $0.id == selection } }

  var body: some View {
    NavigationSplitView {
      List(selection: $selection) {
        Section {
          Button("Search", systemImage: "magnifyingglass") { showSearch = true }
            .keyboardShortcut("k", modifiers: .command)
          Button("Activity", systemImage: "bell") { showActivity = true }
          Button("Pulse", systemImage: "waveform") { showPulse = true }
          Button("Settings", systemImage: "gearshape") { showSettings = true }
          Button("Browse channels", systemImage: "number") { showDirectory = true }
          if !workspace.intents.memberships.isEmpty {
            Button("Membership requests (\(workspace.intents.memberships.count))") {
              showDirectory = true
            }
          }
        }
        channelSection("Channels", type: "stream", icon: "number")
        channelSection("Forums", type: "forum", icon: "text.bubble")
        Section("Direct messages") {
          Button("New direct message", systemImage: "square.and.pencil") { showNewDM = true }
          ForEach(workspace.channels.filter { $0.type == "dm" && !$0.archived }) { channel in
            HStack {
              Label(workspace.channelName(channel), systemImage: "person.2")
                .accessibilityIdentifier("channel-\(channel.id)")
              Spacer()
              let unread = workspace.unreadCount(for: channel)
              if !preferences.mutedChannels.contains(channel.id), unread > 0 {
                Text(unread > 99 ? "99+" : "\(unread)")
                  .font(.caption2.weight(.semibold)).foregroundStyle(.white)
                  .padding(.horizontal, 6).padding(.vertical, 3)
                  .background(.indigo, in: Capsule())
                  .accessibilityLabel("\(unread) unread")
                  .accessibilityIdentifier("unread-channel-\(channel.id)")
              }
            }
            .tag(channel.id)
            .contextMenu {
              Button(
                preferences.mutedChannels.contains(channel.id)
                  ? "Unmute conversation" : "Mute conversation",
                systemImage: preferences.mutedChannels.contains(channel.id) ? "bell" : "bell.slash"
              ) {
                preferences.setMuted(
                  !preferences.mutedChannels.contains(channel.id), channelID: channel.id)
              }
            }
          }
        }
        if !workspace.intents.pending.isEmpty {
          Section("Pending actions") {
            Label("\(workspace.intents.pending.count) awaiting acceptance", systemImage: "clock")
              .font(.caption).foregroundStyle(.secondary)
            Button("Retry pending actions", systemImage: "arrow.clockwise") {
              Task { await workspace.retry() }
            }
          }
        }
      }
      .navigationTitle(workspace.account.community.name)
      .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 340)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Menu {
            ForEach(model.accounts) { account in
              Button(account.community.name) { Task { await model.open(account) } }
            }
            Button("Add community", systemImage: "plus") { showConnection = true }
          } label: {
            Label("Switch community", systemImage: "building.2.crop.circle")
          }
        }
      }
      .refreshable { await workspace.refresh() }
    } detail: {
      if let channel {
        GeometryReader { geometry in
          HStack(spacing: 0) {
            if thread == nil || geometry.size.width >= 680 {
              ConversationView(workspace: workspace, channel: channel, root: nil) { thread = $0 }
                .id(channel.id)
                .frame(maxWidth: .infinity)
            }
            if let thread {
              if geometry.size.width >= 680 { Divider() }
              ConversationView(
                workspace: workspace, channel: channel, root: thread,
                closeThread: { self.thread = nil }
              ) { _ in }
              .id(thread.id)
              .frame(maxWidth: .infinity)
            }
          }
        }
      } else {
        ContentUnavailableView(
          "Pick a conversation", systemImage: "bubble.left.and.bubble.right",
          description: Text("Your channels and direct messages appear in the sidebar."))
      }
    }
    .onChange(of: selection) { _, _ in thread = nil }
    .onChange(of: workspace.channels.map(\.id)) { _, ids in
      if let selection, !ids.contains(selection) {
        self.selection = nil
        thread = nil
      }
    }
    .onChange(of: model.pendingDeepLink) { _, link in
      guard let link else { return }
      Task {
        if let event = await workspace.resolveDeepLink(link) {
          selection = link.channelID
          thread =
            event.rootID.flatMap { root in workspace.events.first { $0.id == root } } ?? event
        }
        model.pendingDeepLink = nil
      }
    }
    .task {
      await workspace.setPresence("online")
      await workspace.refresh()
      if let link = model.pendingDeepLink,
        let event = await workspace.resolveDeepLink(link)
      {
        selection = link.channelID
        thread = event.rootID.flatMap { root in workspace.events.first { $0.id == root } } ?? event
        model.pendingDeepLink = nil
      }
    }
    .onChange(of: scenePhase) { _, phase in
      switch phase {
      case .active:
        Task {
          await workspace.setPresence("online")
          await workspace.refresh()
        }
      case .inactive:
        Task { await workspace.setPresence("away") }
      case .background:
        Task { await workspace.setPresence("offline") }
      @unknown default:
        break
      }
    }
    .overlay(alignment: .bottom) {
      if let error = workspace.error {
        HStack {
          Image(systemName: "exclamationmark.triangle")
          Text(error).font(.callout).lineLimit(3)
          Button("Retry") { Task { await workspace.refresh() } }
          Button {
            workspace.error = nil
          } label: {
            Image(systemName: "xmark")
          }
          .accessibilityLabel("Dismiss error")
        }
        .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)).padding()
        .accessibilityElement(children: .contain)
      }
    }
    .sheet(isPresented: $showSearch) {
      SearchView(workspace: workspace) { event in
        selection = event.tag("h")
        thread = event.rootID.flatMap { id in workspace.events.first { $0.id == id } } ?? event
      }
    }
    .sheet(isPresented: $showActivity) {
      ActivityView(workspace: workspace) { item in
        if let channelID = item.channelID { selection = channelID }
        thread =
          item.event.rootID.flatMap { root in workspace.events.first { $0.id == root } }
          ?? item.event
      }
    }
    .sheet(isPresented: $showPulse) { PulseView(workspace: workspace) }
    .sheet(isPresented: $showConnection) { ConnectionView(model: model) }
    .sheet(isPresented: $showSettings) {
      SettingsView(workspace: workspace, preferences: preferences)
    }
    .sheet(isPresented: $showDirectory) { ChannelDirectoryView(workspace: workspace) }
    .sheet(isPresented: $showNewDM) {
      NewDirectMessageView(workspace: workspace) { channel in
        selection = channel.id
        thread = nil
        showNewDM = false
      }
    }
  }

  @ViewBuilder private func channelSection(_ title: String, type: String, icon: String) -> some View
  {
    let channels = workspace.channels
      .filter { $0.type == type && !$0.archived }
      .sorted {
        let lhsStarred = preferences.starredChannels.contains($0.id)
        let rhsStarred = preferences.starredChannels.contains($1.id)
        if lhsStarred != rhsStarred { return lhsStarred }
        return workspace.channelName($0).localizedStandardCompare(workspace.channelName($1))
          == .orderedAscending
      }
    if !channels.isEmpty {
      Section(title) {
        ForEach(channels) { channel in
          HStack {
            Label(workspace.channelName(channel), systemImage: icon)
              .accessibilityIdentifier("channel-\(channel.id)")
            Spacer()
            if preferences.starredChannels.contains(channel.id) {
              Image(systemName: "star.fill").foregroundStyle(.orange)
                .accessibilityLabel("Starred")
            }
            if preferences.mutedChannels.contains(channel.id) {
              Image(systemName: "bell.slash").foregroundStyle(.secondary)
                .accessibilityLabel("Muted")
            }
            let unread = workspace.unreadCount(for: channel)
            if !preferences.mutedChannels.contains(channel.id), unread > 0 {
              Text(unread > 99 ? "99+" : "\(unread)")
                .font(.caption2.weight(.semibold)).foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.indigo, in: Capsule())
                .accessibilityLabel("\(unread) unread")
                .accessibilityIdentifier("unread-channel-\(channel.id)")
            }
          }
          .tag(channel.id)
          .contextMenu {
            Button(
              preferences.starredChannels.contains(channel.id) ? "Unstar channel" : "Star channel",
              systemImage: preferences.starredChannels.contains(channel.id) ? "star.slash" : "star"
            ) {
              preferences.setStarred(
                !preferences.starredChannels.contains(channel.id), channelID: channel.id)
            }
            Button(
              preferences.mutedChannels.contains(channel.id) ? "Unmute channel" : "Mute channel",
              systemImage: preferences.mutedChannels.contains(channel.id) ? "bell" : "bell.slash"
            ) {
              preferences.setMuted(
                !preferences.mutedChannels.contains(channel.id), channelID: channel.id)
            }
          }
        }
      }
    }
  }
}
