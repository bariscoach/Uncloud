# Export Since a Date — Plan

Branch `feature/duplicates-and-icloud-cleanup` at 37ab681 (0.1.12). One build chunk.

Owner: "based on the date and time of the latest file (photo/video) exported, allow users to pick a date (suggest)
in a date picker for the new export."

## Behaviour

When the backup already has photos from this source (today's `offersNewPhotosOnly`), the primary action
**Export New Photos** opens a small sheet instead of starting at once:

```
Export New Photos
Export photos added to your library since:
[ Oct 12, 2026  3:41 PM ]        (DatePicker, .dateAndTime, stepper-field style)
Suggested: your newest backed-up photo was added Oct 12, 2026 at 3:41 PM.
About 312 photos                  (live, after a short pause; "Counting…" while counting; "No photos" at 0)
                         [Cancel]  [Export]  (Export = default action)
```

- Suggested date = when the **newest photo already in the backup** was added to the library (iCloud: `added`,
  falling back to `created`; Photos on This Mac: `creationDate`). While it's being looked up, the picker shows the
  New Photos watermark's `newestAddedDate` if there is one, else today minus 30 days, and the caption reads
  "Finding your newest backed-up photo…". If none can be found: caption "Couldn’t find a backed-up photo to
  suggest a date from." and the date stays.
- The picker can't go past now (`in: ...Date()`).
- Export runs a normal export of exactly those photos (`.only(ids)` override selection, so the saved selection is
  untouched), **with no pre-run drive check**. Photos already in the backup are skipped by the engine as always.
- Everything else keeps today's behaviour: first export (no history), partial selection, Resume, the menu bar
  extra's "Export New Photos" and automatic backups (they keep the quick update with no sheet).
- Menu titles that now open the sheet get an ellipsis: the Backup menu's primary item reads
  "Export New Photos…" when it will open the sheet (HIG: ellipsis = more input needed). Toolbar/hero buttons keep
  their titles without an ellipsis (HIG: buttons in a toolbar don't use ellipses when … — keep as today).
- Free feature (Export). Never consult `AccountModel`.

## Finding the photos (new pure helper, unit-tested)

New file `Uncloud/Model/ExportSince.swift`:

```swift
enum ExportSince {
    /// iCloud: walks pages newest-first from rank 0. Returns the ids (with ranks, for rank hints) of items whose
    /// `added ?? created` is >= `date`. Stops at the first item whose `added` is earlier than `date` (the walk is in
    /// added order). Items with nil `added` use `created` for the comparison and don't stop the walk.
    /// `limit` (default 20_000) caps the result: past it, `isAtLeast` is true and the sheet says "More than 20,000
    /// photos" and Export is still allowed (the export then includes the first 20,000 only — say so in the caption:
    /// "Only the newest 20,000 are exported this time.").
    static func iCloudItems(since date: Date, fetcher: any ICloudPageFetching, pageSize: Int = 200, limit: Int = 20_000)
        async throws -> (items: [String: Int], isAtLeast: Bool)

    /// iCloud: the newest backed-up item's date: walks from rank 0 until the first id in `known`; returns its
    /// `added ?? created`. Gives up (nil) after `scanLimit` (default 5_000) items.
    static func iCloudSuggestedDate(known: Set<String>, fetcher: any ICloudPageFetching, pageSize: Int = 200,
                                    scanLimit: Int = 5_000) async throws -> Date?
}
```

`ICloudPageFetching.assets(offset:limit:)` returns `ICloudAsset` with `added` and `created`. Get a fetcher the
way `NewPhotosTracker` does (NewPhotosTracker.swift ~line 188 uses one; `ICloudBridgeFetcher` in ICloudBridge.swift
~1136). `known` = `ICloudExportEngine.knownItems(in:layout:)` (manifest only, no disk scan).

Photos on This Mac (PhotoKit): in the same file, `photosLibraryItems(since:)` → `PHAsset.fetchAssets(with:)` with
predicate `creationDate >= %@`, returning local identifiers; `photosLibrarySuggestedDate(exported:)` → fetch all
assets sorted by `creationDate` descending and return the first whose `localIdentifier` is in
`ExportManifest.exportedIDs(in:)`; give up after 5,000. (No unit tests for the PhotoKit parts; keep them thin.)

## Model (`ExportModel`)

- `var isChoosingExportSince = false` (sheet binding).
- `performPrimaryAction()`: when `offersNewPhotosOnly` and not paused / no resume pending → set
  `isChoosingExportSince = true` instead of `startOrResume()`. The Backup menu item calls the same.
- `func exportSince(_ date: Date, items: [String: Int])`: `startRun(selection: .only(Set(items.keys)), …)` with a
  new parameter `skipsDriveCheck: true` threaded like `forcesFullCheck` (startRun → startExport), and the iCloud
  rank hints taken from `items` instead of `browser.rankHints` (add an optional `rankHints:` override parameter
  threaded the same way). For PhotoKit, items' values are unused (pass ranks 0).
- Activity line at start: "Exporting photos added since <date, abbreviated, with time>."

## View

New `Uncloud/Views/ExportSinceSheet.swift`, built with the existing `FormSheetScaffold` (Components.swift) like
the other small sheets. Holds `@State date`, `suggested: Date?`, the counted `items`, `isCounting`. On appear:
look up the suggestion (task), then count. On date change: cancel the previous count task, wait ~400 ms, recount.
Export disabled while counting or at 0. Present it with `.sheet(isPresented: $model.isChoosingExportSince)` from
`MainWindow` next to the other sheets there.

Copy (sentence case for descriptions, title case for title/buttons):
- Title "Export New Photos"; prompt "Export photos added to your library since:" (Photos on This Mac: "Export
  photos taken since:" since PhotoKit has no added date).
- Captions as in the mock above; count: "1 photo" / "312 photos" / "About 312 photos" never (exact), "Counting…",
  "No photos since then".

## Tests (Swift Testing)

`UncloudTests/ExportSinceTests.swift` with a fake `ICloudPageFetching` (list of ICloudAsset newest first):
- items since a date: stops at the first older `added`; includes nil-`added` items by `created`; ranks correct;
  limit → `isAtLeast`.
- suggested date: first known item's `added`; falls back to `created`; nil when none within `scanLimit`.
- `performPrimaryAction` with history opens the sheet (if `ExportModel` tests have a seam for `offersNewPhotosOnly`;
  otherwise skip).
Full suite: 0 failures via `xcrun xcresulttool get test-results summary`.
