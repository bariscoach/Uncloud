# Remove Tools and its features (owner request, 2026-10-23)

Owner: "remove tools and related features"

Build this automatically, then bump the version and make the DMG. The owner approved building without a further
round.

## What goes

1. **The Tools sidebar pane.** Remove `ExportModel.Pane.tools` and `Uncloud/Views/ToolsPane.swift`. The sidebar
   becomes:
   - Cloud Library
   - Browse Backup
   - Delete from iCloud
   - the break
   - Export Settings

   Move the break so it sits before Export Settings. ⌘1–⌘4 follow `allCases`.
2. **Verify Backup.** Remove:
   - `VerifyBackupSheet.swift`
   - `BackupVerification.swift`
   - `BackupVerifier.swift`
   - `QuickVerifier.swift`
   - `VerifyCheckpoint.swift`
   - `SequentialFileReader.swift`
   - the parts of `CheckDriveViews.swift` used only by Verify

   Before deleting each file, check it isn't used by export, the drive check before an export, Browse or Delete from
   iCloud. `grep` every type. Keep anything those still use.
3. **Find Duplicates.** Remove:
   - `FindDuplicatesSheet.swift`
   - `DuplicateCleanup.swift`
   - `DuplicateLibrary.swift`
   - `DuplicateFinder.swift`, unless something outside the tools uses it
   - the review-in-Delete-from-iCloud hook in `CleanupView.swift` / `ICloudCleanup`, if it exists only for Find
     Duplicates
4. **Free Up Space** (Photos on This Mac). Remove `FreeUpSpaceSheet.swift` and its model code.
5. **`BackupTools`.** Remove the verify, duplicates and free-up-space state, sheets and `can…`/`show…` API.
   - Keep `browse`, which Browse Backup uses.
   - If `BackupTools` only holds `browse` afterwards, it can stay as a thin holder; don't churn call sites.
   - Remove `BackupToolSheets.swift`, or whatever part of it only presents these sheets.
6. **Menu commands** (`ExportCommands.swift`): remove Verify Backup…, Find Duplicates… and Free Up Space….
7. **Paid features** (`AccountTypes.swift` `PaidFeature`):
   - Remove `findDuplicates`, `verifyBackup` and `freeUpSpace`, along with their titles, symbols and descriptions.
   - Update every place that lists paid features: the paywall, `WelcomeView`, `BenefitsCarousel` and the account
     summary.
   - Also update any copy that names these tools, such as "Verify, Find Duplicates…".
   - Check `MainWindow.toolsLocked` and remove it.
   - The server and Stripe only know a plan, not features. Don't change the server.
8. **Other copy and help text** that mentions Tools, Verify, Find Duplicates or Free Up Space. `grep -ri` for:
   - "Tools"
   - "Verify Backup"
   - "Find Duplicates"
   - "Free Up Space"
   - "duplicate"

   Leave real uses like "toolbar" alone.
9. **Tests.**
   - Delete the tests of the removed code:
     - `ToolsPaneContentTests`
     - `DuplicateFinderTests`
     - `DuplicateSizesTests`
     - `DuplicateSnapshotTests`
     - `DuplicateLibraryTests`
     - `DuplicateWordingTests`
     - the Verify, QuickVerifier and checkpoint tests
     - the Free Up Space tests
   - Update the tests that refer to them: `EntitlementGatingTests`, `AccountModelTests`, the snapshot suites,
     `ExportPaneRenameTests` (pane order and shortcuts) and `BackupToolsBrowseWiringTests`.
   - All remaining tests must pass.
10. Run `xcodegen generate` after deleting files.

## What stays

- Export, including the drive check before an export: the bulk lister, `FlatFolderCheck` and the manifest.
- Browse Backup.
- Delete from iCloud, including its selection bar and toolbar.
- Export Settings and Folder Organization.
- The account.
- The `Reorganize*` mover files, which aren't wired to the UI. Leave them.
- `UserDefaults` keys from removed features. Leave them on disk and add no migration.

## Constraints

- Swift 6 and XcodeGen.
- Run tests with `scratchpad/locked-test.sh` and read the results with
  `xcrun xcresulttool get test-results summary`.
- Don't touch:
  - the running app
  - `~/Library/Containers/com.example.Uncloud`
  - `/Volumes`
  - the Keychain
