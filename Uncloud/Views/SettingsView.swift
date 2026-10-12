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
                Toggle("Back up when the destination drive is connected", isOn: $settings.backUpWhenDriveConnects)
                    .disabled(model.destination == nil)
                Toggle("Back up once a day", isOn: $settings.backUpDaily)
                    .disabled(model.destination == nil)

                LabeledContent("Save To") {
                    HStack {
                        Text(model.destination?.displayName ?? "No folder chosen")
                            .foregroundStyle(model.destination == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button(model.destination == nil ? "Choose Folder…" : "Change Folder…") {
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

            Section("General") {
                Toggle("Open at login", isOn: $settings.openAtLogin)
                if let error = settings.loginItemError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Toggle("Show in menu bar", isOn: $settings.showInMenuBar)
                Text("The menu bar item appears while automatic backup is on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }

    private var statusText: String {
        let last = model.lastBackupDate?.formatted(.relative(presentation: .named)) ?? "none yet"
        return "Last backup: \(last). While automatic backup is on, Uncloud keeps running in the menu bar after you close its window."
    }
}
