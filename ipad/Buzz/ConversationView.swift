import BuzzCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

private struct EditingMessage: Identifiable {
  let event: Event
  var id: String { event.id }
}

private struct ProfileTarget: Identifiable {
  let pubkey: String
  var id: String { pubkey }
}

struct ConversationView: View {
  @Bindable var workspace: Workspace
  let channel: Channel
  let root: Event?
  let closeThread: (() -> Void)?
  let openThread: (Event) -> Void
  @State private var draft = ""
  @State private var photoItem: PhotosPickerItem?
  @State private var mediaTags: [[String]] = []
  @State private var uploadingMedia = false
  @State private var showPreview = false
  @State private var voiceRecorder: VoiceNoteRecorder?
  @State private var lastTypingSentAt = Date.distantPast
  @State private var deleteTarget: Event?
  @State private var editTarget: EditingMessage?
  @State private var reactionTarget: EditingMessage?
  @State private var editedText = ""
  @State private var showDetails = false
  @State private var showEditChannel = false
  @State private var showAddMember = false
  @State private var confirmArchive = false
  @State private var confirmDeleteChannel = false
  @State private var confirmLeave = false
  @State private var showHuddle = false
  @State private var mediaViewer: MediaViewerItem?
  @State private var profileTarget: ProfileTarget?
  @State private var reminderTarget: Event?
  @State private var refreshGeneration = UUID()
  @State private var history: ConversationHistory
  @Environment(\.scenePhase) private var scenePhase

  private var draftKey: String { Workspace.draftKey(channel: channel.id, root: root?.id) }
  init(
    workspace: Workspace, channel: Channel, root: Event?, closeThread: (() -> Void)? = nil,
    openThread: @escaping (Event) -> Void
  ) {
    self.workspace = workspace
    self.channel = channel
    self.root = root
    self.closeThread = closeThread
    self.openThread = openThread
    _history = State(
      initialValue: ConversationHistory(
        workspace: workspace, channelID: channel.id, rootID: root?.id))
  }

  private var messages: [Event] { history.messages }
  private var replyCounts: [String: Int] { Projection.replyCounts(events: workspace.visibleEvents) }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          if root == nil { historyControls(proxy: proxy).id("history-controls") }
          if messages.isEmpty, history.loaded, history.error == nil {
            ContentUnavailableView(
              root == nil ? "Start a conversation" : "No replies yet",
              systemImage: "bubble.left", description: Text("Write the first message below.")
            )
            .frame(maxWidth: .infinity).padding(.top, 80)
          }
          ForEach(messages, id: \.id) { event in
            messageRow(event).id(event.id)
            Divider().padding(.leading, 60)
          }
          if root != nil { historyControls(proxy: proxy).id("history-controls") }
          Color.clear.frame(height: 1).id("bottom")
        }
        .padding(.horizontal)
      }
      .defaultScrollAnchor(.bottom)
      .accessibilityIdentifier(root == nil ? "channel-history" : "thread-history")
      .overlay(alignment: .bottomTrailing) {
        Button {
          proxy.scrollTo("bottom", anchor: .bottom)
        } label: {
          Label("Latest", systemImage: "arrow.down").font(.caption)
        }
        .buttonStyle(.bordered).background(.regularMaterial, in: Capsule()).padding()
      }
      .safeAreaInset(edge: .top, spacing: 0) {
        HStack(spacing: 8) {
          Text(root == nil ? workspace.channelName(channel) : "Thread")
            .font(.headline).lineLimit(1).accessibilityAddTraits(.isHeader)
          Spacer(minLength: 0)
          Button(
            root == nil ? "Older messages" : "More replies", systemImage: "clock.arrow.circlepath"
          ) {
            proxy.scrollTo("history-controls", anchor: root == nil ? .top : .bottom)
          }
          Button("Refresh", systemImage: "arrow.clockwise") { refreshGeneration = UUID() }
          Button("Channel details", systemImage: "info.circle") { showDetails = true }
          if root == nil, channel.type != "dm" {
            Button("Huddle", systemImage: "waveform.and.person.filled") { showHuddle = true }
          }
          if let closeThread {
            Button("Close thread", systemImage: "xmark", action: closeThread)
          }
        }
        .labelStyle(.iconOnly).buttonStyle(.bordered).controlSize(.large)
        .padding(.horizontal).padding(.vertical, 8).background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(root == nil ? "channel-toolbar" : "thread-toolbar")
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      VStack(spacing: 0) {
        let names = workspace.typingNames(for: channel, root: root)
        if !names.isEmpty {
          Text(typingLabel(names))
            .font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal).padding(.top, 6)
            .accessibilityIdentifier("typing-indicator")
        }
        composer
      }
    }
    .onAppear { draft = workspace.intents.drafts[draftKey] ?? "" }
    .task(id: "\(refreshGeneration)-\(scenePhase)") {
      if scenePhase == .active {
        async let updates: Void = workspace.watch(channel: channel)
        await history.refresh()
        if root == nil { await workspace.markChannelRead(channel.id) }
        await updates
      } else {
        history.cancel()
      }
    }
    .onDisappear {
      history.cancel()
      voiceRecorder?.cancel()
      voiceRecorder = nil
    }
    .sheet(isPresented: $showHuddle) {
      HuddleView(workspace: workspace, channel: channel)
    }
    .fullScreenCover(item: $mediaViewer) { item in
      MediaViewer(item: item, loader: workspace.media)
    }
    .onChange(of: draft) { _, text in
      workspace.saveDraft(text, key: draftKey)
      guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        Date().timeIntervalSince(lastTypingSentAt) >= 3
      else { return }
      lastTypingSentAt = Date()
      Task { await workspace.sendTyping(channel: channel, root: root) }
    }
    .onChange(of: photoItem) { _, item in
      guard let item else { return }
      uploadingMedia = true
      Task {
        defer {
          uploadingMedia = false
          photoItem = nil
        }
        do {
          guard let data = try await item.loadTransferable(type: Data.self), !data.isEmpty else {
            throw BuzzError.invalidResponse
          }
          let mime = item.supportedContentTypes.first?.preferredMIMEType ?? "image/jpeg"
          let descriptor = try await workspace.uploadMedia(data, mimeType: mime)
          mediaTags.append(descriptor.imetaTag())
          draft += (draft.isEmpty ? "" : "\n") + "![image](\(descriptor.url))"
        } catch {
          workspace.error = error.localizedDescription
        }
      }
    }
    .confirmationDialog(
      "Delete this message?",
      isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    ) {
      if let event = deleteTarget {
        Button("Delete message", role: .destructive) {
          Task {
            await workspace.action(
              kind: 5, content: "", tags: [["h", channel.id], ["e", event.id]])
          }
        }
      }
    } message: {
      Text("This removes the message from the conversation.")
    }
    .sheet(item: $editTarget) { target in
      let event = target.event
      NavigationStack {
        TextEditor(text: $editedText).padding().accessibilityLabel("Edit message")
          .navigationTitle("Edit message")
          .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editTarget = nil } }
            ToolbarItem(placement: .confirmationAction) {
              Button("Save") {
                let text = editedText
                Task {
                  if await workspace.action(
                    kind: 40003, content: text, tags: [["h", channel.id], ["e", event.id]])
                  {
                    editTarget = nil
                  }
                }
              }.disabled(editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
          }
      }
    }
    .sheet(item: $reactionTarget) { target in
      ReactionPicker(workspace: workspace, message: target.event)
    }
    .sheet(item: $profileTarget) { target in
      UserProfileView(workspace: workspace, pubkey: target.pubkey)
    }
    .confirmationDialog(
      "Remind me about this message",
      isPresented: Binding(get: { reminderTarget != nil }, set: { if !$0 { reminderTarget = nil } })
    ) {
      if let event = reminderTarget {
        Button("In 15 minutes") { scheduleReminder(event, after: 15 * 60) }
        Button("In 1 hour") { scheduleReminder(event, after: 60 * 60) }
        Button("Tomorrow") { scheduleReminder(event, after: 24 * 60 * 60) }
      }
    } message: {
      Text("aitaco will notify you on this iPad and open the message when tapped.")
    }
    .sheet(isPresented: $showDetails) {
      NavigationStack {
        Form {
          Section("About") { Text(channel.about.isEmpty ? "No description" : channel.about) }
          Section("People") {
            ForEach(channel.participants, id: \.self) { pubkey in
              HStack(spacing: 10) {
                Avatar(workspace: workspace, pubkey: pubkey, size: 28)
                Text(workspace.name(pubkey))
              }
            }
            if channel.type != "dm" {
              Button("Add member", systemImage: "person.badge.plus") { showAddMember = true }
            }
          }
          if channel.type != "dm" {
            Section {
              Button("Edit channel", systemImage: "pencil") { showEditChannel = true }
              Button(
                channel.archived ? "Unarchive channel" : "Archive channel",
                systemImage: "archivebox"
              ) {
                confirmArchive = true
              }
              Button("Delete channel", systemImage: "trash", role: .destructive) {
                confirmDeleteChannel = true
              }
              Button("Leave channel", role: .destructive) { confirmLeave = true }
                .disabled(
                  workspace.membershipBusy
                    || workspace.intents.memberships.contains { $0.channelID == channel.id })
            }
          }
        }.navigationTitle(workspace.channelName(channel))
          .toolbar { Button("Done") { showDetails = false } }
          .confirmationDialog("Leave \(channel.name)?", isPresented: $confirmLeave) {
            Button("Leave channel", role: .destructive) {
              Task {
                await workspace.requestMembership(channel: channel, joining: false)
                showDetails = false
              }
            }
            .accessibilityIdentifier("confirm-leave-channel")
          } message: {
            Text(
              "Your drafts stay on this iPad. Unconfirmed requests remain available under Browse channels."
            )
          }
          .confirmationDialog(
            channel.archived ? "Unarchive \(channel.name)?" : "Archive \(channel.name)?",
            isPresented: $confirmArchive
          ) {
            Button(channel.archived ? "Unarchive" : "Archive") {
              Task {
                _ = await workspace.archiveChannel(channel, archived: !channel.archived)
                showDetails = false
              }
            }
          } message: {
            Text(
              channel.archived
                ? "The channel will become available again after the relay accepts the command."
                : "Archiving hides the channel from active lists; existing history remains recoverable."
            )
          }
          .confirmationDialog(
            "Delete \(channel.name)?", isPresented: $confirmDeleteChannel
          ) {
            Button("Delete channel", role: .destructive) {
              Task {
                _ = await workspace.deleteChannel(channel)
                showDetails = false
              }
            }
          } message: {
            Text("This submits a relay command and cannot be undone locally.")
          }
      }
    }
    .sheet(isPresented: $showEditChannel) {
      EditChannelView(workspace: workspace, channel: channel)
    }
    .sheet(isPresented: $showAddMember) {
      AddMemberView(workspace: workspace, channel: channel)
    }
  }

  @ViewBuilder private func historyControls(proxy: ScrollViewProxy) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      if let error = history.error {
        Text(error).font(.callout).foregroundStyle(.red)
          .accessibilityIdentifier("history-error")
      }
      if history.loading {
        ProgressView("Loading history…")
      } else if history.error != nil || history.hasMore {
        Button(
          history.error != nil
            ? "Retry history" : (root == nil ? "Load older messages" : "Load more replies")
        ) {
          let anchor = root == nil ? messages.first?.id : messages.last?.id
          Task {
            if await history.loadMore(), let anchor, !Task.isCancelled {
              proxy.scrollTo(anchor, anchor: root == nil ? .top : .bottom)
            }
          }
        }
        .accessibilityIdentifier(root == nil ? "load-older-messages" : "load-more-replies")
      } else if history.loaded {
        Text(root == nil ? "Beginning of loaded history" : "All available replies loaded")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical)
  }

  private func messageRow(_ event: Event) -> some View {
    let pending = workspace.intents.pending.first { $0.id == event.id }
    let content = Projection.content(of: event, events: workspace.visibleEvents)
    let imeta = MessageMedia.parseImetaTags(event.tags)
    let attachments = MessageMedia.urls(in: content).compactMap {
      url -> (String, MessageMediaKind, ImetaEntry?)? in
      guard let kind = MessageMedia.classify(url, imeta: imeta[url]) else { return nil }
      return (url, kind, imeta[url])
    }
    return HStack(alignment: .top, spacing: 12) {
      Avatar(workspace: workspace, pubkey: event.pubkey)
      VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .firstTextBaseline) {
          Button(workspace.name(event.pubkey)) {
            profileTarget = ProfileTarget(pubkey: event.pubkey)
          }
          .font(.headline).buttonStyle(.plain)
          .accessibilityLabel("Open profile for \(workspace.name(event.pubkey))")
          Text(Date(timeIntervalSince1970: Double(event.createdAt)), style: .time)
            .font(.caption).foregroundStyle(.secondary)
          Spacer(minLength: 0)
          if pending != nil {
            Image(systemName: pending?.failure == nil ? "clock" : "exclamationmark.circle")
              .foregroundStyle(pending?.failure == nil ? Color.secondary : Color.orange)
              .accessibilityLabel(
                pending?.failure == nil
                  ? "Pending relay acceptance" : "Send failed. Retry available in sidebar.")
          }
        }
        RichMessageText(source: content)
          .frame(maxWidth: .infinity, alignment: .leading)
        ForEach(Array(attachments.enumerated()), id: \.offset) { _, attachment in
          attachmentView(attachment.0, kind: attachment.1, imeta: attachment.2)
        }
        if root == nil {
          let replies = replyCounts[event.id] ?? 0
          Button {
            openThread(event)
          } label: {
            Label(
              replies == 0 ? "Open thread" : "Open thread, \(replies) replies",
              systemImage: "bubble.right"
            )
          }
          .font(.caption).buttonStyle(.plain).foregroundStyle(Aitaco.accent)
          .accessibilityIdentifier("thread-\(event.id)")
        }
        ReactionRow(workspace: workspace, message: event) {
          reactionTarget = EditingMessage(event: event)
        }
      }
    }
    .padding(.vertical, 14)
    .contextMenu {
      Button("Reply", systemImage: "arrowshape.turn.up.left") { openThread(event) }
      let rootID = event.rootID ?? event.id
      Button(
        workspace.followedThreads.contains(rootID) ? "Unfollow thread" : "Follow thread",
        systemImage: workspace.followedThreads.contains(rootID) ? "bell.slash" : "bell"
      ) { workspace.toggleThreadFollow(rootID) }
      Button("Copy text", systemImage: "doc.on.doc") {
        UIPasteboard.general.string = Projection.content(of: event, events: workspace.events)
      }
      Button("Copy message link", systemImage: "link") {
        UIPasteboard.general.string =
          BuzzDeepLink(channelID: channel.id, eventID: event.id).url?.absoluteString
      }
      Button("Remind me later", systemImage: "bell.badge") { reminderTarget = event }
      Button("Add reaction", systemImage: "face.smiling") {
        reactionTarget = EditingMessage(event: event)
      }
      if event.pubkey == workspace.identity.pubkey && pending == nil {
        Button("Edit", systemImage: "pencil") {
          editedText = Projection.content(of: event, events: workspace.events)
          editTarget = EditingMessage(event: event)
        }
        Button("Delete", systemImage: "trash", role: .destructive) { deleteTarget = event }
      }
    }
  }

  private func scheduleReminder(_ event: Event, after interval: TimeInterval) {
    reminderTarget = nil
    Task {
      do {
        try await NativeReminderService.schedule(
          event: event, channel: channel, workspace: workspace, after: interval)
      } catch { workspace.error = error.localizedDescription }
    }
  }

  @ViewBuilder private func attachmentView(
    _ urlString: String, kind: MessageMediaKind, imeta: ImetaEntry?
  ) -> some View {
    if kind == .image, let url = URL(string: urlString) {
      Button {
        mediaViewer = MediaViewerItem(url: url, kind: .image, alt: imeta?.alt)
      } label: {
        MediaImage(url: url, loader: workspace.media, maxPixel: 1280) {
          ProgressView("Loading image…")
        } failure: {
          Label("Image unavailable", systemImage: "photo.badge.exclamationmark")
            .foregroundStyle(.secondary)
        }
        .scaledToFit().frame(maxWidth: 420, maxHeight: 280)
        .clipShape(RoundedRectangle(cornerRadius: 12))
      }
      .buttonStyle(.plain)
      .accessibilityLabel(imeta?.alt ?? "Open image attachment")
      .accessibilityHint("Opens the image viewer")
    } else if let url = URL(string: urlString) {
      if kind == .audio {
        AudioAttachmentView(url: url, loader: workspace.media)
      } else {
        Button {
          mediaViewer = MediaViewerItem(url: url, kind: .video, alt: imeta?.alt)
        } label: {
          Label("Open video attachment", systemImage: "video")
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("media-attachment")
      }
    }
  }

  private var mentionSuggestions: [MentionCandidate] {
    Mentions.ranked(
      workspace.events.filter { $0.kind == 0 }.map {
        MentionCandidate(
          pubkey: $0.pubkey, name: workspace.name($0.pubkey),
          member: channel.participants.contains($0.pubkey))
      }, query: Mentions.activeQuery(in: draft) ?? "")
  }

  private var composer: some View {
    VStack(alignment: .leading, spacing: 8) {
      if showPreview {
        VStack(alignment: .leading, spacing: 4) {
          Text("Preview").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
          if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("Nothing to preview yet.").font(.callout).foregroundStyle(.secondary)
          } else {
            RichMessageText(source: draft)
          }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12)
        )
        .accessibilityIdentifier("composer-preview")
      }
      HStack(alignment: .bottom, spacing: 12) {
        TextField(
          root == nil ? "Message \(workspace.channelName(channel))" : "Reply in thread",
          text: $draft,
          axis: .vertical
        )
        .lineLimit(1...8).padding(12)
        .background(
          Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14)
        )
        .accessibilityIdentifier(root == nil ? "message-composer" : "thread-composer")
        Button {
          showPreview.toggle()
        } label: {
          Image(systemName: showPreview ? "pencil" : "eye")
            .frame(width: 28, height: 28)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(showPreview ? "Edit message" : "Preview message")
        .accessibilityIdentifier("composer-preview-toggle")
        if Mentions.activeQuery(in: draft) != nil && !mentionSuggestions.isEmpty {
          Menu {
            ForEach(mentionSuggestions, id: \.pubkey) { candidate in
              Button("@\(candidate.name)") {
                guard let at = draft.lastIndex(of: "@") else { return }
                draft.replaceSubrange(at..., with: "@\(candidate.name) ")
              }
            }
          } label: {
            Image(systemName: "at").frame(width: 28, height: 28)
          }
          .accessibilityLabel("Mention someone")
          .accessibilityIdentifier("mention-suggestions")
        }
        PhotosPicker(selection: $photoItem, matching: .images) {
          Image(systemName: uploadingMedia ? "arrow.triangle.2.circlepath" : "paperclip")
            .frame(width: 28, height: 28)
        }
        .disabled(uploadingMedia || workspace.sending || channel.archived)
        .accessibilityLabel("Attach image")
        .accessibilityIdentifier("attach-image")
        Button {
          if let recorder = voiceRecorder, recorder.isRecording {
            let url = recorder.stop()
            voiceRecorder = nil
            guard let url else { return }
            uploadingMedia = true
            Task {
              defer {
                uploadingMedia = false
                try? FileManager.default.removeItem(at: url)
              }
              do {
                let descriptor = try await workspace.uploadMedia(
                  Data(contentsOf: url), mimeType: "audio/mp4")
                mediaTags.append(descriptor.imetaTag(filename: "voice-note.m4a"))
                draft += (draft.isEmpty ? "" : " ") + "[voice note](\(descriptor.url))"
              } catch { workspace.error = error.localizedDescription }
            }
          } else {
            do {
              let recorder = VoiceNoteRecorder()
              try recorder.start()
              voiceRecorder = recorder
            } catch { workspace.error = error.localizedDescription }
          }
        } label: {
          Image(systemName: voiceRecorder?.isRecording == true ? "stop.circle.fill" : "mic")
            .foregroundStyle(voiceRecorder?.isRecording == true ? .red : .primary)
            .frame(width: 28, height: 28)
        }
        .disabled(uploadingMedia || workspace.sending || channel.archived)
        .accessibilityLabel(
          voiceRecorder?.isRecording == true ? "Stop voice note" : "Record voice note"
        )
        .accessibilityIdentifier("voice-note")
        Button {
          let text = draft
          let tags = mediaTags
          Task {
            if await workspace.send(text: text, channel: channel, root: root, mediaTags: tags),
              draft == text
            {
              draft = ""
              mediaTags = []
            }
          }
        } label: {
          Image(systemName: "arrow.up").font(.headline).frame(width: 28, height: 28)
        }
        .buttonStyle(.borderedProminent).clipShape(Circle())
        .keyboardShortcut(.return, modifiers: .command)
        .accessibilityLabel(root == nil ? "Send message" : "Send reply")
        .disabled(
          workspace.sending || channel.archived
            || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding().background(.bar)
  }

  private func typingLabel(_ names: [String]) -> String {
    switch names.count {
    case 1: "\(names[0]) is typing…"
    case 2: "\(names[0]) and \(names[1]) are typing…"
    default: "\(names[0]) and \(names.count - 1) others are typing…"
    }
  }
}
