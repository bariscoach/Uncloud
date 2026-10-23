# Delete from iCloud toolbar + sidebar order (owner request 2026-10-23)

Owner: "delete button should be visible, redesign the menu order perhaps menu as well to make it make more sense".
Screenshot: window ~875 pt wide. The toolbar has the segmented "Library | Recently Deleted (5,084)" picker, then
Select All, then the filter menu, and then a `>>` overflow chevron. The Delete from iCloud button is hidden in the
overflow. In the sidebar, the traffic lights sit on top of the "Export Settings" row: the rows have scrolled under
the titlebar and the brand header can't be seen.

Build automatically (the owner approved building without a further round), then bump the version and make the DMG.

## A. Delete from iCloud toolbar: the delete button can always be seen

File: `Uncloud/Views/CleanupView.swift` (`CleanupGridView.toolbar`, `modePicker`).

1. **Fewer, narrower toolbar items.** Use exactly three items:
   - **Centre** (`.principal`): the segmented picker, labelled `Library` | `Recently Deleted`, with no count in the
     segment. The Recently Deleted count moves to the window subtitle in that mode, as
     "5,084 photos · Deleted for good after 30 days", and the selection count stays there when something is selected.
   - **Trailing, first**: one `Menu` labelled "Select", with the `checkmark.circle` symbol and a title-and-icon label.
     It contains, in this order:
     - Select All, which uses the current filter, as now
     - Deselect All, disabled when nothing is selected
     - a divider
     - an inline picker titled "Show", with the BackupFilter cases
     This replaces both the Select All/Deselect All button and the separate filter menu. When the filter isn't "All",
     the label reads "Select · <filter title>" so the filter in use stays visible. Keep the existing help text and
     accessibility label wording, adapted.
   - **Trailing, last**: the main action. In Library this is "Delete from iCloud…" with a trash symbol, bordered,
     using the existing title, help and enabled rules (keep `deleteTitle`). In Recently Deleted it is "Recover…" as now.
     Give it the highest visibility so it is the last item to overflow. If SwiftUI on this SDK has no visibility
     priority, the item order and the reduced width are what keep it on screen.
2. **Selection bar** (a backstop that can always be seen). While something is selected, a bar sits at the bottom of
   the grid (`safeAreaInset(edge: .bottom)`) on a regular material background with a divider on top. From leading to
   trailing it holds:
   - "12 photos selected · 3.2 GB" (use the known bytes when available, and leave out the size when unknown)
   - a spacer
   - a "Deselect" plain button
   - the same main action button (Delete from iCloud… / Recover…) with the same enabled rule and action
   Hide the bar while a run's status card shows. Animate it with `.smooth`, or with nothing under Reduce Motion.
3. The Edit menu command stays as it is.
4. **Width check**: at the window's minimum width (760 pt) with the sidebar showing, at 1000 pt, and with a count of
   5,084, nothing may overflow. Add snapshot cases for both widths, in both modes, with and without a selection.
   Follow the existing env-gated snapshot test pattern (TEST_RUNNER_ prefix). If the toolbar doesn't render in
   snapshots, assert the item count and labels in a unit test instead.

## B. Sidebar order that follows the job

Files: `Uncloud/Model/ExportModel.swift` (`Pane` order), `Uncloud/Views/MainWindow.swift` (`SidebarPaneRows`), tests
that assert the order (search for `Pane.allCases` and order expectations).

The new order follows the steps a person takes: get photos out, check them, then free up iCloud. The settings and
utilities come after those.

1. Cloud Library (`.export`): see your iCloud photos and export them
2. Browse Backup (`.browse`): see what's on your drive
3. Delete from iCloud (`.cleanup`): free up iCloud space once backed up
4. A section break, as an unlabelled `Section` or a spacer
5. Tools (`.tools`)
6. Export Settings (`.backup`). The progress badge stays on this row.

Rules for the change:
- Reorder the `Pane` cases. `CaseIterable` drives the sidebar.
- Update the doc comment that lists the order.
- Leave the default pane as `.export`.
- Keep the keyboard shortcuts. If ⌘1…⌘5 are mapped to `allCases` order, they follow the new order, and that's
  intended. Check the menu commands.

## C. Sidebar header never under the traffic lights

`MainWindow.swift`: the brand header is a `safeAreaInset(edge: .top)` on the sidebar `List`. In the owner's window
(macOS 26) the rows ended up under the titlebar, with the traffic lights over "Export Settings". Make the header and
rows always start below the titlebar:
- Option 1, preferred: put `SidebarBrandHeader` inside the `List` as the first, non-selectable content, such as a
  `Section` header or a row with `.selectionDisabled()` and no tag. List content respects the titlebar's safe area.
- If that isn't possible, keep the inset and add top padding equal to the titlebar height.

Verify the fix in a real `NSWindow` with `.fullSizeContentView` and the unified toolbar style, using the same window
setup as the app. Do this in a snapshot test if the existing harness can host a window, and say so if it can't.

## Constraints

- Swift 6, XcodeGen. Run `xcodegen generate` if files are added.
- Tests: `scratchpad/locked-test.sh <repo> -resultBundlePath <unique>`. Read the results with
  `xcrun xcresulttool get test-results summary`. All tests must pass.
- Don't touch the running app, ~/Library/Containers/com.example.Uncloud, /Volumes or Keychain.
- Match the surrounding code's comment density and naming. Write user-facing copy in plain words.
