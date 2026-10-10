import AppKit
import UserNotifications

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// UNUserNotificationCenter chỉ dùng được khi chạy dạng .app có bundle id.
    private var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    func setup() {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func notify(title: String, subtitle: String? = nil, body: String, url: URL?) {
        guard isAvailable, UserDefaults.standard.bool(forKey: Prefs.notificationsEnabled) else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle { content.subtitle = subtitle }
        content.body = body
        if UserDefaults.standard.bool(forKey: Prefs.notificationSound) { content.sound = .default }
        if let url { content.userInfo = ["url": url.absoluteString] }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let s = response.notification.request.content.userInfo["url"] as? String, let url = URL(string: s) {
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
        completionHandler()
    }
}
