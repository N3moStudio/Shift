import Foundation
import UserNotifications

final class SessionNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = SessionNotifications()
    static let reminderID = "locus.session.reminder"

    func install() { UNUserNotificationCenter.current().delegate = self }

    func requestPermission() async -> Bool {
        let allowed = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        DeveloperLogStore.shared.record("notification_permission_result", ["allowed": String(allowed)])
        return allowed
    }

    func warn(title: String, message: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        content.sound = .default
        addLogged(UNNotificationRequest(
            identifier: "locus.session.connection", content: content, trigger: nil))
    }

    func scheduleReminder(minutes: Int, startedAt: Date) {
        cancelReminder()
        guard minutes > 0 else { return }
        let remaining = startedAt.addingTimeInterval(Double(minutes * 60)).timeIntervalSinceNow
        // Changing settings after the deadline shouldn't generate repeated alerts.
        guard remaining > 1 else { return }
        let content = UNMutableNotificationContent()
        content.title = "Check your Shift session"
        content.body = "Your session reminder is due. Open Shift to review its current status."
        content.sound = .default
        addLogged(UNNotificationRequest(
            identifier: Self.reminderID, content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: remaining, repeats: false)))
    }

    func cancelReminder() {
        DeveloperLogStore.shared.record("reminder_cancel_requested")
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.reminderID])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        DeveloperLogStore.shared.record("notification_foreground_delivery", ["id": notification.request.identifier,
            "title": notification.request.content.title, "body": notification.request.content.body])
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DeveloperLogStore.shared.record("notification_response", ["id": response.notification.request.identifier,
            "action": response.actionIdentifier])
        completionHandler()
    }

    private func addLogged(_ request: UNNotificationRequest) {
        DeveloperLogStore.shared.record("notification_requested", ["id": request.identifier,
            "title": request.content.title, "body": request.content.body, "scheduled": String(request.trigger != nil)])
        UNUserNotificationCenter.current().add(request) { error in
            var details = ["id": request.identifier, "result": error == nil ? "accepted_by_iOS_not_proof_seen" : "failed"]
            if let error = error as NSError? { details["error_domain"] = error.domain; details["error_code"] = String(error.code) }
            DeveloperLogStore.shared.record("notification_request_result", details)
        }
    }
}
