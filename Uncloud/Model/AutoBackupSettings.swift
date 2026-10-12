import Observation
import ServiceManagement
import UserNotifications

/// Automatic backup preferences, saved in UserDefaults.
@MainActor
@Observable
final class AutoBackupSettings {
    private nonisolated static let connectKey = "autoBackupOnConnect"
    private nonisolated static let dailyKey = "autoBackupDaily"
    private nonisolated static let menuBarKey = "showInMenuBar"
    private nonisolated static let notificationsKey = "didRequestNotificationAuthorization"

    var backUpWhenDriveConnects: Bool {
        didSet {
            UserDefaults.standard.set(backUpWhenDriveConnects, forKey: Self.connectKey)
            requestNotificationsIfNeeded()
        }
    }

    var backUpDaily: Bool {
        didSet {
            UserDefaults.standard.set(backUpDaily, forKey: Self.dailyKey)
            requestNotificationsIfNeeded()
        }
    }

    var showInMenuBar: Bool {
        didSet { UserDefaults.standard.set(showInMenuBar, forKey: Self.menuBarKey) }
    }

    /// Whether the app should stay running after its window closes.
    var isEnabled: Bool {
        backUpWhenDriveConnects || backUpDaily
    }

    /// Mirrors the system's login item state. Changing it registers or unregisters the app.
    var openAtLogin = false {
        didSet {
            guard !isSyncingLoginItem, openAtLogin != oldValue else { return }
            applyLoginItem()
        }
    }

    private(set) var loginItemError: String?

    @ObservationIgnored private var isSyncingLoginItem = false

    /// Read from the app delegate, which runs outside the main actor.
    nonisolated static var isEnabledInDefaults: Bool {
        UserDefaults.standard.bool(forKey: connectKey) || UserDefaults.standard.bool(forKey: dailyKey)
    }

    init() {
        let defaults = UserDefaults.standard
        backUpWhenDriveConnects = defaults.bool(forKey: Self.connectKey)
        backUpDaily = defaults.bool(forKey: Self.dailyKey)
        showInMenuBar = defaults.object(forKey: Self.menuBarKey) == nil ? true : defaults.bool(forKey: Self.menuBarKey)
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Asks for notification permission the first time automatic backup is switched on.
    private func requestNotificationsIfNeeded() {
        guard isEnabled, !UserDefaults.standard.bool(forKey: Self.notificationsKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.notificationsKey)
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
    }

    private func applyLoginItem() {
        do {
            if openAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
        }

        // Show what the system actually did, which may differ from the request.
        isSyncingLoginItem = true
        openAtLogin = SMAppService.mainApp.status == .enabled
        isSyncingLoginItem = false
    }
}
