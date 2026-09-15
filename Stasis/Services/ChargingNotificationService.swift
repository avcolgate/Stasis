import Defaults
import Foundation
import UserNotifications
import os.log

@MainActor
final class ChargingNotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ChargingNotificationService()
    private var tracker = ChargingTransitionTracker()
    private let logger = Logger(subsystem: "com.srimanachanta.stasis", category: "Notifications")

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            logger.info("Notification authorization granted: \(granted)")
        } catch {
            logger.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func observe(_ metrics: BatteryMetrics) {
        let enabled = !Defaults[.disableNotifications] && Defaults[.showChargingStatusChangedNotification]
        guard let charging = tracker.update(isCharging: metrics.isCharging, valid: metrics.hasPowerSourceData,
                                            notificationsEnabled: enabled) else { return }
        let title = charging ? String(localized: "Charging Resumed") : String(localized: "Charging Paused")
        let body = charging
            ? "Battery is charging at \(metrics.batteryPercentage)%."
            : "Battery stopped charging at \(metrics.batteryPercentage)%."
        Task {
            do { try await send(title: title, body: body) }
            catch { logger.error("Charging notification failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    func sendTestNotification() async throws {
        guard !Defaults[.disableNotifications] else { throw NotificationError.disabledInApp }
        let center = UNUserNotificationCenter.current()
        guard try await center.requestAuthorization(options: [.alert, .sound]) else {
            throw NotificationError.permissionDenied
        }
        try await send(title: "Stasis Test", body: "Notifications are working. Stasis will notify you when battery charging starts or stops.")
    }

    private func send(title: String, body: String) async throws {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            throw NotificationError.permissionDenied
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let identifier = UUID().uuidString
        try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        logger.info("Notification accepted: \(title, privacy: .public), id=\(identifier, privacy: .public)")
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

private enum NotificationError: LocalizedError {
    case disabledInApp
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .disabledInApp: "Enable notifications in Stasis first."
        case .permissionDenied: "Allow Stasis notifications in System Settings → Notifications."
        }
    }
}
