# Export sessions, "Check the drive", continue-where-it-left-off, and "All in One Folder"

Status: plan only (nothing implemented). Author: architect run, 2026-10-12.
Builds on the auto-resume work that is in flight (`Uncloud/Model/AutoResume.swift`, ExportModel `autoResume`,
`ProgressCard.AutoResumeStatus`). **No task below starts until auto-resume has merged and QC passed it** (task T0).

User requests:
1. "save each export session by date time and then when users start another export to the same hard drive, it should
   first check the files on the hard drive folders and then continue from where it left off — meaning should not
   start the export process from scratch."
2. "allow users to export everything from icloud as it is as an option (no categorization by month year etc if not
   wanted by the user)".

---

## 0. What the code does today (verified)

| Area | Fact | Consequence |
| --- | --- | --- |
| Manifest | `.photo-export/` has `exported.tsv` (id → paths, append-only), `checksums.tsv` (path → sha256), `layout`, `run-in-progress`. No file sizes, no session history. | Can't detect truncated files cheaply; no history. |
| PhotoKit | `ExportEngine` skips IDs in the manifest, emits `.prepared(total, alreadyExported)`. | Already "continues"; counts are right. |
| iCloud, everything | `ICloudExportEngine` runs the icloudpd process. icloudpd pages the whole library (`startRank` 0, ASCENDING, 100 per page ≈ 930 CloudKit queries for 93k) and stats each file ("already exists"). Engine emits `.prepared(total, 0)` and one `.skipped` per existing file. | Progress starts at 0 and climbs through skips: looks like "from scratch". Every auto-resume after a 503 re-pages the done prefix (600+ extra queries at 60k done), which itself invites more throttling. |
| iCloud order | Code and bridge docs agree: icloudpd's order is **oldest first** (`ICloudPageFetching`, `AssetSizeIndex.scanStart`: "new items come last"). `ICloudPageCache` reverses it for the newest-first browser. Sorted by **asset date**, so a back-dated item (scan, Shared Library import, saved WhatsApp image keeping its date) is inserted in the middle. | A "resume rank" must be verified; new photos land at the high-rank end. |
| icloudpd log paths | `Downloaded %s` / `%s already exists` use `truncate_middle(path, 96)`. The bridge patches this away; `Vendor/icloudpd-runtime/run_icloudpd.py` does not. | icloudpd-process paths are unreliable for long paths; that's why `ICloudChecksumScanner` walks folders. |
| Checksum scanner | Records every new file under the run folder as `icloud:<path>` + sha256. In month layout only `YYYY/MM/name`. Hashes inline. | First scan of a drive with an old icloudpd-CLI export hashes the whole drive (hundreds of GB). Flat layout can't use a path pattern. |
| Idle "X of Y" (iCloud) | `ExportModel.iCloudProgress` counts `icloud:` **file** records. | Over-counts: Live Photo `.MOV`s and `.xmp` sidecars are counted as items. |
| Bridge download | `allExcept` still iterates the whole album (`for asset in album`); `only` uses rank hints unless > 30 % of the library. Events carry `asset` (ID) and full `path`/`paths`. | Bridge already gives ID + full path per item; it can start at an offset (`fetch_assets(view.offset=…)`). |
| Bridge errors | Per-item download exceptions become `failed` events. A 503 during a download would be a per-item failure, not a run-ending `serviceUnavailable`. | Must be fixed before full exports go through the bridge, or auto-resume won't trigger. |
| icloudpd flags | `--recent N` = first N in walk order (oldest); `--until-found N` stops after N consecutive existing (useless when the walk starts at the oldest); `--skip-created-before/after` filter **after** each page is fetched. None skips paging. | Option (b) rejected. |
| Layout switch | BackupPane warning says "They'll stay where they are, and new items will use the layout you choose here." | True for PhotoKit (ID skip). **False for iCloud**: icloudpd only checks paths in the new layout, so it downloads the whole library again. |
| PhotoKit `relativePath(of:in:)` | `"\(folderPath)/\(name)"`. | With a flat layout (`""`) it would record `/IMG_0001.HEIC`. Must fix. |
| icloudpd mtime | `download.update_mtime(created_date, …)` sets file mtime to the photo's creation date. | "mtime ≥ run start" can't identify exported files. |

---

## 1. Export sessions

### 1.1 Decision: one file per run attempt, linked into chains

An auto-resumed run is a **new session file linked to the first one** (`chainID`, `attempt`), not a rewrite of
the original:

- Each file is written by exactly one run, so crash safety is simple (only the running file is ever rewritten).
- Per-attempt start/end times and counts stay exact ("3:10–3:52, 1,204 downloaded, stopped: Apple is limiting
  downloads"), which is what a user debugging throttling wants.
- The History list groups a chain into one row ("Export · 3 attempts · completed"), so it still reads as the same
  session continuing. Manual Resume after a cancel/failure **also** continues the chain when it starts within 24 h
  with the same source, account, layout and selection kind; otherwise it starts a new chain.

### 1.2 Data model (`Uncloud/Export/ExportSession.swift`)

```swift
struct ExportSession: Codable, Identifiable, Sendable {
    var schema = 1
    var id: UUID
    var chainID: UUID              // == id for the first attempt
    var attempt: Int               // 1-based within the chain
    var kind: Kind                 // .export, .verify, .driveCheck
    var trigger: Trigger           // .manual, .exportAll, .automaticBackup, .autoResume, .resume
    var startedAt: Date
    var updatedAt: Date            // heartbeat, written at every checkpoint
    var endedAt: Date?
    var appVersion: String         // "0.1.4 (14)"
    var launchID: UUID             // one per app launch; tells "mine, still running" from "orphaned"
    var source: LibrarySource      // "iCloud" | "photosLibrary"
    var account: String?           // hashed, see 1.5; nil for photosLibrary
    var layout: FolderLayout
    var writesSidecars: Bool
    var selection: SelectionSummary   // { kind: everything|only|allExcept, count: Int } — never IDs
    var libraryCount: Int?
    var driveCheck: DriveCheckSummary?  // onDrive, toGo, missing, damaged, setAside, untracked, mode, seconds
    var continuation: Continuation?     // strategy: fullWalk|fromRank|selection, startRank, fallbackReason
    var counts: Counts             // exported, skipped, failed, bytesWritten
    var result: Result             // status + reason
    var autoResume: AutoResumeNote?     // { attempt, resumeAt } when this attempt ended into a scheduled resume
    var failures: [Failure]        // first 50 { name, reason }; total in counts.failed
}
enum Status: String, Codable { case running, completed, completedWithFailures, cancelled, failed, interrupted }
struct Result: Codable { var status: Status; var reason: String?; var retryable: Bool? }
```

"Waiting to auto-resume" is **derived**, not stored as a status: `status == .failed && retryable == true &&
autoResume != nil` and it is the last attempt in its chain and `ExportModel.autoResume` is pending. If the app quit
meanwhile, the same file reads as "Stopped: Apple is limiting downloads" with Resume offered. This avoids having to
rewrite an older file when the resume starts, and stays truthful if the resume never happens.

Unknown JSON keys are ignored on read; a file with `schema > 1` is shown read-only ("made by a newer Uncloud").

### 1.3 Storage

- `DEST/.photo-export/sessions/2026-10-12T14-03-27Z-1f3a9c.json` — UTC start time, hyphens instead of colons (exFAT,
  FAT32 and SMB safe), plus the first 6 hex of `id` so two sessions in the same second can't collide.
  Lexicographic order = chronological order.
- Travels with the drive and survives reinstall. **No app-side mirror**: when the drive isn't connected the History
  section says "Connect “Backup Drive” to see its export history." `lastBackupDate` in UserDefaults stays as is.
- Writes never fail an export: a session write error is logged once to Activity ("Couldn't save the export history
  on this drive") and the run continues.

### 1.4 Atomic writes and crash safety (`Uncloud/Export/SessionStore.swift`)

- Write `sessions/.<name>.tmp` (JSONEncoder, `.sortedKeys`, ISO 8601 dates), `fsync`, then
  `FileManager.replaceItemAt`/`moveItem` (same pattern as `ExportManifest.replaceFile`). Readers skip dotfiles and
  any file that doesn't decode.
- `SessionRecorder` (main actor) checkpoints on: start, the first `.prepared`, every 30 s **or** 500 finished items
  (whichever first), pause/resume, and the end. Cost: one ~2 KB rewrite per 30 s.
- At launch, on destination change and when a drive mounts: any session with `status == .running` whose
  `launchID != currentLaunchID` **and** `updatedAt` older than 2 minutes is rewritten as `.interrupted`
  (reason "Uncloud quit or the Mac restarted while exporting", `endedAt = updatedAt`). The 2-minute guard protects a
  second Mac writing to the same network drive. `ExportManifest.hasIncompleteRun` is unchanged and still drives
  the Resume button.

### 1.5 Privacy

- `account` = first 16 hex of SHA-256 over `"uncloud-account-v1:" + appleID.trimmed.lowercased()` — reuse the
  normalisation in `AssetSizeStore.fileURL(account:)`. Pseudonymous (lets History say "a different iCloud account"),
  never the Apple ID. Note in the code that it is guessable from a known email; that's acceptable for a file on the
  user's own drive.
- No asset IDs, no file names except in `failures` (file names only, already shown in Activity), no paths outside
  the destination, no host name.

### 1.6 Retention

Keep at most **1,000 files or 8 MB** in `sessions/`; when over, delete whole oldest chains (never a `.running`
file, never the newest chain). Pruned after each finished session. A file is capped at ~16 KB by the 50-failure cap.

---

## 2. "Check the drive" pre-flight

### 2.1 What is new on disk

- `exported.tsv` gains a third record kind, alongside PhotoKit `localIdentifier` and legacy `icloud:<path>`:
  **`icloud-id:<assetID>\t<path>\t<path>…`**, written from bridge `downloaded`/`skipped` events (they carry the asset
  ID and full paths). Old readers treat it as an opaque ID, so older app versions don't break.
- `.photo-export/files.tsv` — a **snapshot** (rewritten atomically, not appended) of `path\tsize\tmtime` for every
  file the manifest knows, plus `dir\t<relative dir>\t<dir mtime>` lines. Used for size-mismatch detection and for
  the quick check.
- `.photo-export/resume.json` — the iCloud resume point (section 3).
- `.photo-export/set-aside/<session id>/<original relative path>` — damaged files moved out of the way (2.3).

### 2.2 Inventory (`Uncloud/Export/DriveInventory.swift`)

`FileManager.enumerator` with prefetched `[.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]`,
`.skipsHiddenFiles`; ignores `.part`, `.partial`, `.photo-export`. Runs in `Task.detached(priority: .utility)`,
checks cancellation every file, reports progress every 1,000 files. Stat only — **never hashes**.

- **Quick mode** (before every export, and every auto-resume): re-lists only directories whose mtime differs from
  `files.tsv`, and stats every manifest file in those. Month layout: ~300 directories, typically < 1 s.
- **Full mode** (Backup Tools > Check Drive, first check of a drive without `files.tsv`, and the flat layout, where
  the single directory always changes): stats everything.
- Budget: 100k files ≤ 10 s on an APFS SSD, ≤ 90 s cold on a USB HDD; UI never blocked; Cancel stops within
  100 ms; progress "Checking your drive… 41,000 of ~93,000 files".

### 2.3 Reconcile (`Uncloud/Export/DriveCheck.swift`)

Inputs: manifest records + checksums, previous `files.tsv`, the inventory, layout, source. Output `DriveCheckReport`:

| Finding | Rule | Action |
| --- | --- | --- |
| **On drive** | record whose every file exists with the recorded size (or no recorded size yet). | Counted. |
| **Missing** | record with a file that's gone. | `ExportManifest.forget([id])` so the item is exported again. For iCloud the walk re-downloads it anyway; forgetting keeps counts honest. |
| **Damaged / truncated** | file size ≠ `files.tsv` size, or 0 bytes. | Move the file to `set-aside/<session>/…` (never delete), then `forget`. Required for iCloud: icloudpd would otherwise see "same name, different size" and download a second copy to `NAME-<size>.ext`, leaving the bad file in place. |
| **Untracked, iCloud month/album** | file under an icloudpd path (`YYYY/MM/name`, or inside an album folder) with no record. From an icloudpd CLI export, an older Uncloud, or a crash between write and record. | Register as `icloud:<path>` with size only; hashing is deferred to the background checksum backfill (2.5). Same path rule as `ICloudChecksumScanner.isDownloadPath` (move it into a shared helper). |
| **Untracked, PhotoKit or flat** | any other non-hidden file. | Not registered. Counted as "other files in this folder" (shown in the flat layout, see 7c). |

### 2.4 "Already on this drive" vs "to go" for the current selection

- **PhotoKit:** exact by ID: `selection ∩ manifestIDs − missing − damaged`.
- **iCloud, items with `icloud-id:` records:** exact by ID, same formula.
- **iCloud, legacy `icloud:<path>` records only:** path-level, grouped into items: drop `.xmp`, drop a `.MOV`/`.mov`
  whose stem matches an image in the same folder (Live Photo with `--live-photo-mov-filename-policy original`).
  Shown as "about 9,200 already on this drive" until a bridge walk has replaced them with ID records.
  Mapping legacy paths to IDs by reimplementing icloudpd's naming in Swift is **rejected** (filename cleaner, RAW
  disambiguation, `-original`, dedup suffixes — it would drift). The first bridge walk maps them for free: its
  `skipped` events carry ID + path.
- `toGo = selectedCount − onDrive` (clamped ≥ 0); `selectedCount` from `LibrarySelection.selectedCount(total:)`
  with `ICloudLibrary.cachedLibraryCount`. The bytes still to copy come from `AssetSizeIndex` when it's complete,
  else the existing proportional `StorageCheck.remainingBytes`.
- This replaces `ExportModel.iCloudProgress`, which fixes the Live Photo/XMP over-count.

### 2.5 Checksum backfill

Files registered without a hash (pre-flight, or an icloudpd `already exists` event) are queued in memory and hashed by
the existing scanner path **while the export runs and the drive is otherwise idle**, at most 1 file in flight, and
by Verify Backup. Until hashed, Verify reports them as "unverifiable", as it does today for old exports.

### 2.6 When it runs

1. Idle, when a destination is set/restored/mounted, or the selection changes: quick mode, then show the summary.
2. Inside `startExport`, after `phase = .preparing` and the run number is claimed (so Cancel's watchdog covers it),
   before the engine starts. Quick mode. Result passed into the engine (2.4 counts, the `icloud-id` set, missing IDs).
3. Before every auto-resume: quick mode. A missing drive is already handled by auto-resume (`isWaitingForDestination`).
4. Backup Tools > **Check Drive**: full mode with a result sheet.

---

## 3. Continue from where it left off without re-walking

### 3.1 Options

| Option | Saves paging? | Correct with added/deleted items? | Verdict |
| --- | --- | --- | --- |
| (a) bridge `allExcept(exportedIDs)` | **No**: the bridge still iterates every page; it only skips the `stat`/log. | Yes. | Part of the answer (it gives IDs, full paths and no fake progress), not enough alone. |
| (b) icloudpd `--recent`, `--until-found`, `--skip-created-*` | No (see section 0). | — | Rejected. |
| (c) bridge from a stored resume rank, verified by an anchor | **Yes**: starts paging at `R − margin`. | Yes, **with** anchor verification and a fallback full walk. | **Chosen** for "everything" in month and flat layouts. |
| (d) start progress at the already-exported count, make skips cheap | No. | Yes. | **Always on**, all sources and layouts. It fixes the "from scratch" look by itself. |

### 3.2 Chosen design: (d) everywhere + (a)+(c) for iCloud "everything" in month/flat layouts

**Move iCloud full exports (month and flat layouts) from the icloudpd process to the bridge's `download`**
(`mode: allExcept`). The bridge downloads with icloudpd's own `download_builder`, so paths and names are
byte-identical, and a later icloudpd run (or the album-layout process path) still says "already exists". What this
gives:

- an asset ID, rank and full path for every item → exact `icloud-id:` records, exact counts and resume points;
- an offset start (`fetch_assets` already sets `view.offset`);
- no 96-character truncated paths;
- one sign-in shared with browsing.

The album layout stays on the icloudpd process (one run per album, albums are small) and gets (d) only. A hidden
`UserDefaults` switch `iCloudFullExportsUseBridge` (default on) keeps the process path available as a fallback.

**Resume point** (`.photo-export/resume.json`, per destination):

```json
{ "schema": 1, "account": "a1b2…", "layout": "month", "libraryCount": 93015,
  "coveredThrough": 9207, "anchor": { "id": "AVk3…", "rank": 9206 }, "updatedAt": "…" }
```

- `coveredThrough` R = length of the **contiguous prefix of ranks** (from rank 0, or from the verified start of
  this walk) for which every item is downloaded or confirmed existing. The first `failed` item freezes R for the
  rest of the run, so failures are never jumped over. Pausing/cancelling keeps R. Written at each session
  checkpoint and at the end.
- The anchor is the item at rank R−1.

**Start-up decision** (in `ICloudExportEngine`, Opus-owned):

1. No resume point, different account/layout, or R < 500 → full walk from rank 0 (`allExcept(icloud-id set)`).
   This is the one-time cost on a legacy drive; its `skipped` events convert legacy records into ID records.
2. Otherwise ask the bridge for the window `[R − 200, R + 200)` (one or two pages) and find the anchor.
   - Found at rank R−1 **and** every ID in `[R−200, R−1]` is in the `icloud-id` set → **start at R − 200**. The
     overlap re-checks 200 items cheaply.
   - Anchor moved, missing, or the overlap has an unknown ID → **full walk**, reason stored in the session
     (`continuation.fallbackReason`: "Items were added to or removed from older parts of your library").
3. Before the offset run, items the pre-flight found **missing or damaged below R** (they have IDs) are downloaded
   with `mode: only` and the browser's rank hints, so holes below the offset are filled without a walk.
4. **Weekly safety sweep:** if the last full walk on this drive (stored in `resume.json` as `lastFullWalkAt`) is
   older than 7 days, the run does a full walk anyway. This covers the one case the anchor can't see (a back-dated
   insert and a deletion below R in the same interval cancel out).

Why this is correct:
- New photos have the newest asset date → highest ranks → always ≥ R → included.
- Deletions below R shift the anchor down → fallback. Deletions above R don't matter.
- Back-dated inserts below R shift the anchor up → fallback.
- An item deleted between sessions that's already on the drive stays on the drive (we never delete), exactly as
  icloudpd behaves.
- The rank model assumes oldest-first order, which the code assumes in three places. **T0 confirms it once with a
  real account** (open question 4): if the order turned out to be newest-first, swap to "covered suffix from the
  newest" in one place; the anchor logic is symmetric.

**Progress (d):** the engine emits `.prepared(total: selectedCount, alreadyExported: onDrive)` from the pre-flight.
Bridge `skipped` events for IDs the pre-flight already counted emit **nothing**; a skip of an unknown ID (legacy
file) emits `.skipped`, which correctly adds to processed. Bridge `progress.total` (items this run visits) is
translated: `appTotal = onDrive + bridgeTotal − alreadyCountedInRange`; the engine owns this arithmetic and has
tests. For the album-layout icloudpd path, which has no IDs: `.prepared(total, 0)` as today, but while only skips
have arrived ProgressCard reads "Checking photos already on this drive…" instead of a climbing export count.

**Bridge prerequisites** (Opus): `download` accepts `startRank` and `layout: "none"`; every item event carries
`rank`; `allExcept` checks `asset.id in ids` before `process` (it already does) so done items cost no `stat`; a
503/"temporarily refusing to serve" during a download **ends the download with an error event** (kind mapped to
`.serviceUnavailable` by `ICloudBridge.error(kind:message:)`) instead of failing item after item, so auto-resume
triggers as it does for the process path. Large `ids` lists (~90k IDs ≈ 4 MB JSON) are fine in one request line;
the reader must not have a line-length cap (check `Channel.feed`).

---

## 4. UX (the designer agent refines visuals)

**Idle, Backup pane "Export" section** (replaces the "X of Y" line when a check exists):
- While checking: spinner + "Checking your drive…" + small "41,000 of about 93,000 files".
- Then: **"9,207 already on this drive · 83,808 to go"**, with "about" when path-level (2.4). Secondary caption:
  "Last export: Yesterday at 22:14 · stopped: Apple is limiting downloads." (from the newest session).
- If damaged or missing were found: orange "12 files were missing or damaged and will be downloaded again. Show…"
  (opens the Check Drive sheet).
- Primary button: "Continue Export (83,808 to go)" when onDrive > 0, else "Start Export"; "Resume" keeps its
  current meaning when `run-in-progress` exists.

**Starting an export:** phase `.preparing` shows "Checking your drive…" (cancellable), then the progress card starts
at **9,207 of 93,015** with "Continuing from where the last export stopped" in Activity. If the fast path fell back
to a full walk: Activity note "Your library changed in older months, so Uncloud is checking all of it. Items already
on the drive are skipped." First check of a legacy drive: "First check of this drive takes a little longer."

**Export History** (new section in the Backup pane under Backup Tools, also a "Show All…" sheet):
- Rows grouped by chain, newest first: date and time ("Today, 14:03"), a result badge (Completed, Completed with
  12 failures, Cancelled, Stopped, Interrupted, **Resuming at 15:10** for the live pending one), counts
  ("1,204 downloaded · 9,207 already there · 3 failed · 4.1 GB"), attempt count ("3 attempts"), and an "Automatic"
  tag for automatic backups and auto-resumes.
- Detail sheet: per attempt start–end, trigger, source, layout, selection summary, drive-check summary,
  continuation strategy and fallback reason, failures list, app version, "a different iCloud account" if the hash
  differs from the signed-in one.
- "Show in Finder" reveals `.photo-export/sessions` (`NSWorkspace.activateFileViewerSelecting` on the newest file —
  works for a hidden folder).
- Drive not connected: "Connect “Backup Drive” to see its export history."

**Auto-resume:** each auto-resume is a new attempt in the same chain; the History row shows the live "Resuming at
HH:MM" state from `ExportModel.autoResume`. The quick check runs before each resume and costs ~1 s.

**Verify Backup:** writes a `kind: .verify` session ("Verified 9,207 items · 2 damaged"). Damaged items found there
use the same set-aside + forget path as the pre-flight. Check Drive is the cheap size/presence check; Verify is the
slow hash check. The Backup Tools copy says so.

---

## 5. Work breakdown

Rules for every task: one owner file set; build with zero new warnings; run the suite with the commands in
`.claude/agents/quality-control.md` (isolated `UncloudTestHost`, `ICloudAccount.helperOverride` pointing at
`UncloudTests/Fakes/fake_bridge.py` / `fake_icloudpd.py`); no real Apple ID ever. **H** = Haiku, **O** = Opus.

### T0 — Gate (O)
Auto-resume merged and QC green. Confirm with the user (open question 4) that icloudpd order is oldest-first by
running the browser on their account and comparing rank 0's date with the last rank's date. Agree the hook points in
`ExportModel` (`startExport`, `apply`, `finish`, `scheduleAutoResume`, `stopForTermination`) with whoever owns
auto-resume now.

### Phase A — Sessions
| # | Owner | Files | Acceptance criteria / tests |
| --- | --- | --- | --- |
| A1 | H | `Uncloud/Export/ExportSession.swift` (new) | Types from 1.2. `ExportSessionTests`: JSON round-trip; unknown keys ignored; `schema: 2` decodes as read-only; no field holds an Apple ID (encode a session with `account: hash("a@b.c")`, assert the JSON doesn't contain "a@b.c"). |
| A2 | H | `Uncloud/Export/SessionStore.swift` (new) | File naming (no `:`; sortable; collision suffix); atomic write via tmp + replace; `list()` skips dotfiles and undecodable files; `markInterrupted(currentLaunch:olderThan:)`; `prune(maxFiles:maxBytes:)` deletes whole oldest chains and never `.running`. Tests in temp dirs, including a half-written `.tmp` and a corrupt JSON. |
| A3 | H | `Uncloud/Model/SessionRecorder.swift` (new) | Accumulates an `ExportBatch`; checkpoints at 30 s or 500 items with an injected clock; `finish(status:reason:retryable:autoResume:)`. Unit tests with a fake clock and store. |
| A4 | **O** | `ExportModel.swift` (hooks only), `ExportRun.swift` (`.exported` gains optional `bytes`), engines (fill `bytes`) | Session written for start/finish/cancel/fail; chain + attempt on auto-resume and on manual Resume ≤ 24 h; interrupted sweep at launch/mount. Tests (extend `ExportCancellationTests`/`AutoResumeTests` with shortened `AutoResumeTiming`): complete → `.completed`; cancel → `.cancelled`; `fake_icloudpd --throttle-after 5 --throttle-runs 1` → attempt 1 `.failed, retryable, autoResume` and attempt 2 `.completed`, same `chainID`; kill mid-run (simulate stale `updatedAt` + other launchID) → `.interrupted`. |
| A5 | H | `Uncloud/Views/ExportHistoryView.swift` (new), `BackupPane.swift` (one section insert) | Section + detail sheet + Show in Finder as in 4. Preview with fixture sessions. Designer pass afterwards. |
| A6 | H | `README.md` | "Files in the destination" lists `sessions/`, `files.tsv`, `resume.json`, `set-aside/`, the `icloud-id:` record kind. |

**QC checkpoint 1** (quality-control agent): suite green, sessions folder appears on a temp destination after a fake
export, a corrupt session file doesn't break the pane, nothing written outside `.photo-export/`.

### Phase B — Check the drive
| # | Owner | Files | Acceptance / tests |
| --- | --- | --- | --- |
| B1 | H | `Uncloud/Export/DriveInventory.swift` (new) | Quick and full modes, progress callback, cancellation. Tests: ignores dotfiles, `.part`, `.partial`, `.photo-export`; quick mode lists only changed dirs (touch one dir, assert only it is listed); cancellation within 100 ms; perf test with 20,000 generated files < 5 s (logged, not a hard CI failure). |
| B2 | H | `ExportManifest.swift` (additions only) | `filesSnapshot` read/write (atomic); `recordICloudItem(id:paths:)` writing `icloud-id:`; `setAside(paths:session:)` moving into `set-aside/<session>/…` with folders; `forget` unchanged. Extend `ExportManifestTests`. |
| B3 | **O** | `Uncloud/Export/DriveCheck.swift` (new); move `isDownloadPath` to a shared helper | Rules of 2.3 and 2.4. Tests with fixture trees: missing → forgotten; truncated → set aside + forgotten; untracked month file → registered without hash; user's own `notes.txt` in root never registered; Live Photo pair + `.xmp` count as one item; `icloud-id` exact counts vs selection `.only`/`.allExcept`. |
| B4 | **O** | `ExportModel.swift` | Pre-flight in `startExport` (cancellable during `.preparing`), idle refresh replacing `iCloudProgress`, `driveCheck` observable state, Check Drive action; report passed to engines. Tests: cancel during check → `.cancelled`, no engine launched (fake launch log stays empty); counts after a fake export equal `exported`. |
| B5 | H | `ProgressCard.swift`, `BackupPane.swift`, `BackupToolSheets.swift` | UI strings of section 4; Check Drive sheet with missing/damaged lists and "Download Again". |

**QC checkpoint 2:** 100k-file synthetic destination (script in scratch, not committed): quick check < 2 s, full
check within budget, UI responsive while checking, Cancel works; legacy-drive fixture (icloudpd-style tree with no
`.photo-export`) shows "about N already on this drive" and nothing is hashed during the check.

### Phase C — Continue without re-walking (highest risk)
| # | Owner | Files | Acceptance / tests |
| --- | --- | --- | --- |
| C1 | **O** | `Uncloud/Helper/photo_bridge.py` | `startRank`, `rank` in item events, `layout: "none"`, run-ending throttle error, no line-length cap. `UncloudTests/Bridge/test_bridge.py` (via `scripts/test-bridge.sh`): offset start pages from `startRank` only; 503 ends the download with an error event; `layout none` passes `--folder-structure none`; paths equal `download_builder`'s. |
| C2 | H | `UncloudTests/Fakes/fake_bridge.py` | Same protocol additions; flat `item_path`; `--insert-at RANK` / `--delete-at RANK` (library changes between launches, state file); `--throttle-after N`; logs the `startRank` it was asked for to `--launch-log`. |
| C3 | H | `Vendor/icloudpd-runtime/run_icloudpd.py` | Patch `icloudpd.base.truncate_middle` to identity, as the bridge does. `ICloudOutputParserTests` unchanged and green; check `scripts/build-icloudpd.sh` still copies the file and its pin/checksum logic (if any) is updated. |
| C4 | **O** | `ICloudExportEngine.swift`, new `Uncloud/Export/ICloud/ResumePoint.swift` | Full exports (month/flat) via the bridge behind `iCloudFullExportsUseBridge`; `icloud-id:` records from events; hashing of downloaded paths after settle; R tracking and `resume.json`; anchor check; fallback; missing-below-R `only` pass; weekly sweep; prepared/total arithmetic. Fake-bridge tests: (1) session 2 starts at R−200 (launch log); (2) items appended to the library between sessions are downloaded; (3) `--insert-at` below R → full walk, no gap (every fake asset has a file); (4) `--delete-at` below R → full walk; (5) a failed item at rank k → R ≤ k; (6) progress starts at onDrive and never exceeds total; (7) throttle → `.serviceUnavailable` → auto-resume schedules and the resumed run starts from R. |

**QC checkpoint 3 (Opus review + QC):** a deep review of C1 and C4 by Opus; then one **manual run with the user's
real account** on a small test folder: session 1 cancelled at ~300 items, session 2 shows "≈300 already on this
drive", starts at the offset (diagnostic log), and the final tree is identical (`diff -r` of names and sizes) to a
plain icloudpd run into a copy of the same folder, with icloudpd reporting every file "already exists".

### Phase D — "All in One Folder" (section 7)
| # | Owner | Files | Acceptance / tests |
| --- | --- | --- | --- |
| D1 | H | `FolderLayout.swift` | `case flat` (raw value `"flat"`), title "All in One Folder", example `IMG_0001.HEIC`, available for both sources, `folderStructureArgument` = `"none"`. Extend `FolderLayoutAndSelectionTests`. |
| D2 | H | `ExportEngine.swift` (PhotoKit) | `folderPath` returns `""` for flat; `relativePath` doesn't produce a leading `/`; `availableURL` collision naming unchanged. Unit test the path helper (extract a static func). |
| D3 | **O** (with C4) | `ICloudExportEngine.swift`, `fake_icloudpd.py` (`--folder-structure none` → files in DEST) | Process path passes `--folder-structure none`; bridge path passes `layout: "none"`; scanner in flat layout records **only reported paths** (7c). Tests: a user's `Resume.pdf` and `IMG_9999.HEIC` (not reported) in the folder are never recorded; two fake items with the same name, different size → `NAME.ext` and `NAME-<size>.ext`; a second run skips both. |
| D4 | H | `BackupPane.swift` | Picker entry + caption; non-empty folder warning; source-aware layout-switch warning (7e); FAT32 warning. |
| D5 | **O** | `ExportModel.swift` | Layout switch on an iCloud destination with exports asks first (7e); changing layout cancels a pending auto-resume with an Activity note. |

**QC checkpoint 4:** full suite, sandbox/sign checks from the QC checklist, manual flat export with the fake bridge
and with the real account on a test folder (the user runs it), and a later plain icloudpd `--folder-structure none`
run into that folder reports everything "already exists".

### Ordering
T0 → A1–A3 (parallel) → A4 → A5, A6 → QC1 → B1, B2 (parallel) → B3 → B4 → B5 → QC2 → C2, C3 (parallel) → C1 →
C4 + D3 → D1, D2, D4 (D1 can go any time after T0) → D5 → QC3 + QC4. Phases A and D1/D2 deliver value on their own
if C slips.

---

## 6. Risks

| Risk | Mitigation |
| --- | --- |
| Moving full exports to the bridge changes the most-used path. | Feature switch; QC3 real-account `diff -r`; the process path stays for album layout and as a fallback. |
| Bridge 503 handling differs from icloudpd's. | C1 turns throttles into a run-ending error; C4 test 7. |
| Order assumption (oldest-first). | T0 check; the anchor logic falls back to a full walk on any mismatch, so a wrong assumption costs speed, not data. |
| Insert+delete below R that cancel out. | Weekly full-walk sweep. |
| Set-aside fills the drive. | Shown in the Check Drive sheet with "Delete Set-Aside Files"; never automatic. |
| `exported.tsv` grows with `icloud-id:` lines next to legacy `icloud:` ones. | Readers dedupe by path; optional compaction later. |
| 90k-entry flat directory on FAT32 (65,534-entry limit) and slow Finder. | FAT32 check in D4; caption. |

---

## 7. "All in One Folder" layout

### (a) Engine arguments and paths
- `FolderLayout.flat`, raw value `"flat"`, stored in `.photo-export/layout`. Older app versions read an unknown
  layout as `nil` (`FolderLayout(rawValue:)`), so they show no layout warning instead of crashing.
- **icloudpd process:** `-d DEST --folder-structure none` (icloudpd sets `date_path = ""`, so files go to
  `DEST/NAME`). Same shared arguments as month.
- **Bridge:** request `layout: "none"`; `icloudpd_arguments` maps it to `--folder-structure none`; validation accepts
  `"none"`. Because both use `download_builder` with identical arguments, paths are identical by construction.
- **PhotoKit:** folder = destination root; `availableURL` handles collisions as it does today; the manifest records IDs,
  so collisions never cause a re-export.
- Album layout is unaffected; flat ignores albums (for iCloud: the whole "All Photos" library, like month).

### (b) Filename collisions
- Use icloudpd's default `name-size-dedup-with-suffix` (what both paths already use): if `IMG_0001.HEIC` exists with
  another size, the second item becomes `IMG_0001-<size>.HEIC`. The check is order-independent (A checks its plain
  name, B checks plain then `-<size>`), so the bridge, the process and a later full run agree.
- **The pre-flight never predicts names.** It works from recorded `icloud-id` → paths and from `stat`, so it can't
  disagree with icloudpd.
- Known limit: two **different** photos with the same name **and** the same byte size → the second is reported
  "already exists" and never downloaded. iPhone names wrap every 10,000 photos, so a 100k flat library has ~10 items
  per name; the expected number of such pairs is well below one, but not zero (it exists in month folders today at a
  lower rate). With ID records we can **detect** it: a `skipped` event for asset B whose path is already recorded for
  asset A is logged as a "name clash" in the session and listed in Check Drive. Fixing it would mean
  `--file-match-policy name-id7` (`IMG_0001_AbC1234.HEIC`): no clashes, but different names than plain icloudpd
  → open question 2.

### (c) Recording without misreading the user's own files
Options considered:
- *mtime ≥ run start*: **rejected**; icloudpd sets each file's mtime to the photo's creation date.
- *Per-folder marker*: says the folder is Uncloud's, not which files are.
- *Require an empty folder*: too strict for people continuing an existing icloudpd CLI folder.
- **Chosen: record only paths the engine reports**, plus a warning for non-empty folders.
  - Bridge: `downloaded`/`skipped` events carry full, untruncated paths (truncation patched) and the asset ID →
    `icloud-id:` records. Downloaded files are hashed once they've settled; skipped ones are hashed by the backfill.
  - icloudpd process (fallback): C3 patches `truncate_middle` in `run_icloudpd.py`, so `Downloaded`/`already exists`
    lines carry full paths; the scanner, in flat mode, hashes exactly those paths instead of walking the folder.
  - The pre-flight never registers untracked files in flat mode; it counts them as "other files in this folder".
- **Warning:** when flat is selected and the destination root holds non-hidden files that aren't recorded (from the
  inventory, capped count), BackupPane shows: "This folder already has 312 other files. Photos will be saved next to
  them. For a tidy backup, choose an empty folder." with a "Choose Folder…" button. No blocking.

### (d) Pre-flight and sessions
- Inventory of a flat folder is always full mode (one directory, its mtime always changes), still stat-only; 100k
  entries in one directory is within the budget on APFS/exFAT.
- Counts come from ID records; "other files" from untracked. Sessions record `layout: "flat"`; the resume point is
  keyed by layout, so switching layouts invalidates it.
- Resume-from-rank (section 3) works identically for flat: same library order, different directory.

### (e) Switching layouts on a folder that already has exports
- **PhotoKit:** current behaviour is right (IDs skip; new items use the new layout). Keep the message.
- **iCloud:** icloudpd only recognises files at the new layout's paths, so switching downloads the whole library
  again next to the existing copy (for 93k items, the full size again). Replace the warning with:
  "This folder already has 9,207 items saved by month. Switching to All in One Folder downloads your whole library
  again (about 412 GB) into this folder. To keep one copy, choose a new folder for the new layout." On starting the
  export, a confirmation alert with **Choose New Folder…** (default) / **Download Again Here** / Cancel.
- A layout change while an auto-resume is pending cancels the resume (Activity: "Automatic resume cancelled because
  the folder layout changed"), because the resume would otherwise continue in a different layout.
- Reorganising existing files into the new layout is out of scope (open question 3).

### (f) Wording and placement
In the "Folders and Files" picker, last entry, so the organised layouts come first:

> **All in One Folder**
> `IMG_0001.HEIC`

Caption when selected (same `Label(…, systemImage: "info.circle")` style as the album caption):

> "Every photo and video is saved directly in the folder you chose, with no subfolders. Files keep their iCloud
> names; when two have the same name, the second gets its size added, like IMG_0001-2483921.HEIC."

For the Photos library source, the last sentence becomes: "…the second gets a number, like IMG_0001 2.HEIC." On a
FAT32 drive: orange "This drive's format (MS-DOS FAT32) allows about 65,000 files in one folder. Choose a layout with
folders, or a drive formatted as APFS or exFAT."

---

## 8. Open questions for the user

1. **Damaged files:** when the drive check finds a truncated file, may Uncloud move it into a hidden "set aside"
   folder on the drive and download it again automatically, or should it ask each time? (Plan assumes automatic,
   never deleting.)
2. **Names in "All in One Folder":** keep iCloud's standard names (`IMG_0001.HEIC`, matches the icloudpd tool; a rare
   same-name-same-size clash is detected and listed but not downloaded), or add a short ID to every name
   (`IMG_0001_AbC1234.HEIC`, never clashes, but names differ from what icloudpd makes)? Plan assumes standard names.
3. **Switching layout on an existing iCloud backup:** OK that switching means downloading everything again (with the
   warning and "Choose New Folder…" offered first), or do you want a later tool that rearranges existing files?
4. **One real-account check:** before Phase C we need you to confirm, once, that the oldest photo in the Library view
   is at the end of iCloud's list (a 1-minute check we'll script), because the fast continue relies on it.

---

## User decisions and orchestrator corrections (2026-10-12): these override anything above

**User decisions**
1. **Partial or truncated files:** set them aside (never delete) and re-download them automatically.
2. **All in One Folder names:** keep the original names, using icloudpd's name-size-dedup policy. Don't use `name-id7`.
3. **Layout change on iCloud:** warn clearly that everything downloads again and offer "Choose New Folder…". No rearrange tool.
4. **Order check:** approved. Result below.

**Correction: icloudpd walks NEWEST FIRST.** This comes from the user's real export transcripts (2026-10-12): every session started at 2026/09 and moved down through 2026/05, 2026/03 and 2026/02 to 2025/10, and IMG numbers decrease within a month. So rank 0 is the newest item, and photos added between sessions are PREPENDED, which shifts every existing rank by the number of new items. Everything in part 3 must be re-derived on that basis:
- First download the new items at the top (ranks 0..k−1, until reaching the anchor).
- Then locate the stored anchor ID's new rank (search near the old R+k rather than expecting R−1) and continue from just past it, with the overlap check.
- Deletions shift ranks the other way; the anchor search covers both directions.
- If the anchor isn't found within a bounded window, fall back to a full walk.
- Make the fakes (C2) able to prepend items (`--insert-at 0`) as well as insert in the middle, and test the prepend case explicitly.
The live order check couldn't run because Apple reported PrimarySync indexing state RUNNING (verified for both icloudpd and the bridge). The transcripts settle the question anyway.

**Additional bug to fix: transcript redaction over-matches paths.** ICloudDiagnostics.redact's token regex (≥40 chars of [A-Za-z0-9+/=_-]) swallows file paths ("Photos Archive - <redacted>.JPG"), because "/" is in the character class. Redact tokens without "/" in them, keep paths readable, and still redact the Apple ID and email addresses. Add a test with a real-looking path.

**Bugs found by the planner, to fix in this round** (each gets a test):
- The layout-switch warning is wrong for iCloud: it says files "stay where they are", but a new layout means a full re-download. Covered by decision 3.
- A 503 during a bridge download becomes per-item failures instead of a run-ending throttle error, so auto-resume never triggers. It must end the run as serviceUnavailable.
- The idle iCloud "X of Y" counts files (Live Photo .MOV and .xmp sidecars), not items. Count items.
- PhotoKit relativePath would record a leading "/" in the flat layout.
