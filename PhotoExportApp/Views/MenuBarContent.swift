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

        Button("Open Photo Export") {
            openWindow(id: "main")
            NSApp.activate()
        }

        Divider()

        SettingsLink {
            Text("Settings…")
        }

        Button("Quit Photo Export") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var statusText: String {
        if model.isExporting {
            return "Exporting… \(Int(model.fractionComplete * 100))%"
        }
        if let date = model.lastBackupDate {
            return "Last backup: \(date.formatted(.relative(presentation: .named)))"
        }
        return "No backups yet"
    }
}
