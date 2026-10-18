import Observation
import UserNotifications

/// The new-photos reminder preferences, saved in UserDefaults. On by default; the notification itself appears only
/// once the user allows notifications.
@MainActor
@Observable
final class NewPhotosReminderSettings {
    private nonisolated static let enabledKey = "newPhotosReminder"
    private nonisolated static let frequencyKey = "newPhotosReminderFrequency"
    private nonisolated static let lastReminderKey = "newPhotosLastReminder"

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled { requestNotifications() }
        }
    }

    var frequency: NewPhotosReminderFrequency {
        didSet { UserDefaults.standard.set(frequency.rawValue, forKey: Self.frequencyKey) }
    }

    /// When the last reminder was posted. Reminders wait at least one frequency after it.
    private(set) var lastReminder: Date?

    init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.object(forKey: Self.enabledKey) == nil ? true : defaults.bool(forKey: Self.enabledKey)
        frequency = defaults.string(forKey: Self.frequencyKey).flatMap(NewPhotosReminderFrequency.init) ?? .weekly
        lastReminder = defaults.object(forKey: Self.lastReminderKey) as? Date
    }

    func recordReminder(at date: Date) {
        lastReminder = date
        UserDefaults.standard.set(date, forKey: Self.lastReminderKey)
    }

    /// Asks for notification permission the first time the reminder is turned on, as automatic backup does.
    private func requestNotifications() {
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
    }
}
