import SwiftUI

/// Menu bar commands. The app menu (About, Quit) comes from the system.
///
/// Signed out (plan B.2), only the system items and Help's diagnostic logs remain. Each group below stays in place
/// so the system's own items for it are still replaced, and only its contents are gated.
struct ExportCommands: Commands {
    let model: ExportModel
    let tools: BackupTools
    let account: AccountModel
    /// Set only while the library grid has keyboard focus, so text fields keep their own shortcuts.
    @FocusedValue(\.gridSelection) private var grid
    /// Published by Delete from iCloud while its grid has focus. Nil elsewhere, which disables Delete and Recover.
    @FocusedValue(\.cleanupCommand) private var cleanup
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // Uncloud ▸ Account Settings…, the plan action and Sign Out of Uncloud…, after Settings… (plan §1.3).
        CommandGroup(after: .appSettings) {
            ForEach(accountMenuItems) { item in
                Button(item.title) {
                    perform(item.action)
                }
                .disabled(!item.isEnabled)
            }
        }

        if account.showsAppMenus {
            // View › Show/Hide Sidebar comes from the system, so it's offered from the menu bar as well.
            SidebarCommands()
        }

        CommandGroup(replacing: .newItem) {
            if account.showsAppMenus {
                Button("Choose Backup Folder…") {
                    model.beginChoosingDestination()
                }
                .keyboardShortcut("o")
                .disabled(model.isExporting)

                Button("Show Backup Folder in Finder") {
                    model.revealDestination()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(model.destination == nil)

                Divider()

                Menu("Photos From") {
                    Picker("Photos From", selection: sourceSelection) {
                        ForEach(LibrarySource.allCases) { source in
                            Text(source.title).tag(source)
                        }
                    }
                    .pickerStyle(.inline)
                }
                .disabled(model.isExporting)

                // One slot for both. Each opens the same confirmation or sheet as the sidebar footer.
                if model.source == .iCloud {
                    Divider()
                    if model.iCloudAppleID != nil {
                        Button("Sign Out of iCloud…") {
                            model.isConfirmingICloudSignOut = true
                        }
                        .disabled(!model.canSignOutICloud)
                    } else {
                        Button("Sign In to iCloud…") {
                            model.isShowingICloudSignIn = true
                        }
                    }
                }
            }
        }

        CommandGroup(before: .sidebar) {
            if account.showsAppMenus {
                // Same order as the sidebar, with ⌘1–⌘5.
                ForEach(ExportModel.Pane.allCases, id: \.self) { pane in
                    Button(pane.title) {
                        model.pane = pane
                    }
                    .keyboardShortcut(KeyEquivalent(pane.shortcut))
                }

                Divider()

                // The same setting as the Browse Backup toolbar. Only Browse Backup has dates and photos to sort.
                Menu("Sort") {
                    Picker("Sort", selection: browseSortSelection) {
                        ForEach(BrowseSortOrder.allCases) { order in
                            Text(order.title).tag(order)
                        }
                    }
                    .pickerStyle(.inline)
                }
                .disabled(model.pane != .browse || !account.allows(.browseBackup))

                Divider()
            }
        }

        if account.showsAppMenus {
            CommandMenu("Backup") {
                if model.destination == nil {
                    // No folder yet: File already offers Choose Backup Folder, so this stays a disabled Export All Photos
                    // rather than a second folder item.
                    Button("Export All Photos") {}
                        .keyboardShortcut("r", modifiers: [.command, .option])
                        .disabled(true)
                } else {
                    // The same title and action as the primary button: the selection, or a folder first. Its ellipsis
                    // comes from the title when it opens the Export Photos by Date sheet.
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
                }

                Divider()

                Button(model.phase == .paused ? "Resume Export" : "Pause Export") {
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

                Button("Check Backup Folder") {
                    model.checkDrive(full: true)
                }
                .disabled(!model.canCheckDrive)

                // Every photo in the iCloud library, not just the new ones a routine export checks. Takes longer.
                if model.source == .iCloud {
                    Button("Check Whole Library") {
                        model.checkWholeLibrary()
                    }
                    .disabled(!model.canExportAll || model.destination == nil)
                }

                Button("Verify Backup…") {
                    account.require(.verifyBackup) { tools.showVerify() }
                }
                .disabled(!tools.canOpenVerify)

                Button("Find Duplicates…") {
                    account.require(.findDuplicates) { tools.showDuplicates() }
                }
                .disabled(!tools.canOpenDuplicates)

                // Always listed. Only Photos on This Mac can free up space, so it is disabled for iCloud.
                Button("Free Up Space…") {
                    account.require(.freeUpSpace) { tools.showFreeUpSpace() }
                }
                .disabled(!tools.canOpenFreeUpSpace)
            }
        }

        CommandGroup(after: .pasteboard) {
            if account.showsAppMenus {
                // Select All (⌘A) is the system item, which the grid answers while it has focus.
                Button("Deselect All") {
                    grid?.deselectAll()
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(grid == nil)

                Divider()

                // Only opens the typed confirmation of the focused pane. Return never triggers it.
                Button(cleanup?.title ?? "Delete from iCloud…") {
                    cleanup?.perform()
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!(cleanup?.isEnabled ?? false))
            }
        }

        CommandGroup(replacing: .help) {
            if account.showsAppMenus {
                Button("Getting Started") {
                    model.introSheet = .gettingStarted
                }
            }

            // Support and the website stay available when signed out, so people can ask for help before they sign in.
            Button("Uncloud Website") {
                NSWorkspace.shared.open(AccountLinks.website)
            }

            Button("Contact Support…") {
                NSWorkspace.shared.open(AccountLinks.support)
            }

            Divider()

            // Redacted transcripts of the last iCloud helper runs; they stay on this Mac.
            Button("Show Diagnostic Logs in Finder") {
                HelperTranscript.revealFolder()
            }
        }
    }

    /// The account items for the app menu, from the same summary the popover shows.
    private var accountMenuItems: [AccountMenuItem] {
        AccountMenuItems.appMenu(summary: account.summary, isExporting: model.isExporting || model.isEngineRunning)
    }

    /// Opens the main window first when an action needs it, so its sheet or dialog is visible.
    private func perform(_ action: AccountMenuAction) {
        switch action {
        case .accountSettings:
            UserDefaults.standard.set(SettingsTab.account.rawValue, forKey: SettingsTab.storageKey)
            openSettings()
            NSApp.activate()
        case .getPlus:
            openWindow(id: "main")
            NSApp.activate()
            account.showPaywall()
        case .manageSubscription, .updatePaymentMethod:
            Task { await account.openManageSubscription() }
        case .checkAgain:
            Task { await account.refreshEntitlement(force: true) }
        case .signOut:
            openWindow(id: "main")
            NSApp.activate()
            account.isConfirmingSignOut = true
        }
    }

    /// Source changes are disabled while an export runs, so the picker can't revert under the user.
    private var browseSortSelection: Binding<BrowseSortOrder> {
        Binding(
            get: { tools.browse.sortOrder },
            set: { tools.browse.sortOrder = $0 }
        )
    }

    private var sourceSelection: Binding<LibrarySource> {
        Binding(
            get: { model.source },
            set: { model.source = $0 }
        )
    }
}
