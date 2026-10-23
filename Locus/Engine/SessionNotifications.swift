import Foundation
import UserNotifications
import Combine

/// Retains a cold-launch tap until the map and privacy gate can consume it.
@MainActor
final class SessionNotificationNavigation: ObservableObject {
    static let shared = SessionNotificationNavigation()
    @Published var pendingSessionDetails = false
}

final class SessionNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = SessionNotifications()
    static let reminderID = "locus.session.reminder"
    static let connectionID = "locus.session.connection"

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
            identifier: Self.connectionID, content: content, trigger: nil))
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
        // Connection errors already have an in-app alert. Reminders still need a banner.
        completionHandler(notification.request.identifier == Self.connectionID ? [] : [.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DeveloperLogStore.shared.record("notification_response", ["id": response.notification.request.identifier,
            "action": response.actionIdentifier])
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           [Self.reminderID, Self.connectionID].contains(response.notification.request.identifier) {
            Task { @MainActor in
                SessionNotificationNavigation.shared.pendingSessionDetails = true
            }
        }
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
