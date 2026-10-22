# Export New Photos: last export + date range — Plan

Branch `feature/duplicates-and-icloud-cleanup` at 7ccd99c (0.1.14). Builds on `ExportSince` (0.1.13) and replaces
its single "since" date with a From–To range.

Owner (2026-10-21): "archiving new photos only feature doesn't work, show user the latest export date based on the
date/time on the last exported file in the last export and allow user to pick a date range from a date picker".
Keep the DMG app (no web app).

## Probable cause of "doesn't work" — fix first
`ExportSinceSheet` pages iCloud through `ICloudBridgeFetcher.assets`, which does **not** await `bridge.ready()`
(only `count()` does). Right after launch the bridge may not be ready, so the suggestion fails silently
(`try?`) and the count shows "Couldn’t count the photos." Fix: await `bridge.ready()` once before the first fetch
(in the sheet's lookup, or make `assets` await it — prefer the sheet, to leave the browser untouched).
Also: never swallow errors silently. Log the error (the app's `Logger`, category "export") and show it under the
count: "Couldn’t reach iCloud Photos. <error.localizedDescription>" with a **Try Again** button.

## The sheet (ExportSinceSheet → rename to ExportRangeSheet if simple; keep the model API names otherwise)

```
Export New Photos

Last export      Oct 20, 2026 at 9:27 AM
Newest photo     IMG_4512.HEIC, taken Oct 19, 2026 at 6:12 PM

Export photos taken
From  [ Oct 19, 2026  6:12 PM ]
To    [ Oct 21, 2026  8:40 AM ]      ("Now" button next to it resets To to now)

312 photos not backed up yet  (· 4 already backed up)
                                        [Cancel]  [Export]
```

- **Last export**: `endedAt` (or `updatedAt`) of the newest session in `SessionStore(destination:).list()` whose
  `counts.exported > 0` (status completed, completedWithFailures, cancelled or interrupted all count — it
  exported files). Hidden when there is none.
- **Newest photo** (the owner's "date/time on the last exported file in the last export"): read the **last 500
  records** of the manifest in file order (`exported.tsv` is append-only, so the tail is the most recent exports;
  add a small `ExportManifest.recentRecords(in:limit:)` that reads the tail without loading the whole file into
  an array if easy — reading the whole 6 MB file is acceptable too), stat their files in the destination, and take
  the one with the newest modification date (icloudpd and the PhotoKit export set a file's modification date to
  when the photo was taken). Show its file name and that date. Off the main actor. Nil when nothing can be read
  (drive missing) → hide the row.
- **From** default = that newest photo's date (else the previous suggestion logic: newest backed-up item's
  added/created date, else the New Photos watermark, else 30 days ago). **To** default = now. Both DatePickers
  `.dateAndTime`, stepper-field style; From `in: ...To`, To `in: From...Date()`.
- **Which photos**: those **taken** (`created`, falling back to `added`) within [From, To], not already backed
  up (manifest IDs, as today). Count text: "312 photos not backed up yet", "1 photo not backed up yet",
  "All 4 photos are already backed up", "No photos taken in this range", "Counting…", errors as above. The "· N
  already backed up" suffix only when N > 0.
- Copy for Photos on This Mac is the same (PhotoKit `creationDate` is "taken").

## Finding the photos (pure, unit-tested; update `ExportSince`)
- iCloud: `iCloudItems(takenFrom:to:fetcher:pageSize:limit:)` walks newest-first by `added`. Stop at the first
  item whose `added < from` (a photo can't be taken after it was added, so nothing earlier in added order can be
  taken in range; items with nil `added` never stop the walk). Include an item when `created ?? added` is within
  [from, to]. Keep `limit`/`isAtLeast` as today. Keep ranks for hints.
- Photos on This Mac: predicate `creationDate >= %@ AND creationDate <= %@`.
- Remove the old `iCloudItems(since:)` if nothing else uses it; keep `iCloudSuggestedDate` as the fallback.

## Model
`exportSince(_:items:)` → `exportRange(from:to:items:)` (or keep the name and add `to`). Activity line:
"Exporting photos taken from <from> to <to>." Everything else as today (`.only` override selection, no drive
check, rank hints from the walk).

## Tests (Swift Testing, fake fetcher)
- range walk: includes in-range by created; excludes taken-after-To; stops at first added < From; nil-added
  items don't stop; falls back to added when created is nil; limit → isAtLeast.
- newest-photo lookup: temp destination with a manifest tail and files with set modification dates → picks the
  newest; nil when files are missing.
- last export: from a temp SessionStore with sessions (exported 0 ignored; newest with exported > 0 wins).
- the ready() fix: a fake fetcher/bridge seam if one exists; otherwise note it untested.
Full suite: 0 failures (xcresulttool). Don't launch the app, don't touch ~/Library/Containers, /Volumes, Keychain.
Don't commit.
