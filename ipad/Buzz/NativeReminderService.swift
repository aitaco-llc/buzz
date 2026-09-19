import BuzzCore
import Foundation
import UserNotifications

@MainActor
enum NativeReminderService {
  static func schedule(
    event: Event, channel: Channel, workspace: Workspace, after interval: TimeInterval
  ) async throws {
    let content = UNMutableNotificationContent()
    content.title = "Buzz reminder"
    content.body = "Return to (workspace.channelName(channel))"
    content.sound = .default
    content.userInfo = [
      "buzz_push_navigation": [
        "event_id": event.id,
        "community_id": workspace.account.community.id,
        "channel_id": channel.id,
      ]
    ]
    content.threadIdentifier = channel.id
    let delay = max(1, interval)
    let request = UNNotificationRequest(
      identifier: "buzz.reminder.\(event.id).\(Int(Date().timeIntervalSince1970))",
      content: content,
      trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false))
    try await UNUserNotificationCenter.current().add(request)
  }
}
