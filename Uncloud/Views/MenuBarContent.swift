import AppKit
import SwiftUI

/// The menu bar item's menu: backup status and the most-used actions.
struct MenuBarContent: View {
    @Environment(ExportModel.self) private var model
    @Environment(AccountModel.self) private var account
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(statusText)
            .disabled(true)

        if let newPhotosText {
            Text(newPhotosText)
                .disabled(true)
        }

        // Only a failed payment or a plan that couldn't be checked adds a line (plan §1.4).
        if let line = AccountMenuItems.menuBarLine(summary: account.summary) {
            Text(line.text)
                .disabled(true)
            Button(line.buttonTitle) {
                performAccountAction(line.action)
            }
        }

        Button(NewPhotosTitle.exportByDate) {
            openWindow(id: "main")
            NSApp.activate()
            model.openExportByDate()
        }
        .disabled(!model.canOpenExportByDate)

        Button("Open Uncloud") {
            openWindow(id: "main")
            NSApp.activate()
        }

        Divider()

        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",")

        Button("Quit Uncloud") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func performAccountAction(_ action: AccountMenuAction) {
        switch action {
        case .checkAgain:
            Task { await account.refreshEntitlement(force: true) }
        default:
            Task { await account.openManageSubscription() }
        }
    }

    private var statusText: String {
        if model.isExporting {
            return "Exporting… \(Int(model.fractionComplete * 100))%"
        }
        if let pending = model.autoResume {
            return pending.isWaitingForDestination
                ? "Waiting for your backup drive"
                : "Resumes at \(ExportModel.resumeTimeText(pending.resumeAt))"
        }
        if model.offersResumeExport {
            return "Your last export didn’t finish"
        }
        if let date = model.lastBackupDate {
            return "Last export \(date.formatted(.relative(presentation: .named)))"
        }
        return "Not exported yet"
    }

    /// The new-photos line, shown only while there are new photos to export.
    private var newPhotosText: String? {
        guard let status = model.newPhotosStatus, status.count > 0 || status.isAtLeast else { return nil }
        return NewPhotosText.statusLine(status, now: .now)
    }
}
