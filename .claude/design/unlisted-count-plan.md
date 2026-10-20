# "298 to go" that never goes away — Plan

Branch `feature/duplicates-and-icloud-cleanup` at 4e9a3e1 (0.1.13).

## Facts (owner's backup, 2026-10-20)
- Hero: "Your backup is up to date · Last export today" next to the button "Export 298 New Photos", and
  "92,929 backed up · 298 to go". Earlier: "92,924 of 93,222". The gap stays exactly 298 as the library grows.
- `exported.tsv` holds 92,929 unique `icloud-id:` records, no path-only records.
- The last full walk (session 2026-10-20T00-50-48Z, fullWalk from rank 0) completed with 0 failures; it records
  every item it visits by ID. So the walk yields 92,929 distinct items while iCloud's count says 93,227: 298 items
  are counted but never listed (or listed twice). They can't be exported, so "to go" can never reach 0.
- The 0.1.13 quick resume completed in seconds with 0 new: the speed work does its job.

## Fix 1 — remember the unlisted gap at the end of a complete full walk
- `ICloudResumePoint` gains `var unlistedCount: Int?` (optional, so old files still decode; schema stays 1).
- In `ICloudExportEngine.runEverythingWithBridge`, where `visitedEverything = now` is set and the run ends with
  `failures == 0`: compute `listed = Self.knownItems(in: destination, layout: layout).count` (after the run's
  records) and save `unlistedCount = max(0, libraryCount - listed)` into the point that `savePoint()` writes
  (thread it through `ICloudCoverage.point(...)` or set it on the point before saving — whichever is smaller).
  A quick update keeps the stored value (it doesn't write the point). A run with failures leaves it unchanged
  (copy `previous?.unlistedCount`).
- `ExportModel.iCloudProgress(toward:selection:layout:records:)`: for an `everything` / `allExcept` selection, the
  library size used is `max(0, cachedLibraryCount - unlisted)` where `unlisted` is the destination's resume point's
  `unlistedCount` when its layout matches `layout` (else 0). `.only` selections unchanged.
  Result for the owner: "92,929 of 92,929 photos", "92,929 backed up · all backed up", 0 to go; 5 new photos
  added later show as 5 to go.
- Tests: point decodes without the field; engine test (in `ICloudResumeExportTests`, existing fake bridge) that a
  full walk with 0 failures over a fake library whose count exceeds what it lists saves `unlistedCount`; a run with
  a failure doesn't change it; `iCloudProgress` subtracts it (pure, with a temp destination containing a written
  resume point).

## Fix 2 — the button never promises a number it won't export
Export New Photos now opens the date sheet, which counts what it will export. So the primary title drops the
number: `NewPhotosTitle.primary` returns `exportNewPhotos` ("Export New Photos") instead of
`exportNewPhotos(count:)` when it offers new photos only. Keep `exportNewPhotos(count:)` only if something else
still uses it; otherwise remove it and its tests. Update `NewPhotosTests` / snapshot expectations accordingly.
The Library pane subtitle ("· 298 not backed up") stays, since it describes state, not an action.

## Fix 3 — the hero doesn't say "up to date" while photos are missing
In `BackupHeroContent.make` (BackupHero.swift), before the `.upToDate` return: when New Photos says 0 but the
exact count of photos not backed up (`toGoCount`, not approximate) is > 0, return a new kind `.notBackedUp`:
symbol `exclamationmark.circle`, title "\(N) photos aren’t backed up" (1 → "1 photo isn’t backed up"), subtitle
"Older photos that weren’t exported. Check Whole Library exports them.", tone `.warning`; its button is
**Check Whole Library** (`model.checkWholeLibrary()`, iCloud) — for Photos on This Mac keep the primary button.
Pass whatever `make` needs (to-go count, isApproximate, source) the way its other inputs are passed, with
defaults so existing call sites/tests compile. Add rows to `BackupHeroContentTests`.
After Fix 1 the owner's backup no longer hits this state; it's for real misses (e.g. photos that kept failing).

## Also
`BackupPane`'s "Check Now" button next to "N backed up · M to go" → "Check Backup Folder", matching the menu.

Full suite 0 failures (read via xcresulttool). Don't launch the app; don't touch ~/Library/Containers,
/Volumes, Keychain. Don't commit.
