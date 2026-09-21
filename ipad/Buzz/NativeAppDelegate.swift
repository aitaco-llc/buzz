import BuzzPushKit
import UIKit
import UserNotifications

final class NativeAppDelegate: NSObject, UIApplicationDelegate,
  @preconcurrency UNUserNotificationCenterDelegate
{
  static let navigationBuffer = BuzzPushNavigationBuffer()
  static let registrationBuffer = APNsRegistrationBuffer()

  static func takePendingNotificationTarget() -> BuzzPushNavigationTarget? {
    navigationBuffer.take()
  }

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    Task { @MainActor in
      await NativePushStatus.shared.request(application: application)
    }
    return true
  }

  func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    Self.registrationBuffer.recordToken(deviceToken)
    Task { @MainActor in NativePushStatus.shared.recordToken(deviceToken) }
  }

  func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    Self.registrationBuffer.recordError(error.localizedDescription)
    Task { @MainActor in NativePushStatus.shared.recordError(error) }
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    if let target = BuzzPushNavigationTarget.decodeIfPresent(
      from: response.notification.request.content.userInfo)
    {
      Self.navigationBuffer.record(target)
      NotificationCenter.default.post(name: .buzzPushNavigationReceived, object: target)
    }
    completionHandler()
  }

}

extension Notification.Name {
  static let buzzPushNavigationReceived = Notification.Name("buzz.push.navigation.received")
}
