# Export Photos by Date can always be reached (owner report, 2026-10-23)

Owner: "the date picker is gone from cloud library and export settings"

## Why it disappears

The date sheet (`ExportRangeSheet`) only opens through the primary button. The primary button's title is "Export
Photos by Date…" only when `NewPhotosTitle.offersNewOnly` holds. That requires all of these:

- not paused
- **no interrupted run**
- a folder is chosen
- the selection is everything
- there is a new-photos status
- there are backed-up photos

The owner's backup has an interrupted run, so the primary button turns into Resume or Export All, and the date picker
is gone. The menu bar item is the only other way to reach it.

## Change

Give Export Photos by Date its own control that is always there, separate from the primary button.

1. **Model.** Add `ExportModel.canExportByDate`, true when:
   - a destination is set
   - nothing is exporting
   - not paused
   - `canStart` holds

   Add `openExportByDate()`, which sets `isChoosingExportSince = true` when `canExportByDate`, and otherwise picks a
   folder first when there's none. Test both.
2. **Cloud Library toolbar** (`ExportView.swift`, `ExportToolbar`). Add a button before the primary group:
   - label "By Date…" with `calendar` symbol, `.labelStyle(.titleAndIcon)`
   - help "Export the photos taken between two dates"
   - accessibility label "Export Photos by Date"

   Show it whenever the export progress ring isn't showing, and disable it when `!canExportByDate`. While a folder
   isn't chosen, still show it; it calls `openExportByDate()`, which asks for a folder.
3. **The primary button no longer opens the date sheet.**
   - `NewPhotosTitle.primary` returns the fallback (or "Choose Folder…") instead of `exportByDate`.
   - `performPrimaryAction` no longer branches on `opensExportSince`.
   - Remove `opensExportSince` if nothing else uses it.
   - Keep `offersNewOnly` if the subtitle (`notBackedUpSummary`) or help still needs it.
   - Update the `NewPhotos` / title tests to match.
4. **Export Settings › General** (`BackupPane.swift`). Add a clear row in the top section, near the backup status or
   the export button:
   - title "Export Photos by Date"
   - subtitle "Pick a start and end date. Uncloud exports the photos taken in between and skips the ones already
     backed up."
   - trailing button "Choose Dates…", which calls `openExportByDate()` and is disabled with the same rule
5. **Backup menu** (`ExportCommands.swift`). Add "Export Photos by Date…" right after the primary item, always
   listed:
   - shortcut ⌘⇧R, if it's free (check)
   - calls `openExportByDate()`
   - disabled with the same rule
6. **Menu bar** (`MenuBarContent.swift`). Use `openExportByDate()` there too.
7. **Make sure the sheet opens from every pane.** It's presented from `MainWindow`; confirm this.

## Tests

- Unit tests for `canExportByDate` and `openExportByDate`.
- Update the title tests.
- Add a snapshot of the Cloud Library toolbar with the By Date button at 760 pt, if the toolbar snapshot harness
  allows it. Look at the PNG.
- All tests pass.

## Constraints

- Another agent is removing the Tools pane at the same time. It touches:
  - `ExportCommands.swift` (the tool menu items)
  - `MainWindow.swift`
  - `ExportModel.Pane`
  - `AccountTypes`

  Keep your edits to those files minimal and local, so the merge is easy.
- Don't touch:
  - the running app
  - `~/Library/Containers/com.example.Uncloud`
  - `/Volumes`
  - the Keychain
- Use `scratchpad/locked-test.sh`, and read the results with `xcrun xcresulttool get test-results summary`.
