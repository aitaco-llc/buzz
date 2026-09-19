import BuzzCore
import SwiftUI

struct PairingView: View {
  @Bindable var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var invitation = ""
  @State private var code: String?
  @State private var confirmed = false
  @State private var status = ""
  @State private var failure: String?
  @State private var saved: Account?
  @State private var session: PairingSession?
  @State private var operation: Task<Void, Never>?
  @State private var generation = UUID()
  @State private var busy = false
  @State private var showScanner = false
  @State private var scannedInvitation: String?
  @State private var isVisible = false

  var body: some View {
    Form {
      if let saved {
        Section {
          Label("Identity saved on this iPad", systemImage: "checkmark.circle.fill")
          Text(status)
          Button("Open community") {
            Task {
              await model.open(saved)
              dismiss()
            }
          }.buttonStyle(.borderedProminent)
        }
      } else if let code {
        Section {
          Text("You are about to copy your Buzz identity from your desktop to this iPad.")
          Text(code).font(.largeTitle.monospacedDigit().bold())
            .accessibilityLabel("Pairing code: " + code.map(String.init).joined(separator: ", "))
            .accessibilityIdentifier("pairing-code")
          Text(
            "Compare all six digits with your desktop. Confirm on both devices only if they match.")
          Button("Codes match") { confirm() }
            .buttonStyle(.borderedProminent).disabled(confirmed)
          Button("Codes don’t match", role: .destructive) {
            stop()
            failure = "Pairing cancelled. Generate a new code on your desktop."
          }
        }
      } else {
        Section {
          Text(
            "On Buzz Desktop, open Settings → Mobile pairing. Scan its QR code or paste its pairing link below."
          )
          Button("Scan pairing QR code", systemImage: "qrcode.viewfinder") { showScanner = true }
            .disabled(busy)
          SecureField("nostrpair://…", text: $invitation)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .accessibilityLabel("Desktop pairing link")
          Button("Pair with desktop") { start() }
            .disabled(busy || invitation.isEmpty)
        }
      }
      if busy {
        Section { ProgressView(status.isEmpty ? "Connecting…" : status) }
      }
      if let failure {
        Section { Text(failure).foregroundStyle(.red).accessibilityIdentifier("pairing-error") }
      }
      if session != nil, saved == nil {
        Button("Cancel pairing", role: .cancel) { stop() }
      }
    }
    .navigationTitle("Pair with desktop")
    .sheet(
      isPresented: $showScanner,
      onDismiss: {
        if isVisible, let scanned = scannedInvitation {
          scannedInvitation = nil
          invitation = scanned
          start()
        }
        scannedInvitation = nil
      }
    ) {
      PairingScannerView { if isVisible { scannedInvitation = $0 } }
    }
    .onAppear { isVisible = true }
    .onDisappear {
      isVisible = false
      scannedInvitation = nil
      stop()
    }
  }

  private func start() {
    stop()
    let token = UUID()
    generation = token
    let uri = invitation.trimmingCharacters(in: .whitespacesAndNewlines)
    invitation = ""
    busy = true
    failure = nil
    operation = Task {
      var active: PairingSession?
      do {
        let next = try await Task.detached {
          try PairingSession(invitation: PairingInvitation(uri: uri))
        }.value
        active = next
        guard generation == token, !Task.isCancelled else {
          await next.cancel()
          return
        }
        session = next
        let expires = ContinuousClock.now.advanced(by: .seconds(120))
        let updates = try await next.start()
        for try await update in updates {
          guard generation == token, !Task.isCancelled else {
            await next.cancel()
            return
          }
          switch update {
          case .compareCode(let value):
            code = value
            busy = false
          case .waitingForPeer:
            status = "Waiting for your desktop to confirm…"
            busy = true
          case .credentials(let imported):
            status = "Checking community access…"
            busy = true
            // Authenticate to the actual community before persisting transferred credentials.
            let relay = HTTPRelay(community: imported.community, identity: imported.identity)
            _ = try await relay.query([
              EventFilter(kinds: [39002], tags: ["p": [imported.identity.pubkey]], limit: 1)
            ])
            try await next.validateImport()
            try Task.checkCancellation()
            guard generation == token else {
              await next.cancel()
              return
            }
            guard ContinuousClock.now < expires else { throw PairingError.expired }
            let account = try model.save(community: imported.community, identity: imported.identity)
            saved = account
            // From this point a transport failure must never undo a successfully saved identity.
            do {
              try await next.complete()
              status = "You can now open your community on this iPad."
            } catch {
              status =
                "Your identity is saved. The confirmation could not reach your desktop. You can still open your community."
            }
            busy = false
          }
        }
        if saved == nil, generation == token {
          failure = "Pairing ended. Generate a new code on your desktop."
          code = nil
          busy = false
        }
      } catch {
        if let active { await active.cancel() }
        guard generation == token, !Task.isCancelled else { return }
        failure =
          (error as? PairingError)?.localizedDescription
          ?? (error as? BuzzError)?.localizedDescription
          ?? "Could not connect to the pairing relay or community. Start again with a new pairing code."
        code = nil
        busy = false
      }
      if generation == token { session = nil }
    }
  }

  private func confirm() {
    guard let session, !confirmed else { return }
    confirmed = true
    let token = generation
    Task {
      do { try await session.confirm() } catch {
        guard generation == token else { return }
        stop()
        failure = "Pairing ended. Generate a new code on your desktop."
      }
    }
  }

  private func stop() {
    generation = UUID()
    operation?.cancel()
    operation = nil
    if let session { Task { await session.cancel() } }
    session = nil
    code = nil
    confirmed = false
    busy = false
    status = ""
  }
}
