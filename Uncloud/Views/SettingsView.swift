import AppKit
import SwiftUI

/// The tabs of the Settings window. `off` builds have no tabs: they keep the single General form (plan §2.1).
enum SettingsTab: String, CaseIterable {
    case general, account

    /// The selected tab, remembered across launches and set by Uncloud ▸ Account Settings….
    static let storageKey = "uncloudSettingsTab"

    static func showsTabs(for mode: AccountMode) -> Bool {
        mode != .off
    }
}

/// The Settings window (⌘,): General, and Account when accounts are on.
struct SettingsView: View {
    @Environment(ExportModel.self) private var model
    @Environment(AccountModel.self) private var account
    @AppStorage(SettingsTab.storageKey) private var tabRaw = SettingsTab.general.rawValue

    var body: some View {
        if SettingsTab.showsTabs(for: account.mode) {
            TabView(selection: tabSelection) {
                GeneralSettingsForm()
                    .tabItem { Label("General", systemImage: "gearshape") }
                    .tag(SettingsTab.general)

                AccountSettingsForm(isExporting: model.isExporting || model.isEngineRunning)
                    .tabItem { Label("Account", systemImage: "person.crop.circle") }
                    .tag(SettingsTab.account)
            }
            .frame(width: 460)
        } else {
            GeneralSettingsForm()
        }
    }

    private var tabSelection: Binding<SettingsTab> {
        Binding(
            get: { SettingsTab(rawValue: tabRaw) ?? .general },
            set: { tabRaw = $0.rawValue }
        )
    }
}

/// The General tab: automatic backup, new photos and general options. Its content is the old Settings form.
struct GeneralSettingsForm: View {
    @Environment(ExportModel.self) private var model
    @Environment(AutoBackupSettings.self) private var settings
    @Environment(AccountModel.self) private var account
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var settings = settings
        let automatic = account.allows(.automaticBackups)

        Form {
            Section("Automatic Backup") {
                // Locked for free accounts: shown off and disabled. The saved values stay as they were (plan C.3).
                Toggle("Export when the backup drive is connected", isOn: lockable($settings.backUpWhenDriveConnects, allowed: automatic))
                    .disabled(model.destination == nil || !automatic)
                Toggle("Export once a day", isOn: lockable($settings.backUpDaily, allowed: automatic))
                    .disabled(model.destination == nil || !automatic)

                if !automatic {
                    LockedSettingRow(text: "Automatic backups are part of Uncloud Plus.") {
                        openPaywall(.automaticBackups)
                    }
                }

                LabeledContent("Backup folder") {
                    HStack {
                        Text(model.destination?.displayName ?? "None")
                            .foregroundStyle(model.destination == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button(model.destination == nil ? "Choose…" : "Change…") {
                            // The folder picker belongs to the main window, which may be closed.
                            openWindow(id: "main")
                            NSApp.activate()
                            model.beginChoosingDestination()
                        }
                        .disabled(model.isExporting)
                    }
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

            Section("General") {
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
        let last = model.lastBackupDate?.formatted(.relative(presentation: .named)) ?? "never"
        return "Last export: \(last). While automatic backups are on, Uncloud keeps running in the menu bar."
    }
}
