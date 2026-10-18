import SwiftUI

/// Menu bar commands. The app menu (About, Quit) comes from the system.
struct ExportCommands: Commands {
    let model: ExportModel
    let tools: BackupTools
    /// Set only while the library grid has keyboard focus, so text fields keep their own shortcuts.
    @FocusedValue(\.gridSelection) private var grid

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Choose Export Folder…") {
                model.beginChoosingDestination()
            }
            .keyboardShortcut("o")
            .disabled(model.isExporting)

            Divider()

            // Opens the same confirmation as the sidebar footer.
            Button("Sign Out of iCloud…") {
                model.isConfirmingICloudSignOut = true
            }
            .disabled(!model.canSignOutICloud)
        }

        CommandGroup(before: .sidebar) {
            Button("Library") {
                model.pane = .library
            }
            .keyboardShortcut("1")

            Button("Backup") {
                model.pane = .backup
            }
            .keyboardShortcut("2")

            Divider()
        }

        CommandMenu("Export") {
            // The same title and action as the primary button: the selection, or a folder first.
            Button(model.primaryExportTitle(total: model.browser?.count)) {
                model.performPrimaryAction()
            }
            .keyboardShortcut("r")
            .disabled(!model.primaryExportEnabled(total: model.browser?.count))

            // Exports the whole library and ignores the saved selection, which stays as it was.
            Button("Export All Photos") {
                model.exportAll()
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(!model.canExportAll)

            Divider()

            Button(model.phase == .paused ? "Resume" : "Pause") {
                if model.phase == .paused {
                    model.startOrResume()
                } else {
                    model.pause()
                }
            }
            // No shortcut: ⌘P is Print, and macOS apps don't assign a standard one to Pause.
            .disabled(!(model.canPause || model.phase == .paused))

            Button("Cancel Export") {
                model.cancel()
            }
            .keyboardShortcut(".")
            .disabled(!model.canCancel)

            Divider()

            Button("Verify Backup…") {
                tools.showVerify()
            }
            .disabled(!tools.canOpenVerify)

            Button("Find Duplicates…") {
                tools.showDuplicates()
            }
            .disabled(!tools.canOpenDuplicates)

            // Only the Photos library can free up space; the item is hidden for iCloud.
            if model.source == .photosLibrary {
                Button("Free Up Space…") {
                    tools.showFreeUpSpace()
                }
                .disabled(!tools.canOpenFreeUpSpace)
            }
        }

        CommandGroup(after: .pasteboard) {
            // Select All (⌘A) is the system item, which the grid answers while it has focus.
            Button("Deselect All") {
                grid?.deselectAll()
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(grid == nil)
        }

        CommandGroup(replacing: .help) {
            Button("Getting Started…") {
                model.introSheet = .gettingStarted
            }

            Divider()

            // Redacted transcripts of the last iCloud helper runs; they stay on this Mac.
            Button("Show Diagnostic Logs") {
                HelperTranscript.revealFolder()
            }
        }
    }
}
