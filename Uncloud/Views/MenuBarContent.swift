import AppKit
import SwiftUI

/// The menu bar item's menu: backup status and the most-used actions.
struct MenuBarContent: View {
    @Environment(ExportModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(statusText)
            .disabled(true)

        Button("Export Now") {
            model.backUpAutomatically(reason: "from the menu bar")
        }
        .disabled(!model.canBackUpAutomatically)

        Button("Open Uncloud") {
            openWindow(id: "main")
            NSApp.activate()
        }

        Divider()

        SettingsLink {
            Text("Settings…")
        }

        Button("Quit Uncloud") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var statusText: String {
        if model.isExporting {
            return "Exporting… \(Int(model.fractionComplete * 100))%"
        }
        if let pending = model.autoResume {
            return pending.isWaitingForDestination
                ? "Waiting for the backup drive to resume"
                : "Resuming at \(ExportModel.resumeTimeText(pending.resumeAt))"
        }
        if let date = model.lastBackupDate {
            return "Last backup: \(date.formatted(.relative(presentation: .named)))"
        }
        return "No backups yet"
    }
}
