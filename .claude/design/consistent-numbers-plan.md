# Consistent numbers on the Backup pane — Plan

Branch `feature/duplicates-and-icloud-cleanup` at bb732e8 (0.1.15). Owner screenshot (2026-10-21), Backup pane:
- Hero "4 new photos · Since your last export yesterday." with "Export New Photos" (looks disabled: pale blue).
- Space "About 3.92 TB needed · 2.01 TB free" (a day earlier: "About 1.42 TB needed").
- "92,929 backed up · 321 to go".
Owner: "numbers are inconsistent".

## Causes
1. **Space** shows the estimated size of the **whole library** and calls it "needed". The amount still to export
   (`storageNeededBytes`) is only in the help tooltip. The estimate's basis moved from heuristic to scanned, so the
   whole-library figure jumped 1.42 → 3.92 TB, and next to "2.01 TB free" it reads as "won't fit".
2. **To go** is iCloud's count minus backed-up items. iCloud's count includes ~298 items it never lists (see
   unlisted-count-plan.md); `unlistedCount` is only learned at the end of a full check, which hasn't completed on
   this backup yet. So "321 to go" (≈298 + 23) contradicts "4 new photos".
3. **New photos** (hero, sidebar badge) counts items added since the last complete export's watermark — a different
   question from "not backed up". Two different numbers for what the owner reads as the same thing.

## Fix
### A. Space row
- Value: when the backup has photos and `storageNeededBytes` is known: "About X to export · Y free"
  (X = `storageNeededBytes`, formatted with `StorageEstimate.format`). When X is 0 or nothing is to go:
  "Nothing to export · Y free". With no backed-up photos (first export): keep today's "About X needed · Y free"
  (then the whole selection IS what's needed).
- Help/accessibility hint: "Your whole library is about <estimate>." plus the existing basis note.
- The storage warning (`storageWarning`) already uses `storageNeededBytes`; leave it.

### B. One "not backed up" number, only when it can be trusted
- For iCloud, while the destination's resume point has no `unlistedCount` (a full check hasn't measured iCloud's
  hidden items yet), the "to go" part is **not shown** in the drive summary row and **not used** by the hero's
  `.notBackedUp` state or the Library subtitle ("· N not backed up"). Make this one property on ExportModel,
  e.g. `trustedToGoCount: Int?` = `toGoCount` when (source is Photos on This Mac) or (iCloud and the resume point
  for the current layout has `unlistedCount != nil`) and not approximate; else nil. Use it in all three places
  (find them via `toGoCount` usages in Views and BackupHero inputs).
- Drive summary row then reads "92,929 backed up" alone, or "92,929 backed up · 4 new" when the New Photos count
  (the hero's number) is > 0 and `trustedToGoCount` is nil — so the row and the hero show the same number.
  When `trustedToGoCount` is known, "· N to go" as today.

### C. Why the Export button is disabled
Find out from code which condition of `primaryExportEnabled(total:)` can be false in this state (canStart:
isExporting, isEngineRunning, isExportBlocked — verification/cleanup/duplicates/iCloud cleanup busy —,
destinationIssue, isSourceReady; or `selection.selectedCount(total:) > 0` with a nil/0 `total`, e.g. the hero
passing a library total that is 0/nil before the browser has loaded). If it's the `total` case: the new-photos
action opens the date sheet, which doesn't need the selection count — make `primaryExportEnabled` not require
`selectedCount > 0` when `opensExportSince` is true. In every disabled case, set `.help` to a reason, e.g.
"Waiting for the drive check to finish.", "Another task is running.", via a small `primaryExportDisabledReason`
on ExportModel, so the owner can see why. Report which cause it was.

## Tests
- Space value strings (first export, X to export, nothing to export) via a small pure formatter.
- `trustedToGoCount`: nil for iCloud without unlistedCount, value with it, value for Photos on This Mac, nil when
  approximate.
- Hero: `.notBackedUp` not produced when the trusted count is nil.
- `primaryExportEnabled` true with nil total when the sheet would open (if testable with existing seams).
Full suite 0 failures (xcresulttool). Don't launch the app; don't touch ~/Library/Containers, /Volumes, Keychain.
Don't commit.
