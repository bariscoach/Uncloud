import AppKit
import SwiftUI

/// The Settings window (⌘,): automatic backup and general options. The source and account live in the sidebar.
struct SettingsView: View {
    @Environment(ExportModel.self) private var model
    @Environment(AutoBackupSettings.self) private var settings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Automatic Backup") {
                Toggle("Export when the backup drive is connected", isOn: $settings.backUpWhenDriveConnects)
                    .disabled(model.destination == nil)
                Toggle("Export once a day", isOn: $settings.backUpDaily)
                    .disabled(model.destination == nil)

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

            NewPhotosReminderSection(reminder: settings.newPhotosReminder)

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

    private var statusText: String {
        let last = model.lastBackupDate?.formatted(.relative(presentation: .named)) ?? "never"
        return "Last export: \(last). While automatic backups are on, Uncloud keeps running in the menu bar."
    }
}
