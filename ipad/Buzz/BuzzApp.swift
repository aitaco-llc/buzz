import BuzzPushKit
import SwiftUI

@main
struct BuzzApp: App {
  @UIApplicationDelegateAdaptor(NativeAppDelegate.self) private var appDelegate
  @State private var model = AppModel()
  @State private var ageGate = AgeGate()
  @State private var preferences = NativePreferences()
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      Group {
        if ageGate.state == .restricted {
          AgeRestrictionView()
        } else {
          if let workspace = model.workspace {
            WorkspaceView(model: model, workspace: workspace, preferences: preferences)
              .id(workspace.account.id)
          } else {
            WelcomeView(model: model)
          }
        }
      }
      .tint(preferences.accent.color)
      .preferredColorScheme(preferences.colorScheme)
      .task {
        await ageGate.request()
        if ageGate.state == .allowed { await model.start() }
      }
      .onReceive(NotificationCenter.default.publisher(for: .buzzPushNavigationReceived)) {
        notification in
        if let target = notification.object as? BuzzPushNavigationTarget {
          model.handle(notification: target)
        }
      }
      .onOpenURL { model.handle(url: $0) }
      .sheet(item: $model.pendingInvite) { invite in
        InviteJoinView(model: model, invite: invite)
      }
      .onChange(of: scenePhase) { _, phase in
        if phase == .background { Task { await model.workspace?.finishDraftWrites() } }
      }
      .alert(
        "Buzz",
        isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })
      ) {
        Button("OK") { model.error = nil }
      } message: {
        Text(model.error ?? "")
      }
    }
  }
}

struct WelcomeView: View {
  @Bindable var model: AppModel
  @State private var showConnection = false

  var body: some View {
    VStack(spacing: 24) {
      Image(systemName: "bubble.left.and.bubble.right.fill")
        .font(.system(size: 64)).foregroundStyle(.indigo).accessibilityHidden(true)
      Text("Your workspace, together.").font(.largeTitle.bold())
      Text("Conversations, people, and agents.\nConnect to your Buzz community to get started.")
        .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
      Button("Connect a community", systemImage: "plus") { showConnection = true }
        .buttonStyle(.borderedProminent).controlSize(.large)
        .accessibilityIdentifier("connect-community")
      if model.opening { ProgressView("Opening community…") }
      ForEach(model.accounts) { account in
        Button(account.community.name) { Task { await model.open(account) } }
      }
    }
    .padding(32)
    .sheet(isPresented: $showConnection) { ConnectionView(model: model) }
  }
}

struct ConnectionView: View {
  @Bindable var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var url = ""
  @State private var key = ""
  @State private var authTag = ""
  @State private var connecting = false

  var body: some View {
    NavigationStack {
      Form {
        Section {
          NavigationLink {
            PairingView(model: model)
          } label: {
            Label("Pair with Buzz Desktop", systemImage: "qrcode")
          }
        }
        Section("Community") {
          TextField("Name", text: $name)
          TextField("https://your-community.example", text: $url)
            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            .accessibilityLabel("Community URL")
        }
        Section {
          SecureField("Private key (nsec or hexadecimal)", text: $key)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .accessibilityIdentifier("identity-private-key")
          SecureField("Owner attestation (if required)", text: $authTag)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
        } header: {
          Text("Identity")
        } footer: {
          Text(
            "Your private key stays in this device’s Keychain. Use the identity already admitted to your community."
          )
        }
        Section {
          Button {
            connecting = true
            Task {
              let success = await model.add(url: url, name: name, privateKey: key, authTag: authTag)
              connecting = false
              if success {
                key = ""
                authTag = ""
                dismiss()
              }
            }
          } label: {
            if connecting { ProgressView("Connecting…") } else { Text("Connect") }
          }
          .disabled(connecting || url.isEmpty || key.isEmpty)
        }
      }
      .navigationTitle("Add community")
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }
    .presentationDetents([.large])
  }
}
