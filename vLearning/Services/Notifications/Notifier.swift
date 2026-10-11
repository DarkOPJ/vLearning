import Foundation
import UserNotifications

/// Local notifications for finished background work. Shown as banners even while the app is open.
final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {

    static let shared = Notifier()

    func configure() {
        UNUserNotificationCenter.current().delegate = self
    }

    func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // Show banners while the app is in the foreground too.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}
