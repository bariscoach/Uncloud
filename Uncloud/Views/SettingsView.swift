import AppKit
import SwiftUI

/// The tabs of the Settings window. General and Backups always show; Account only when accounts are on (plan §3.5).
enum SettingsTab: String, CaseIterable {
    case general, backups, account

    /// The selected tab, remembered across launches and set by Uncloud ▸ Account Settings….
    static let storageKey = "uncloudSettingsTab"

    static func showsTabs(for mode: AccountMode) -> Bool {
        true
    }
}

/// The Settings window (⌘,): General, Backups, and Account when accounts are on.
struct SettingsView: View {
    @Environment(ExportModel.self) private var model
    @Environment(AccountModel.self) private var account
    @AppStorage(SettingsTab.storageKey) private var tabRaw = SettingsTab.general.rawValue

    var body: some View {
        TabView(selection: tabSelection) {
            GeneralSettingsForm()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)

            BackupSettingsForm()
                .tabItem { Label("Backups", systemImage: "externaldrive") }
                .tag(SettingsTab.backups)

            if account.mode != .off {
                AccountSettingsForm(isExporting: model.isExporting || model.isEngineRunning)
                    .tabItem { Label("Account", systemImage: "person.crop.circle") }
                    .tag(SettingsTab.account)
            }
        }
        .frame(width: 460)
    }

    private var tabSelection: Binding<SettingsTab> {
        Binding(
            get: {
                // Off builds have no Account tab, so a remembered Account selection falls back to General.
                let tab = SettingsTab(rawValue: tabRaw) ?? .general
                return tab == .account && account.mode == .off ? .general : tab
            },
            set: { tabRaw = $0.rawValue }
        )
    }
}

/// The General tab: login and menu bar options.
struct GeneralSettingsForm: View {
    @Environment(AutoBackupSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                Toggle("Open at login", isOn: $settings.openAtLogin)
                if let error = settings.loginItemError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Toggle("Show in menu bar", isOn: $settings.showInMenuBar)
                Text("Shown while automatic backups are on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }
}

/// The Backups tab: automatic backups, the backup folder caption, and the new photo reminders.
struct BackupSettingsForm: View {
    @Environment(ExportModel.self) private var model
    @Environment(AutoBackupSettings.self) private var settings
    @Environment(AccountModel.self) private var account
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var settings = settings
        let automatic = account.allows(.automaticBackups)

        Form {
            Section("Automatic Backups") {
                // Locked for free accounts: shown off and disabled. The saved values stay as they were (plan C.3).
                Toggle("Export when the backup drive connects", isOn: lockable($settings.backUpWhenDriveConnects, allowed: automatic))
                    .disabled(model.destination == nil || !automatic)
                Toggle("Export once a day", isOn: lockable($settings.backUpDaily, allowed: automatic))
                    .disabled(model.destination == nil || !automatic)

                if !automatic {
                    LockedSettingRow(text: "Automatic backups are part of Uncloud Plus.") {
                        openPaywall(.automaticBackups)
                    }
                }

                // The folder itself is changed in the Backup pane, so this only says where exports go.
                if let destination = model.destination {
                    Text("Exports to “\(destination.displayName)”.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Choose a backup folder in Uncloud first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Choose Backup Folder…") {
                        // The folder picker belongs to the main window, which may be closed.
                        openWindow(id: "main")
                        NSApp.activate()
                        model.beginChoosingDestination()
                    }
                    .buttonStyle(.link)
                    .disabled(model.isExporting)
                }

                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            NewPhotosReminderSection(
                reminder: settings.newPhotosReminder,
                isAllowed: account.allows(.newPhotos),
                onGetPlus: { openPaywall(.newPhotos) }
            )
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }

    /// A toggle's value while the feature is allowed; shown off otherwise. Writes go through only when allowed.
    private func lockable(_ binding: Binding<Bool>, allowed: Bool) -> Binding<Bool> {
        Binding(
            get: { allowed && binding.wrappedValue },
            set: { value in
                guard allowed else { return }
                binding.wrappedValue = value
            }
        )
    }

    /// Opens the paywall in the main window, which is where it is presented, and brings that window forward.
    private func openPaywall(_ feature: PaidFeature) {
        openWindow(id: "main")
        NSApp.activate()
        account.require(feature) {}
    }

    private var statusText: String {
        let note = "While automatic backups are on, Uncloud keeps running in the menu bar."
        guard let date = model.lastBackupDate else {
            return "Not exported yet. \(note)"
        }
        return "Last export \(date.formatted(.relative(presentation: .named))). \(note)"
    }
}
