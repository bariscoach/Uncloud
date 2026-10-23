# Find Duplicates: a duplicates library that keeps the original (owner request, 2026-10-23)

## Owner's request

> "finding duplicates should open up a duplicate library showing all copies, the action should keep only the original
> (first) copy the rest should be deleted. User should be notified of that once clicking remove duplicates action."

Build this automatically, then bump the version and make a DMG. The owner approved building without a further round.

## What's there today (0.1.20)

The Find Duplicates sheet lives in `Uncloud/Views/FindDuplicatesSheet.swift`. Its states come from `DuplicateCleanup`
(`Uncloud/Model/DuplicateCleanup.swift`): ready, scanning, noneFound, found, removing, finished, failed.

In the found state, the sheet lists three sections:

1. **Extra copies.** `DuplicateFinder.ExtraCopy`, grouped by folder, with one checkbox per folder.
2. **Same-folder groups.** `DuplicateFinder.Group`, with a choice of which copy to keep (`setKeeper`).
3. **iCloud items that share a file.** `SharedItemGroup`, with "Review in Delete from iCloud".

How removal works today:

- Removal goes through `DuplicateFinder.remove(...)` and `removeExtraCopies(...)`.
- Both re-verify checksums and move files to the Trash.
- The extra-copy keeper is the copy in the layout's folders, otherwise the copy recorded first
  (`DuplicateFinder.swift` ~L213).

## Design

### 1. The duplicates library

Once the scan has found something, the sheet becomes a library of duplicates. It replaces the found state's list.

**Size.** Make the sheet large and resizable: ideal 920×660, minimum 720×520. A sheet is fine; it doesn't need its
own window.

**Header bar** (top):

- Title: "Duplicates".
- Summary: "2,854 copies of 2,851 photos · 66 GB". Use the existing byte formatting.
- A short line under the summary: "Uncloud keeps the original of each photo, the first copy it saved, and removes the
  other copies."

**Body.** A lazy, scrolling list of photo groups. Each group is one photo that has more than one copy on the drive,
and both kinds of drive duplicates are merged into one model:

- an ExtraCopy set: the keeper's media plus each extra folder's copy
- a same-folder `Group`: its copies

Each group has:

- **A group header row.** It shows the file name (the keeper's first media file name), then
  "3 copies · 4.2 MB to free".
- **A row of tiles.** Use 140 pt square thumbnails and reuse the existing `FileThumbnail` / QuickLook loader. They
  load lazily and cancel when scrolled away. The **original comes first**.
  - **Original tile:** a green "Original · Kept" capsule badge (`checkmark.seal.fill`), with the folder path below in
    caption, relative to the backup, for example "All in One Folder" or "2026/10".
  - **Copy tiles:** a "Copy · Removed" badge (`trash` symbol, secondary/red tint). The thumbnail is dimmed to 60%.
    The folder path appears below.
  - **Videos:** the tile overlays a small video glyph.

**Context menu on a group:**

- "Keep All Copies of This Photo": excludes the group, which turns its badges to "Kept" and dims it out of the count.
- "Show in Finder": reveals the original.

There's no per-copy keeper picker any more. The rule is fixed (see §2). `setKeeper` can stay in the model for
tests, but the UI no longer offers it.

**Big libraries.** The owner's case is about 2,850 groups. Use `LazyVStack` with pinned section headers off, and don't
build all tiles eagerly. Scrolling must stay smooth.

**iCloud items saved twice** (`SharedItemGroup`) are not files to delete on the drive. Show them as one compact
notice row at the top of the list, rather than as groups:

> "31 photos are saved twice in your iCloud library. Your drive keeps one file for each."

The notice has a "Review in Delete from iCloud" button, which keeps the existing behaviour.

**Footer bar** (bottom, always visible):

- Leading: "2,854 copies selected for removal · 66 GB". This updates when groups are excluded.
- Trailing: Cancel/Close, then **Remove Duplicates…** as `borderedProminent`. Disable it when nothing is left to
  remove.

### 2. "Original" = the first copy

`DuplicateFinder` picks the original as follows:

- **Same-folder groups.** The copy with the lowest `exportOrder`, which is the first exported. Ties go to the
  current order. Set `keeperID` to it; this is already the default sort at ~L343, so confirm and keep it.
- **Extra copies across folders.** The copy recorded first (`firstIndex`) **among the copies in the current folder
  organization**. If no copy is in the layout, use the first recorded copy overall.
  - This matches today's behaviour. It must stay this way: if the kept copy left the layout's folders, the next
    export would download the photo again.
  - Document this in a comment.
  - In the owner's backup, the first copies are the flat ones, which are the layout copies, so "first" and
    "in layout" agree.

Add tests:

- The keeper is the earliest-exported copy.
- An extra-copy keeper prefers the in-layout copy even when a non-layout copy was recorded first.

### 3. Notify before and after removing

**Before.** Clicking **Remove Duplicates…** opens a confirmation alert. Text:

- Title: "Remove 2,854 Duplicates?"
- Message: "Uncloud keeps the original of each photo, the first copy it saved, and moves the other 2,854 copies
  (66 GB) to the Trash on “<volume name>”. Each copy is checked against its original before it's moved. You can put
  copies back from the Trash until you empty it."
- Buttons: "Move to Trash" (destructive), and "Cancel" (the default, which Esc triggers).
- Use singular forms when the count is 1: "Remove 1 Duplicate?", "the other copy".

**After.** The sheet shows a finished state:

- With nothing skipped: "Removed 2,854 duplicates", "66 GB will be freed when you empty the Trash".
- With skips or failures, show them and list them in the existing disclosure: "Removed 2,850 duplicates · 4 skipped
  because they didn't match their original".
- Buttons: "Show Trash" (existing `openTrash`) and "Done".
- **System notification.** If the app isn't frontmost when the removal finishes, post a user notification with the
  same text. Reuse the existing `UNUserNotificationCenter` helper pattern in the app (see `NewPhotosTracker` /
  `AutoBackupController`). Ask for no new permission if one is already requested elsewhere; otherwise request it at
  this moment.

### 4. Keep

- All safety checks: checksum re-verification of both the copy and its original, Trash rather than delete, sidecars
  handled as today.
- The existing ready, scanning, noneFound, removing and failed states, and their copy.

## Tests

- **Unit tests:**
  - the merged group model (counts, bytes, exclusion)
  - the keeper rules from §2
  - the confirmation text, singular and plural
  - the finished text
- **Snapshot tests**, using the existing env-gated pattern with the `TEST_RUNNER_` prefix:
  - the library with mixed groups (including a video and a group with 3 copies)
  - the iCloud notice row
  - the confirmation
  - the finished state
  - light and dark
- All existing tests pass. Update tests for the old found-state UI as needed.

## Constraints

- Swift 6 and XcodeGen. Run `xcodegen generate` when adding files.
- Run tests with `scratchpad/locked-test.sh` and read the results with
  `xcrun xcresulttool get test-results summary`.
- Don't touch:
  - the running app
  - `~/Library/Containers/com.example.Uncloud`
  - `/Volumes`
  - the Keychain
- Write user-facing copy in plain words, matching the existing style.
