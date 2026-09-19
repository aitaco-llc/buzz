import BuzzPushKit
import SwiftUI

#if !SWIFT_PACKAGE
  @main
  enum BuzzAppMain {
    @MainActor static func main() { BuzzApp.main() }
  }
#endif

/// Runs the native iPad UI. The universal app calls this from
/// `mobile/ios/Runner/main.swift` on iPad; iPhone runs the Flutter app.
public enum BuzzPad {
  @MainActor public static func run() -> Never {
    BuzzApp.main()
    fatalError("UIApplicationMain returned")
  }
}

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
        "aitaco",
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
      AitacoMark(size: 116)
        .padding(18)
        .background(Circle().fill(.white.opacity(0.3)))
      Text("Welcome to aitaco").font(.largeTitle.bold())
      Text("Conversations, people, and agents.\nPair with your desktop app to get started.")
        .font(.title3).foregroundStyle(Aitaco.ink.opacity(0.7)).multilineTextAlignment(.center)
      Button("Connect", systemImage: "qrcode") { showConnection = true }
        .buttonStyle(.borderedProminent).controlSize(.large)
        .tint(Aitaco.ink)
        .foregroundStyle(Aitaco.shell)
        .accessibilityIdentifier("connect-community")
      if model.opening { ProgressView("Opening aitaco…") }
      ForEach(model.accounts.filter { Aitaco.allows($0.community) }) { account in
        Button("Open aitaco") { Task { await model.open(account) } }
          .tint(Aitaco.ink)
      }
    }
    .foregroundStyle(Aitaco.ink)
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(
      LinearGradient(colors: [Aitaco.teal, Aitaco.shell], startPoint: .top, endPoint: .bottom)
        .ignoresSafeArea()
    )
    .sheet(isPresented: $showConnection) { ConnectionView(model: model) }
  }
}

struct ConnectionView: View {
  @Bindable var model: AppModel
  @Environment(\.dismiss) private var dismiss
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
            Label("Pair with Desktop", systemImage: "qrcode")
          }
        }
        Section("Community") {
          LabeledContent(Aitaco.communityName, value: Aitaco.relayHost)
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
              let success = await model.add(
                url: Aitaco.relayURL, name: Aitaco.communityName, privateKey: key, authTag: authTag)
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
          .disabled(connecting || key.isEmpty)
        }
      }
      .navigationTitle("Connect to aitaco")
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }
    .presentationDetents([.large])
  }
}
