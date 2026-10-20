# Quick Export New Photos — Plan

Branch `feature/duplicates-and-icloud-cleanup`, at 4794407. One build chunk.

Owner report (screenshot: "Exporting… 99% · 92,924 of 93,222 photos", for a long time): exporting new photos only
is too slow because the run checks every previously exported photo. Owner approved: a quick update for routine runs,
a full check about once every 30 days or on demand, and an honest progress line during full checks.

## Why it's slow today

`ICloudExportEngine.runEverythingWithBridge` (whole library, month/flat layouts, bridge) always visits every rank:
either a `.fullWalk` from rank 0, or `.fromRank` = new items by ID + walk past the anchor + the **closing walk from
rank 0 back to the anchor**. Items already on the drive are passed over without an `ExportEvent`, so progress sits
at 99 % while the bridge pages through ~93,000 items. This is deliberate (ResumePoint.swift SAFETY INVARIANT) and
stays the behaviour of a *full check*. What's new is that a routine run doesn't need to be a full check.

## Design

### 1. Quick update (engine)

New photos are inserted at rank 0 (icloudpd's newest-first order). A quick update scans from rank 0 and collects
items not on the drive, stopping after a long run of items that are.

**New pure type** in a new file `Uncloud/Export/ICloud/ICloudQuickUpdate.swift` (pure apart from `fetch`, like
`ICloudResumePlanner`, so it's unit-testable with a list):

```swift
enum ICloudQuickUpdate {
    enum Plan: Equatable, Sendable {
        /// Items not on the drive at the top of the library, by ID with their ranks (possibly empty).
        case only([String: Int])
        /// A full check is needed; the reason is shown in the activity list.
        case fullCheck(reason: String)
    }

    /// Whether a quick update may run at all. False means a full check.
    static func isEligible(point: ICloudResumePoint?, account: String, layout: FolderLayout,
                           known: Set<String>, missing: Set<String>, now: Date,
                           maxAge: TimeInterval = ICloudResumeSettings().fullCheckInterval) -> Bool
    //  true only when: known is non-empty, missing is empty, point exists with the same account and
    //  layout, point.lastFullWalkAt != nil, and 0 <= now - lastFullWalkAt <= maxAge.
    //  (A lastFullWalkAt in the future, e.g. a clock change, is not eligible.)

    static func plan(libraryCount: Int, known: Set<String>, settings: ICloudResumeSettings,
                     fetch: ICloudResumePlanner.Fetch) async throws -> Plan
}
```

`plan` algorithm: page from offset 0 with `settings.pageSize`, `Task.checkCancellation()` per page. For each id at
rank r: if `known.contains(id)` → `knownRun += 1`, else `only[id] = r; knownRun = 0`. Stop and return `.only(only)`
when `knownRun >= settings.overlap`, or when a page comes back shorter than asked (end of library). Return
`.fullCheck(reason: reasonTooMany)` when `only.count > settings.quickMaxItems` or the scan reached
`settings.quickScanLimit` ranks without stopping.

Reasons (user-facing, sentence case, curly apostrophes):
- `reasonDue` = "It’s been a while since Uncloud checked your whole library, so it’s checking all of it now. Photos already in your backup are skipped."
- `reasonTooMany` = "Too many photos to look for quickly, so Uncloud is checking your whole library. Photos already in your backup are skipped."

**`ICloudResumeSettings`** gains (tests shrink them):
- `fullCheckInterval: TimeInterval = 30 * 24 * 60 * 60`
- `quickScanLimit = 5_000`
- `quickMaxItems = 2_000`
Keep the memberwise init usable: the tests call `ICloudResumeSettings(minimumCovered:searchWindow:overlap:topScanSlack:pageSize:)`,
so put the new properties after the existing ones with defaults.

**`ICloudExportEngine`** gains `var quickUpdate = false` (after `resumeSettings`). In `runEverythingWithBridge`,
after `known`, `account`, `now`, `previous` are computed and **before** `ICloudResumePlanner.plan`:

```
if quickUpdate {
    if ICloudQuickUpdate.isEligible(point: previous, account:, layout:, known:, missing: missingItems.subtracting(known), now:, maxAge: resumeSettings.fullCheckInterval) {
        switch try await ICloudQuickUpdate.plan(libraryCount:, known:, settings: resumeSettings, fetch: { … bridge.page … .map(\.id) }) {
        case .only(let items): try await runQuickUpdate(...); return
        case .fullCheck(let reason): emit(.note(reason))   // then fall through to the planner as today
        }
    } else {
        emit(.note(ICloudQuickUpdate.reasonDue))   // only when quickUpdate was asked for
    }
}
```

`runQuickUpdate` (a private method, or a branch inside `runEverythingWithBridge` reusing its local
`finished`/`failed` closures — whichever keeps the code smaller; extracting the shared closures is fine):
- `emit(.continuation(.init(strategy: .quick, startRank: nil, fallbackReason: nil)))` — add `case quick` to
  `ExportSession.Continuation.Strategy`.
- `onDrive` as computed today; `emit(.prepared(total: onDrive + items.count, alreadyExported: onDrive))`.
- `items.isEmpty` → `emit(.note("No new photos since your last export."))`, then `manifest.markRunFinished()`; return.
- Else `emit(.note("Looking for new photos only. Uncloud checks your whole library about once a month."))`,
  then one `download` in `.only` mode: `options(.only, items.keys.sorted(), items, 0, nil)`, events handled exactly
  like the existing "New items at the top, by ID" block (`finished` / `failed`).
- Never call `savePoint()` / never write `resume.json` in a quick run (the previous point, and its
  `lastFullWalkAt`, stay as they were; the planner already copes with ranks shifted by new items).
- Hash pending files at the end (`scanner.hash(pendingHashes)`, also in the catch path) and
  `manifest.markRunFinished()` only when `failures == 0` — same as the full path.

### 2. Who asks for a quick update (model)

`ExportModel` (ExportModel.swift ~line 858 builds `ICloudExportEngine`). Pass
`quickUpdate: selection.isEverything && !resumesInterrupted && !forcesFullCheck`. `resumesInterrupted` is already
a parameter of `startExport`. A paused run resumes in place and is unaffected.

- New one-shot `@ObservationIgnored private var forcesFullCheck = false`, read and reset to false in `startExport`.
- New `func checkWholeLibrary()`: `guard destination != nil, source == .iCloud else { return }`, set
  `forcesFullCheck = true`, `startRun(selection: .everything)`. If `startRun` doesn't start (guard fails), reset
  the flag (simplest: reset it in `startRun`'s `guard canStart else { forcesFullCheck = false; return }`).
- Photos on This Mac (`ExportEngine`) is local and unchanged.

### 3. Menu

`Uncloud/App/ExportCommands.swift`, `CommandMenu("Backup")`: after "Export All Photos" (line ~126) add
`Button("Check Whole Library")`, calling `model.checkWholeLibrary()`, `.disabled(!model.canExportAll)`, shown only
when `model.source == .iCloud`. `.help("Goes through every photo in your iCloud library and backs up anything missing. Takes longer.")`
if the surrounding items use help; otherwise skip help.

### 4. Honest progress during a full check

**Bridge** (`Uncloud/Helper/photo_bridge.py`): `_DownloadRun.idle(self, rank=None)`; when `rank is not None` and
`self._since_poll` reaches `PAGE_CHUNK` (the same place it calls `serve_waiting`), also send
`{"id": request_id, "event": "walked", "rank": rank}`. Pass `rank` from the `allExcept` branch of `_download`
(`run.idle(rank)` at ~line 1029); leave the other call (~1056) without it. Document the event in the module
docstring next to `progress`. Older apps ignore unknown events.

**Swift bridge** (`ICloudBridge.swift`): `ICloudBridgeDownloadEvent.walked(rank: Int)` parsed from
`"walked"` (needs `rank`; nil → ignore message). Check `ICloudBridgeMessage` already decodes `rank`.

**Engine**: in the two `allExcept` downloads (walk past the anchor, closing walk) handle
`.walked(let rank)` → `emit(.checked(done: min(rank + 1, total), total: total))` where total is the run's
`libraryCount`. New `ExportEvent.checked(done: Int, total: Int)`.

**Batch** (`ExportRun.swift` `ExportBatch`): `var checked: (done: Int, total: Int)?` keeps the last one;
`isEmpty` accounts for it. Not a processed item.

**Model**: `var checkingProgress: (done: Int, total: Int)?` (observable) set from `batch.checked`; cleared in
`finish` and when a run starts. Also `var checkingProgressText: String?` → "Checking your library: 41,000 of 93,222".

**UI**: wherever the running hero shows "92,924 of 93,222 photos" (BackupHero.swift) and the Export pane's running
status, show `checkingProgressText` as a secondary line (`.secondary` foreground, same font as the neighbouring
secondary text) under it when non-nil. Match the existing code's style; no new components.

## Tests (Swift Testing; run with the lock script)

- `UncloudTests/ICloudQuickUpdateTests.swift` (new), in the style of `ICloudResumePlannerTests` (list library,
  `Pages` fetch recorder, shrunk settings e.g. `overlap: 20, pageSize: 10, quickScanLimit: 200, quickMaxItems: 50`):
  - new items at the top → `.only` with exactly those IDs and ranks; stops after `overlap` known items (assert the
    fetched offsets don't go far past)
  - no new items → `.only([:])` after one overlap's worth of pages
  - small library, all new / end of library reached → `.only` with them
  - more than `quickMaxItems` new → `.fullCheck(reasonTooMany)`
  - scan limit reached (known items scattered so the run never reaches overlap) → `.fullCheck`
  - `isEligible`: true for a 1-day-old full walk; false at 31 days, nil `lastFullWalkAt`, nil point, other account,
    other layout, empty known, non-empty missing, future date
- Engine-level: if `ICloudResumeExportTests` has a fake bridge harness for `runEverythingWithBridge`, add: quick
  run downloads only the new items, sends no `allExcept` download, doesn't change `resume.json`, emits
  `.continuation(.quick)`; with an old `lastFullWalkAt` it does the normal walk and emits the `reasonDue` note.
  If no such harness exists, skip this rather than build one.
- `ExportBatch` folds `.checked` (last wins, `processed` unchanged).
- `ICloudBridgeDownloadEvent` parses `walked`.
- Python: in `UncloudTests/Bridge/test_bridge.py`, a test that an `allExcept` download over > PAGE_CHUNK known
  items sends at least one `walked` event with a rank. Run:
  `Vendor/icloudpd-runtime/python/bin/python3.13 -I -B UncloudTests/Bridge/test_bridge.py Uncloud/Helper/photo_bridge.py`

## Not in scope
Album layout (icloudpd per album), Photos on This Mac, the New Photos watermark/count, the primary button title.
