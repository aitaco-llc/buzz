import Observation
import UIKit
import UserNotifications

/// Observable notification state used by Settings and the APNs delegate.
@MainActor @Observable
final class NativePushStatus {
  static let shared = NativePushStatus()

  private(set) var authorization: UNAuthorizationStatus = .notDetermined
  private(set) var deviceToken: String?
  private(set) var registrationError: String?

  func refresh() async {
    let settings = await UNUserNotificationCenter.current().notificationSettings()
    authorization = settings.authorizationStatus
  }

  func request(application: UIApplication = .shared) async {
    do {
      let granted = try await UNUserNotificationCenter.current().requestAuthorization(
        options: [.alert, .badge, .sound])
      await refresh()
      if granted { application.registerForRemoteNotifications() }
    } catch {
      registrationError = error.localizedDescription
    }
  }

  func recordToken(_ data: Data) {
    deviceToken = data.map { String(format: "%02x", $0) }.joined()
    registrationError = nil
  }

  func recordError(_ error: Error) {
    registrationError = error.localizedDescription
  }

  var authorizationLabel: String {
    switch authorization {
    case .notDetermined: return "Not requested"
    case .denied: return "Denied"
    case .authorized: return "Allowed"
    case .provisional: return "Provisional"
    case .ephemeral: return "Temporary"
    @unknown default: return "Unknown"
    }
  }
}
