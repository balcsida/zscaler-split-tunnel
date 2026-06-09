import Foundation
@preconcurrency import UserNotifications

enum RecoveryNotificationService {
    static func notifyStaleRoutesRepaired(_ cleanup: HelperStatus.RouteCleanupStatus) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                postStaleRoutesRepaired(cleanup, using: center)
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    guard granted else { return }
                    postStaleRoutesRepaired(cleanup, using: center)
                }
            case .denied:
                break
            @unknown default:
                break
            }
        }
    }

    private static func postStaleRoutesRepaired(
        _ cleanup: HelperStatus.RouteCleanupStatus,
        using center: UNUserNotificationCenter
    ) {
        let content = UNMutableNotificationContent()
        content.title = "Network routes repaired"
        content.body = "Deleted \(cleanup.removedCount) stale route(s) via an old gateway. Fully quit and reopen Safari if existing tabs are still loading."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "stale-route-cleanup-\(cleanup.date.timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        center.add(request)
    }
}
