# Export New Photos Only + Clean Up iCloud Becomes Paid — Plan

Branch `feature/duplicates-and-icloud-cleanup`, at c6b542f. Plan only. One build chunk, at the end.

Owner feedback: *"if there is an export history in the past and user wants to export photos, we should offer user
to export new photos only (the ones that were not part of the previous download). can app identify this and offer
this option?"*

Owner decision (same day): *"Clean Up iCloud should be a paid feature"*, meaning the whole pane, Recently Deleted and
Recover included.

---

## Part 1. Export New Photos Only

### 1.1 How it works today

- **Primary button title.** `ExportModel.primaryExportTitle(total:)` (ExportModel.swift:546) calls
  `NewPhotosTitle.primary` (NewPhotos.swift). The Export pane toolbar (ExportView.swift:95), the Backup hero
  (BackupHero.swift:196) and the Backup menu ⌘R (ExportCommands.swift:107) all use it. The rules are:
  1. paused, or an interrupted run (`hasIncompleteRun`) → the fallback, which reads "Resume" or "Resume Export"
  2. no folder → "Choose Backup Folder…"
  3. `selection.isEverything && newPhotosStatus != nil` → **"Export New Photos"**
  4. otherwise the fallback, `exportTitle(total:)`: "Export All Photos", or "Export N Photos"
- **`newPhotosStatus`** (ExportModel+NewPhotos.swift:18) is non-nil only when `NewPhotosTracker` found a
  **watermark** in `~/Library/Application Support/Uncloud/NewPhotos/<storageKey>.json`. The key combines the source,
  the Apple Account hash and the volume UUID plus the path.
- **When a watermark is saved.** `captureNewPhotosCandidate` runs at the start of a run and
  `recordNewPhotosWatermark` runs at its end. `NewPhotosWatermarkPolicy.shouldRecord` saves one **only when** the
  outcome is `.completed`, the selection is everything **and `failedCount == 0`**. If the capture fails (for
  example, the iCloud page fetch fails at the start), the run saves nothing and only logs the fact.
- **The engine already skips backed-up photos.** In ExportRun.swift:67 it logs "Skipping N photos that are already
  backed up". "Export New Photos" and "Export All Photos" run **the same code**: `performPrimaryAction` →
  `startOrResume` → `startRun(selection: nil)`. Only the label differs.
- **The app already knows what isn't backed up, with no watermark.** At idle, `refreshProgress()` (ExportModel.swift:1404)
  sets `totalCount` and `processedCount` for the current selection from the backup folder's manifest:
  `PhotoLibrary.progress` for Photos on This Mac, `iCloudProgress` for iCloud Photos. A drive check refreshes them too.
  `onDriveCount` and `toGoCount` (ExportModel.swift:1204–1214) are the same "9,207 backed up · 1,243 to go" the
  Backup pane shows. `isOnDriveCountApproximate` is true when iCloud records came from file paths.

### 1.2 Why the owner didn't see the offer (root cause)

The offer depends on the **watermark**. It doesn't depend on what is **in the backup**. The owner's backup folder
has export history, but it has no watermark for this folder, source and account. Several things can cause that, and
all of them are ordinary:

1. **Runs before New Photos existed** (before 9dbea40). They have history in the manifest and sessions, but they
   left no watermark.
2. **Any run that didn't finish cleanly.** A run with even one photo that couldn't be exported (`failedCount > 0`,
   which is common with iCloud), a cancelled run, a stopped or resumed-and-cancelled run, or an export of a partial
   selection never saves one. On a large library, few real runs meet every condition.
3. **An unfinished run** (`hasIncompleteRun`) makes the button "Resume Export", which hides the offer even when a
   watermark exists.
4. **A different folder or drive path, a different source, or a different Apple Account** has its own key, so it
   starts with no watermark.

The following were ruled out as causes:
- **Account gating (387d7ad).** `AutoBackupController.checkForNewPhotos` still calls `refreshNewPhotos(force: true)`
  when `.newPhotos` isn't allowed. `ExportModel` never consults the account for the count or the title, and Release
  builds have accounts `off`.
- **The count being computed only in the Backup pane.** `LibraryBrowserView.task` in ExportView.swift:161 and
  `refreshProgress()` both refresh it.

Fix: base the offer on the backup itself, using the manifest's counts that already exist. Keep the watermark for
the "N new photos since your last export" line, the badge and the reminders.

### 1.3 Design

**The rule.** When the backup folder already has backed-up photos from this source (`onDriveCount > 0`) and the
whole library is selected, the primary action is presented as an export of new photos only:

| State | Primary title |
|---|---|
| Paused / interrupted run | unchanged: "Resume" / "Resume Export" |
| No backup folder | unchanged: "Choose Backup Folder…" |
| Everything selected, backed up > 0, exact count, to go = N > 0 | **"Export N New Photos"** (for example "Export 1,243 New Photos", "Export 1 New Photo") |
| Everything selected, backed up > 0, but the count is approximate, unknown (iCloud library size not cached yet), 0, or a run or engine is active | **"Export New Photos"** (no number) |
| Everything selected, no backed-up photos, but a watermark exists | "Export New Photos" (as today) |
| Everything selected, nothing backed up, no watermark (**first export ever**) | unchanged: "Export All Photos" |
| Partial selection | unchanged: "Export N Photos" |

- **Source of N:** `toGoCount` from the manifest, which is the "to go" in "N backed up · M to go". The watermark
  count isn't used. The manifest count works for every kind of history, counts photos that are missing from the
  drive too, and is what the engine actually copies. The watermark count ("new since the last complete export")
  stays where it is today, on the status line, the badge and the reminder. The two numbers can differ: the
  manifest count is the larger, because it includes older photos that failed or were never exported. That is
  correct, because the button says what it will copy.
- **To go = 0** keeps "Export New Photos", enabled, and the Backup hero shows it in the bordered style
  (`isUpToDate`) as today. iCloud's library size comes from `ICloudLibrary.cachedLibraryCount`, which can lag
  behind, so 0 doesn't prove there's nothing new. The run finds out.
- **Unknown or being checked:** while `refreshProgress` or a drive check runs, the last figures stay. At launch,
  `processedCount` is 0 until the manifest is read, so the title can read "Export All Photos" for a moment. That's
  acceptable: it's the same flash Resume Export has today. There's no spinner in the title.
- **No "Export All Photos…" that copies everything again.** The brief suggested one, but such an action would have
  to bypass the manifest and contradict "photos already backed up are never exported twice". Today "Export All"
  only differs from the primary when the selection is partial. The existing Backup menu item **"Export All Photos"
  (⌥⌘R)** stays as the way to ignore a partial selection, and it also skips backed-up photos. No new control is
  added. The choice is made clear through wording instead:
  - **Help and accessibility hint** for the primary button when it exports only new photos (replaces the
    `primaryExportHelp` string): "Exports only photos that aren’t in your backup yet. Photos already backed up are
    never exported twice."
  - **Export pane subtitle** (`ExportView.countText`) when everything is selected and backed up > 0, with the
    exact count and N > 0: "All 93,015 photos selected · 1,243 not backed up" followed by the size suffix as today.
    With an approximate count: "· about 1,200 not backed up". With 0 it shows "· all backed up". The glossary uses
    "backed up / not backed up" for state, and status text is sentence case.
- **Library grid selection:** this chunk doesn't change it. A partial selection keeps "Export N Photos", and the
  engine skips the backed-up ones. A follow-up (not in this chunk) could add a "Not Backed Up" filter and
  **Select New Photos** to the Export pane by reusing `BackupFilter`, `BackupFilter.selection(backedUp:)` and the
  manifest-ID read in `CleanupGridView.backedUpIDs` (CleanupView.swift:349), generalized to the Photos on This Mac
  records.
- **Sources:** identical for **iCloud Photos** and **Photos on This Mac**, because both feed
  `totalCount`/`processedCount` through `refreshProgress`. iCloud figures may be approximate, which drops the
  number from the title.
- **Free:** the title, the subtitle and the export never read `AccountModel`. Export is the free tier, and owner
  decision 2 already covers it ("Export New Photos, being an export, is free"). A test pins this down (1.5).
- **Accessibility:** the button's label is its title, numbers included. VoiceOver reads "Export 1,243 New Photos".
  Add `.accessibilityHint` with the help sentence on the Export toolbar and Backup hero buttons. The Backup menu
  item uses the same title.

### 1.4 Code changes

**Uncloud/Model/NewPhotos.swift** — `NewPhotosTitle`:
```swift
enum NewPhotosTitle {
    static let exportNewPhotos = "Export New Photos"
    static let chooseFolder = "Choose Backup Folder…"
    static let newOnlyHelp = "Exports only photos that aren’t in your backup yet. Photos already backed up are never exported twice."

    /// "Export 1 New Photo", "Export 1,243 New Photos".
    static func exportNewPhotos(count: Int) -> String

    /// True when the primary action is presented as new photos only (rows 3–5 of the table).
    static func offersNewOnly(isPaused:hasInterruptedRun:needsFolder:isEverything:hasNewPhotosStatus:backedUpCount:) -> Bool

    /// `notBackedUpCount` is nil when unknown, approximate or during a run.
    static func primary(isPaused: Bool, hasInterruptedRun: Bool, needsFolder: Bool, isEverything: Bool,
                        hasNewPhotosStatus: Bool, backedUpCount: Int, notBackedUpCount: Int?, fallback: String) -> String
}
```
`primary` works as follows: paused or interrupted → fallback; needs a folder → chooseFolder; `offersNewOnly` →
`notBackedUpCount.map { $0 > 0 ? exportNewPhotos(count: $0) : exportNewPhotos } ?? exportNewPhotos`; otherwise
fallback. `offersNewOnly` = not paused, no interrupted run, has a folder, `isEverything`, and
`(backedUpCount > 0 || hasNewPhotosStatus)`.

**Uncloud/Model/ExportModel.swift**:
- `primaryExportTitle(total:)` passes `backedUpCount: isExporting || isEngineRunning ? 0 : (onDriveCount ?? 0)`. That
  keeps today's behavior during a run, when the toolbar button is disabled anyway. Make sure the
  `hasNewPhotosStatus` path still gives "Export New Photos" then.
  It also passes `notBackedUpCount: (isExporting || isEngineRunning || isOnDriveCountApproximate) ? nil : toGoCount`.
- Add `var offersNewPhotosOnly: Bool` built from the same inputs, for the help, the hint and the subtitle.
- Add `var notBackedUpSummary: String?`: nil unless `offersNewPhotosOnly` and `toGoCount != nil`. It returns "1,243
  not backed up", "about 1,200 not backed up" or "all backed up".

**Uncloud/Views/NewPhotosViews.swift**: `primaryExportHelp` returns `offersNewPhotosOnly ? NewPhotosTitle.newOnlyHelp
: nil`. It no longer compares titles, because the title now carries a number.

**Uncloud/Views/ExportView.swift**: `countText` adds ` · \(model.notBackedUpSummary)` after the selection count and
before the size. The toolbar button adds `.accessibilityHint(model.primaryExportHelp ?? "")`.

**Uncloud/Views/BackupHero.swift**: `exportButton` adds the same `.accessibilityHint`. The title and help already
come from the model.

**Uncloud/App/ExportCommands.swift**: no change. The menu shares the title.

### 1.5 Tests

- **UncloudTests/NewPhotosTests.swift** — update `primaryTitle` (around line 165) for the new parameters and add
  these cases:
  - backed up > 0, N = 1,243, everything → "Export 1,243 New Photos"; N = 1 → "Export 1 New Photo"
  - backed up > 0, N nil (approximate or unknown) → "Export New Photos"; N = 0 → "Export New Photos"
  - backed up = 0, no status → "Export All Photos" (first export unchanged); backed up = 0, status → "Export New Photos"
  - partial selection with backed up > 0 → fallback "Export 3 Photos"
  - paused, interrupted or needing a folder still win over the new-photos title
  - `exportNewPhotos(count:)` uses singular and plural and groups thousands
  - `offersNewOnly` matches the table
- **UncloudTests/ResumeExportTests.swift**: `primaryExportTitle == "Resume Export"` (lines 84, 93) must still pass,
  because an interrupted run wins. `otherwiseTheTitlesAreUnchanged` (`exportTitle`) is unchanged.
- **New ExportModel test**, in NewPhotosTests or SessionsAndDriveCheckTests next to line 239 (which already checks
  `onDriveSummaryText` against a fixture): after a completed Photos on This Mac or fake-iCloud run, with the
  manifest written and no watermark (the test host never saves one), `primaryExportTitle` reads "Export New Photos"
  and **not** "Export All Photos". Before any run it reads "Export All Photos". `offersNewPhotosOnly` is true after
  the run. This reproduces the owner's case.
- **Free:** in EntitlementGatingTests, a test with a **free** preview account checks that a model with backed-up
  photos still offers new photos only. `ExportModel` has no account dependency, so the test pins
  `offersNewPhotosOnly` with `isFeatureAllowed` set to deny everything.
- **UncloudTests/NewPhotosSnapshotTests.swift:75–77**: the snapshot (env-gated) may now show a number. Re-record it
  if the run is enabled. No assertion change.

---

## Part 2. Clean Up iCloud Becomes Uncloud Plus (Whole Pane)

### 2.1 Today (387d7ad)

`CleanupGridView` locks only `.library` mode (`isLibraryLocked`). For free accounts, `onAppear` switches the pane to
`.recentlyDeleted`. The mode picker shows a locked "Library" segment, and `chooseMode` opens the paywall.
`mayStart(mode:allowsCleanUp:)` returns true for `.recentlyDeleted`. The sidebar row "Clean Up iCloud" has no lock.
The account-paywall plan's owner decision 3 says Recover is free.

### 2.2 Change

Free accounts get the whole pane locked, the way Browse Backup is locked. A run already in progress (a delete, or a
recovery that started while subscribed) keeps its grid and finishes (plan §5.5).

- **Uncloud/Views/MainWindow.swift**
  - Sidebar: replace `Label("Clean Up iCloud", systemImage: "icloud")` with
    `LockableSidebarRow(title: "Clean Up iCloud", symbol: "icloud", isLocked: !account.allows(.cleanUpICloud))`.
  - Detail `.cleanup`: show `CleanupView()` when `account.allows(.cleanUpICloud) || model.iCloudCleanup?.isRunning == true`,
    otherwise `LockedFeatureView(feature: .cleanUpICloud)`. Both use `.navigationTitle("Clean Up iCloud")`.
  - `.onChange(of: model.pane)`: also run `if pane == .cleanup, !account.allows(.cleanUpICloud) { account.require(.cleanUpICloud) {} }`.
    ⌘4 (ExportCommands.swift:82) sets `model.pane`, so it is covered.
- **Uncloud/Views/Account/LockedFeatureView.swift**: add a `PaidFeature.lockedNote: String?` (in AccountTypes.swift)
  and show it under the description as a second `Text` in `.secondary`. For `.cleanUpICloud` it reads:
  "Photos you deleted stay in Recently Deleted for 30 days. You can recover them there in the Photos app or on
  iCloud.com." All other features return nil.
- **Uncloud/Views/CleanupView.swift** (`CleanupGridView`)
  - Remove `isLibraryLocked`, the `onAppear` switch to Recently Deleted, the locked "Library" segment, and
    `chooseMode`, so the picker calls `cleanup.setMode`. Remove the `isLibraryLocked` terms in `.disabled` and in
    `focusedValue`. The pane-level lock replaces them.
  - Keep `account` for the lapse check. `mayStart(mode:allowsCleanUp:)` now returns `allowsCleanUp` for **both**
    modes, so a recovery whose confirmation was opened before a lapse is refused like a delete. Apply the same
    `mayStart` guard to the `CleanupRecoverySheet` confirm path.
  - Update the doc comments that say Recently Deleted "stays free".
- **Uncloud/Account/AccountTypes.swift**: the `cleanUpICloud` summary stays as it is ("Deletes backed-up photos from
  iCloud, and recovers them if you change your mind."), and so does the title. `PaidFeature.allCases` already lists
  it, so the **paywall feature list** (PaywallSheet.swift:88) and the **WelcomeView** grid need no change. WelcomeView's
  only "Free" badge is on Export, which stays correct. Update the FeatureRow.swift:8 comment only if it mentions
  Recover; it doesn't.
- **.claude/design/account-paywall-plan.md**: under "Owner decisions", replace decision 3 with: "**3 (revised
  2026-10-18): Clean Up iCloud is Uncloud Plus as a whole, including Recently Deleted and Recover.** Free users see
  the locked pane and the paywall. Photos stay recoverable for 30 days in Recently Deleted in Apple's Photos app or
  on iCloud.com, and the locked view says so. A run in progress finishes after a lapse." Line 29 and line 344
  already say "Clean Up iCloud (incl. Recover)" is paid, so they now agree.

### 2.3 Tests

- **UncloudTests/EntitlementGatingTests.swift** `deleteRefusedAfterLapse`: rename it to "Deleting and recovering
  that start after the plan lapsed are both refused". It now expects
  `mayStart(mode: .recentlyDeleted, allowsCleanUp: false) == false`, while `.library`/false stays false and both
  modes with true are true.
- Add a test that `PaidFeature.cleanUpICloud.lockedNote` contains "30 days" and "iCloud.com", and that every other
  feature's `lockedNote` is nil.
- Add a pure helper `MainWindow.showsCleanup(allowed: Bool, isRunning: Bool) -> Bool` (static), returning
  `allowed || isRunning`, with a test for all four combinations. MainWindow uses it.
- Off accounts: `offAllowsEverything` already covers them, and nothing locks.
- AccountSnapshotTests (env-gated) "locks": re-record so it includes the Clean Up iCloud lock in the sidebar.

---

## Build chunk (one, for a Haiku engineer)

**Chunk N1: New photos only + Clean Up iCloud paid**

Owned files (edit only these):
- Uncloud/Model/NewPhotos.swift
- Uncloud/Model/ExportModel.swift (only `primaryExportTitle` and the two new computed properties next to it)
- Uncloud/Views/NewPhotosViews.swift
- Uncloud/Views/ExportView.swift
- Uncloud/Views/BackupHero.swift (`exportButton` hint only)
- Uncloud/Views/MainWindow.swift
- Uncloud/Views/CleanupView.swift
- Uncloud/Views/Account/LockedFeatureView.swift
- Uncloud/Account/AccountTypes.swift (`lockedNote` only)
- UncloudTests/NewPhotosTests.swift, UncloudTests/EntitlementGatingTests.swift,
  UncloudTests/SessionsAndDriveCheckTests.swift (new test only)
- .claude/design/account-paywall-plan.md (decision 3 text only)

Acceptance criteria:
1. With a backup folder that has backed-up photos from the current source and everything selected, the Export
   toolbar, the Backup hero and Backup › ⌘R read "Export N New Photos" when the count is exact and N > 0, and
   "Export New Photos" otherwise. This holds whether or not a New Photos watermark exists.
2. The first export to an empty folder still reads "Export All Photos". A partial selection still reads "Export N
   Photos". Paused and interrupted runs still read "Resume" / "Resume Export". No folder still reads "Choose Backup
   Folder…".
3. The help and VoiceOver hint read "Exports only photos that aren’t in your backup yet. Photos already backed up are
   never exported twice." The Export subtitle adds "· N not backed up" ("about", or "all backed up", as specified).
4. The export behavior doesn't change: the same `performPrimaryAction` path runs, and nothing is copied twice. No
   `AccountModel` or `isFeatureAllowed` check is added to the export path or the title, so it is free for every
   account.
5. For a free account, the Clean Up iCloud sidebar row shows a lock with the accessibility value "Requires Uncloud
   Plus". Choosing the row or pressing ⌘4 shows `LockedFeatureView` with the 30-day Recently Deleted note and opens
   the paywall. A cleanup run already in progress keeps its grid.
6. Plus and `off` accounts see the Clean Up iCloud pane exactly as before, with Library and Recently Deleted and no
   lock. Neither mode is locked inside the pane anymore.
7. Recover confirmed after a lapse is refused (`mayStart` false), the same as Delete.
8. All tests in 1.5 and 2.3 pass in `UncloudTests`, including the existing ResumeExportTests and NewPhotosTests
   cases after their update. No other test changes its expectations.
9. The strings follow the polish-plan glossary: buttons are title case ("Export 1,243 New Photos"), status text is
   sentence case ("1,243 not backed up"), "backed up" / "not backed up" is the only term for state, and apostrophes
   are curly.
