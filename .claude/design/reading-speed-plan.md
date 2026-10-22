# Reading Speed: Plan

Branch `feature/duplicates-and-icloud-cleanup` at bb732e8 (0.1.15). Owner: "how can we make reading of photos faster?"
This is a plan only. Nothing in the app was changed. Faster **downloads** (parallel downloads, hashing while
downloading, per-item file checks in the bridge) are covered in a separate plan, `.claude/design/export-throughput-plan.md`,
written by the export-speed agent. This plan covers them only where they share code with reading.

## 0. What was measured for this plan (2026-10-21, this Mac, Darwin 27)

Measurements were made with a scratch tool (`scratchpad/bench/listbench.swift`; chunk R0 turns it into a repo tool) on an
**exFAT disk image mounted through FSKit** (`com.apple.fskit.exfat`, the same driver the owner's USB drive uses). The
image is backed by an SSD, so seek time is not included. The folder had 61,531 entries: 30,767 photos plus their `._` files.
Building it was very slow and got slower with each file (about 54,000 entries in the first minutes, then about 100 a
second), so it was stopped at 61k.

| Operation on the exFAT folder (61.5k entries) | Time | What it means at the owner's 208k entries |
|---|---|---|
| `readdir` of names only | 0.34 s | linear: ~1.2 s (6.4 s measured on the real USB drive) |
| `getattrlistbulk`, cold: names, type, size and mtime of every entry | **0.33–0.36 s** | linear: **~1–7 s** |
| `FileManager.contentsOfDirectory(at:includingPropertiesForKeys:)` + `resourceValues` (exactly what `DriveInventory.full` does) | **41.5 s** | grows with the square: ~41.5 × (208/61.5)² ≈ **8 min**. The owner measured more than 12 min. |
| `lstat` of the **last** 1,000 names, cold | 6.0 s (**6 ms each**) | |
| `lstat` of the last 3,000 names, cold, then again warm | 17.9 s, then 0.005 s | lookups are cached once done |
| `lstat` of the last 1,000 names right after a `getattrlistbulk` pass | 6.0 s | **bulk listing does not warm lookups** |
| APFS reference: the same work on 208k entries | 1–3.7 s each | |

**Root cause.** On FSKit exFAT, looking up a name scans the directory in a straight line. Each lookup costs time in
proportion to the name's position in the folder: about 6 ms at position 60k, so roughly 10–20 ms on average at 208k, and
more on a spinning USB disk. Anything that touches files **one path at a time** in the flat folder pays this for every
file: `stat`, `resourceValues`, `fileExists`, `open` before a read, and Python's `os.path.isfile`. One
`getattrlistbulk` pass reads every name, size and date in about the time `ls -f` takes. Foundation's directory listing
with property keys does **not** get this benefit on exFAT, because it looks up each entry.

Other measurements:
- Manifest parsing with the current Swift code (`String(decoding:)`, `split("\n")`, `split("\t")`) on SSD: a 6.2 MB
  `exported.tsv` (104k records) takes **0.30 s**, an 11 MB `checksums.tsv` (140k lines) takes **0.28 s**. A byte-level
  scanner gives the same records in **0.034 s**, about 9× faster.
- The bridge's Python work per CloudKit page is small. On a synthetic 100-item page of 528 KB, `json.loads` takes
  1.8 ms, and pyicloud parses each page twice. `inspect.stack()` in `PyiCloudSession.request` takes 0.3 ms. Each
  request also rewrites the session and cookie files. In total that is under 10 ms per page, so **iCloud listing is
  limited by network latency**, at roughly 0.5–1.2 s per query (an estimate; R9 measures it).

## 1. Every read path

Numbers marked "est." are estimates for the owner's setup (93,200 items, 3.9 TB, 104k photos and 208k entries in one
exFAT folder). One "query" is one CloudKit `records/query` POST.

### A. Listing the iCloud library (bridge)

How pyicloud pages: `PhotoAlbum.photos` sends `records/query` with `startRank = offset`, `direction ASCENDING`,
`resultsLimit = page_size × 2` (an asset record plus a master record per item) and **~110 `desiredKeys`**. The bridge
sets `page_size = min(limit, PAGE_CHUNK = 100)`, so one query returns at most 100 items. A page is about 0.5 MB of JSON
uncompressed (synthetic estimate; signed download URLs make up most of it). `len(album)` is one more query (`HyperionIndexCountLookup`).
Because `startRank` is a filter, every page can be asked for **independently**, which means pages can be fetched in
parallel. pyicloud_ipd has **no changes/sync-token API**. Its params include `getCurrentSyncToken: True`, and
`photos.py:415` has a `TODO: Does syncToken ever change?`, but nothing reads or uses the token.

| # | Path | Code | When | Cost (owner) | Bottleneck |
|---|---|---|---|---|---|
| A1 | `page` request | `photo_bridge.py` `handle("page")` → `fetch_assets`; Swift `ICloudBridge.page` | every caller below | 1 query per 100 items. A Swift page of 200 = 2 queries ≈ 1–2 s (est.), ~1 MB JSON | serial queries; full `desiredKeys` for listings that only need ~15 keys |
| A2 | Library grid | `LibraryBrowser` (pageSize 200, maxPages 30) → `ICloudBrowserBackend` → `ICloudPageCache` | opening and scrolling the Library | 1 count + 2 queries per 200 tiles. Thumbnails: `URLSessionThumbnailFetcher`, 6 connections per host, one GET each (~10–30 KB), disk cache of 500 MB (~25k thumbs) | **during an export, page requests wait until the current file finishes**: `between_chunks` only answers pings, so a 4 GB video blocks the grid for minutes. Deep jumps cost 1–2 s per page. Also check: `ICloudPageCache` says "page 0 = newest" but builds it from `total − pageSize` while the bridge's rank 0 is the newest. The order may be reversed or a comment may be stale. |
| A3 | Full-check walk in downloads (`allExcept`) | `walk()` (100 per query, 5 overlap) inside `Bridge._download`; `ICloudExportEngine.runEverythingWithBridge` | monthly full check, first export, Check Whole Library | 93,200 / 95 ≈ **981 queries + counts**, ~490 MB JSON, **est. 10–20 min of listing alone** even with nothing to download. A `.fromRank` run adds the closing walk from rank 0 to the anchor. | serial, latency-bound |
| A4 | Quick update scan | `ICloudQuickUpdate.plan` (pageSize 100, stops after 200 known items in a row) | every routine Export New Photos | 3–4 queries (≤ 50 at the 5,000 limit), ~3 s | fine |
| A5 | Resume planner | `ICloudResumePlanner.plan` (window 200, top scan new + 2,000) | full-check runs with a resume point | ~5–25 queries | fine |
| A6 | New photos count | `NewPhotosCounter.countICloud` (200 per page), `NewPhotosTracker` | refreshProgress, reminder check | routine 2 queries; ≤ 50 at 5,000 | fine |
| A7 | Export range sheet | `ExportSince.iCloudSuggestedDate` (≤ 5,000 items = ≤ 50 queries), `iCloudItems` (from the top until `added < from`, ≤ 20,000 → **≤ 200 queries, est. 2–4 min**) | opening the sheet; each change of the From date | for an old From date, a walk of a large part of the library, **each time the date changes** | re-walks; no cache |
| A8 | Storage-estimate walk | `ICloudSizeScanner.scan` → bridge `stats` (plain pyicloud iteration, page 100) → `AssetSizeIndex` | in the background after launch, yields to exports | **932 queries, est. 10–20 min**. Starts again from 0 when the count changes during the walk or the library shrinks. | repeats work the download walk already does; restarts. **Possible bug:** when the library grows it resumes at `old count − 100` (the oldest end), but new items are at rank 0. |
| A9 | Watermark capture | `NewPhotosTracker.captureCandidate` → `page(0, 1)` | start of each run | 1 query | fine |
| A10 | Delete/restore targets | `Bridge._delete_targets` (walk for `allExcept`; hinted windows otherwise, a walk when hints > 30 %) | Free Up Space, Recently Deleted | up to 981 queries | same as A3 |

### B. Downloading originals (details in the export-throughput plan)

| # | Path | Code | Cost (owner) | Bottleneck |
|---|---|---|---|---|
| B1 | Download each item | `_DownloadRun.process` → icloudpd `download_builder` → `download_media` → `write_response` (32 KB chunks) → `move_into_place` (`renamex_np` EXCL) → `update_mtime` | one HTTPS stream at a time; est. 20–60 MB/s per stream → **3.9 TB ≈ 18–55 h** for a first export. Per item: `os.path.isfile` (an exFAT lookup, ~10–20 ms in the flat folder), `.part` create, rename and utime (more lookups). That is about 50 ms of lookups per new item, **est. ~1.3 h over 93k items**. | sequential; single stream; per-item lookups |
| B2 | Hash after download | `ICloudChecksumScanner.hash` → `FileHasher.sha256` (1 MB reads) every 200 items | **reads every downloaded byte back from USB**: +3.9 TB ≈ +7–9 h on a first export; one manifest append per file | a second disk pass; the hash could be computed while streaming in the bridge |
| B3 | Throttle | `throw_on_503` → `DownloadStopped` → serviceUnavailable → auto resume | — | parallel downloads raise the risk; see the export plan |

### C. Reading the backup drive

| # | Path | Code | When | Cost (owner) | Bottleneck |
|---|---|---|---|---|---|
| C1 | Drive check, full | `DriveInventory.scan` (`contentsOfDirectory(at:includingPropertiesForKeys:)` + `resourceValues` per child) → `DriveCheck.apply` (+ records, checksums, writes files.tsv) | Check Backup Folder, the monthly full check, runs that are not quick updates, Photos on This Mac runs. The flat layout is always `.full`. | **> 12 min (owner); measured 41.5 s at 61k entries** | Foundation looks up each entry on exFAT. `getattrlistbulk` does the same listing in **~1–7 s**. |
| C2 | Flat-folder "other files" check | `ExportModel.unrecordedEntryCount` (`contentsOfDirectory(atPath:)` + `ExportManifest.records`) from `refreshProgress` | launch, after each export, removal, layout change, destination change | readdir of 208k ≈ **6.4 s** + 0.3 s parse, each time; `refreshProgress` also parses `records` again | repeated full listing; no cache |
| C3 | Browse Backup index | `BrowseIndexer.update` → `fileStamp` (`resourceValues` per recorded path) → `BrowseMetadata.read` (ImageIO header; AVFoundation for movies; for files without GPS or date, 2× `fileExists` + read of the `.xmp`) | opening Browse Backup (pauses while exporting) | **every open:** 104k cold lookups ≈ **17–30 min (est.)** even when nothing changed. **First build:** plus a header read per file (lookup + seek + ~64–256 KB) ≈ **45–90 min (est.)**. `persist` JSON-encodes the whole index (≈ 20 MB) every 1,000 files, ~100 times. | per-file lookups; EXIF read for data iCloud already has |
| C4 | Browse thumbnails | `BrowseThumbnails` (`QLThumbnailGenerator`, 256 pt, LRU in memory) | scrolling Browse | per tile: lookup + read of the HEIC/JPEG; every revisit after a relaunch reads again | no disk cache |
| C5 | Find Duplicates scan | `DuplicateCleanup.scan` (records + checksums + firstRecordPositions, then `resourceValues(.fileSizeKey)` per recorded path, progress per file) | Find Duplicates | **104k–140k cold lookups ≈ 17–35 min (est.)** | sizes are read one path at a time; files.tsv or a bulk listing already has them |
| C6 | Verify Backup / Free Up Space check | `BackupVerifier.verifySynchronously` (`fileExists` + `FileHasher.sha256` per file, items in ID order) | Verify Backup; Free Up Space verifies the selected items first | **3.9 TB at ~120–160 MB/s ≈ 7–9 h**, plus ~17–30 min of lookups; no resume; read in ID order (random on disk) | disk throughput (unavoidable for a full check), seeks, no resume |
| C7 | Manifest parsing | `ExportManifest.records / checksums / iCloudItems / exportedIDs / firstRecordPositions / recentRecords`, `FilesSnapshot(tsv:)` | about 20 call sites; several per user action (refreshProgress 2×, Find Duplicates 3 files, every run's `knownItems` and `ICloudChecksumScanner.init`) | 0.3 s per parse on SSD (+0.1–0.3 s USB read); ~1–3 s per action in total | slow Swift string splitting; no memoization |
| C8 | Newest backed-up photo | `ExportSince.newestExportedPhoto` (parses the whole journal, then `resourceValues` for the last 500 records' files) | opening the range sheet | ~500–700 cold lookups ≈ **5–14 s (est.)** | per-file lookups |
| C9 | files.tsv snapshot | `ExportManifest.filesSnapshot` / `writeFilesSnapshot` (~8 MB, sorted lines) | each drive check | ~0.3 s parse, ~0.5 s sort + write | fine |

### D. Photos on This Mac (PhotoKit)

| # | Path | Code | Cost | Bottleneck |
|---|---|---|---|---|
| D1 | Export | `ExportEngine.run` → `ResourceWriter.write` (`PHAssetResourceManager.requestData`, network allowed; stream hash, then **reads the file back** to verify) | sequential; double disk pass | sequential requests (photolibraryd can serve 2–4 at once, which matters with Optimize Mac Storage); re-read (export plan) |
| D2 | Progress / new photos | `PhotoLibrary.progress`, `BackupFiles.allLibraryIDs` (enumerate every `PHAsset`) | ~0.3–1 s per call for 93k items | fine; avoid calling it repeatedly |
| D3 | Grid | `PhotoKitBrowserBackend` (`PHCachingImageManager`) | fast | fine |
| D4 | Places | `PlaceResolver` (one geocode per 10 km cell, JSON cache rewritten on each new place) | geocoder rate limit | fine |

## 2. Ranked improvements

Impact is measured on the owner's setup. Effort: S = one Haiku chunk, M = 2–3 chunks, L = a project.

### Quick wins

| Rank | Improvement | Impact | Effort | Risk |
|---|---|---|---|---|
| Q1 | **`getattrlistbulk` lister** (`BulkDirectoryLister`) used by `DriveInventory` | drive check **12+ min → ~10 s**; the monthly full check and Check Backup Folder become routine | S | low: falls back to today's code when the call fails (ENOTSUP), and tests compare its output with FileManager |
| Q2 | **One bulk listing reused by every per-file reader**: Browse stamps (C3), Duplicate sizes (C5), newest photo (C8), other-files check (C2) | Browse reopen **17–30 min → seconds**; Find Duplicates **17–35 min → seconds**; range sheet −5–14 s; refreshProgress −6 s | S–M | low |
| Q3 | **Manifest cache + byte parser** (memoized by file size + mtime) | 0.3 s → 0.03 s per parse, and repeated parses cost nothing; −1–3 s per action | S | low: tests check the output is identical |
| Q4 | **Bridge timing log** (queries, items, bytes, seconds per request) | turns every estimate above into a measurement; needed before P1/P2 | S | none |
| Q5 | **Answer browsing between chunks** of a download (at most every 0.25 s) | the Library grid no longer freezes during large downloads | S | low: download/stats/delete requests are still deferred |
| Q6 | **Lean `desiredKeys`** for listing-only requests (`page`, `stats`) | est. 50–70 % fewer bytes per page; 10–30 % faster pages | S | medium-low: `describe()` must give identical output (fixture test). Download walks keep the full list. |
| Q7 | Browse: save the index every 1,000 files **and** at least 30 s apart; sidecar existence from the listing | −1–3 min of JSON encoding; −2 lookups per photo without GPS | S | low |
| Q8 | Thumbnails: 12 connections per host; prefetch thumbnails for the next page at low priority | smoother grid scrolling | S | low (the CDN is not the CloudKit API) |

### Bigger projects

| Rank | Improvement | Impact | Effort | Risk |
|---|---|---|---|---|
| P1 | **Parallel or pipelined page fetches** in the bridge. Each walk keeps 1–3 queries ahead on worker threads. Pages are independent (`startRank` filter). The overlap check stays on the main thread. | listing walks (A3, A8, A10) **10–20 min → 4–7 min**. Setting `iCloudParallelListing` (default 2; 1 = off). | M | medium: Apple's 503/ACCESS_DENIED throttle; `PyiCloudSession.request` rewrites the cookie and session files on every request, so those writes need a lock; drop to 1 on the first throttle |
| P2 | **Local iCloud catalog** (SQLite, per account, in Application Support): id, master record name, added, created, filename, type, bytes, latitude and longitude (from `locationEnc`, which icloudpd already decodes with plistlib), last-seen walk. Filled by every `page` and by a compact `listed` event per page during download walks. | Storage estimate needs **no separate 932-query walk** after the first full check. The range sheet queries locally after a top-up of 2–4 queries (was ≤ 200). The Library grid opens instantly from the catalog, then updates. Rank hints for every item. Browse can be seeded without reading files (P4). | L | medium: staleness. Always top up from rank 0 until a run of known items, as the quick update does; the monthly full walk rewrites the catalog. |
| P3 | **CloudKit `changes/zone` spike** (sync token), a Python-only debug command | if Apple accepts it from the web session: **exact deltas** in 1 request (new, changed and deleted records). New-photo counts are exact, quick updates need no scan, and full checks become a rare safety net. | spike S, then L | high and unknown: undocumented for this client, and the first sync without a token pages through every record type in the zone (≥ one full walk) |
| P4 | **Seed the Browse index from the catalog** (date and GPS per iCloud-ID record; read EXIF only for files without a catalog entry; camera name optional and lazy) | first Browse build **45–90 min → ~1 min** for an iCloud backup | M (after P2) | low-medium: the dates and places shown follow iCloud's metadata, not the file's EXIF (usually the same) |
| P5 | **Verify Backup v2**: resumable (checkpoint every 1,000 files), files read in path order (≈ disk order for files written one after another), 4 MB reads with `F_NOCACHE`, a "Quick check" mode (size and mtime from the bulk listing compared with `files.tsv`, seconds) next to the full checksum pass | a full check stays ~7–9 h (disk-bound) but resumes; quick mode takes seconds. **No parallel hashing on a spinning disk** (two readers on one HDD are slower than one). | M | low |
| P6 | Browse thumbnails on disk (Application Support, keyed by path + size + mtime, 256 px JPEG, 1 GB cap) | revisits are instant and don't spin up the drive | S–M | low |
| P7 | Structural fix for the flat layout: the `._` cleanup and "Reorganize into month folders" from export-speed-plan Part 3 | every lookup becomes ~100× cheaper (folders of ~100–1,500 entries), for every remaining per-file path including downloads | M | needs the owner's OK (moves files on the drive) |

Not worth doing now: parallel reads on the HDD (seeks get worse); bigger CloudKit pages. `resultsLimit` is believed to be
capped at 200 records, which is what icloudpd sends now; a single `curl`-free check is part of R9 (log
`len(records)` when asking for 400).

## 3. Build chunks

Rules for every chunk: Swift 6, sandbox-safe, no new dependencies (`SQLite3` and `Darwin` are system libraries).
Swift tests use Swift Testing in `UncloudTests/`. Python tests go in `UncloudTests/Bridge/test_bridge.py`, run with
`Vendor/icloudpd-runtime/python/bin/python3.13 -I -B UncloudTests/Bridge/test_bridge.py Uncloud/Helper/photo_bridge.py`.
Don't edit `ExportModel.swift`, `BackupPane.swift` or `BackupHero.swift` while the other builder has them; the chunks
below that need them say so.

### Order and parallel lanes

- **Lane S (Swift, drive):** R1 → then R2, R4, R5 and R6 **in parallel** (each edits a different file). R3 is part of R1.
- **Lane M (Swift, manifest):** R7. It can run in parallel with lane S because it only edits `ExportManifest.swift` and adds a test file.
- **Lane P (Python, bridge):** R9 → R10 → R8 → R11, **one after another** (all edit `photo_bridge.py` and `test_bridge.py`).
  **Sequence them with the export-throughput plan's bridge chunks**, which edit the same two files.
- **R0** (bench tool) can run at any time. **R12–R15** come later.

### R0: Read benchmark tool (Haiku)
- Files: new `Tools/ReadBench/readbench.swift` (copy and tidy `scratchpad/bench/listbench.swift`) and `Tools/ReadBench/README` (3 lines, how to run it).
- Behaviour: `swiftc -O Tools/ReadBench/readbench.swift -o /tmp/readbench && /tmp/readbench <folder> [readdir|bulk|fm|lstat N|lstatlast N]`.
  Read-only. Prints entries and seconds for each method. It isn't part of the app target.
- Acceptance: on a local temp folder, all methods report the same visible-file count; `bulk` total bytes = the sum of `stat` sizes.
- The owner runs it once on the drive (before and after). It touches nothing on the drive.

### R1: `BulkDirectoryLister` (Haiku, reviewed by Opus)
- Files: new `Uncloud/Export/BulkDirectoryLister.swift`; new `UncloudTests/BulkDirectoryListerTests.swift`.
- API:
  ```swift
  enum BulkDirectoryLister {
      struct Entry: Equatable, Sendable { let name: String; let kind: Kind; let size: Int64; let modified: Double } // modified: seconds since 1970, with nanoseconds
      enum Kind: Sendable { case file, directory, symlink, other }
      /// Every entry of `folder` (hidden ones included; callers filter), from getattrlistbulk with a 256 KB buffer.
      /// Falls back to FileManager when the call isn't supported (ENOTSUP/EINVAL) for that volume.
      static func list(_ folder: URL) throws -> [Entry]
  }
  ```
  Ask for `ATTR_CMN_RETURNED_ATTRS | NAME | OBJTYPE | MODTIME` and `ATTR_FILE_DATALENGTH` (the data fork's logical size,
  the value `.fileSizeKey` gives). Read `attribute_set_t` to see whether the size was returned (directories have none).
  Use `loadUnaligned`. Check `Task.checkCancellation()` between buffers. Names come back as the file system stores them
  (no Unicode normalization), the same as FileManager.
- Tests: a temp folder with 5,000 files (several buffers), a subfolder, a symlink, a dotfile, `x.part`, names in NFC and
  NFD, a 0-byte file, and a 3 MB file. The result must equal a FileManager listing built in the test (same names, kinds,
  sizes, and mtimes within 1 µs). Also: a missing folder throws; cancellation stops it.

### R2: `DriveInventory` uses the lister (Haiku)
- Files: `Uncloud/Export/DriveInventory.swift`; extend `UncloudTests/DriveInventoryTests.swift` (or the existing inventory tests).
- Behaviour: in `scan`, replace `contentsOfDirectory(at:includingPropertiesForKeys:)` and the `resourceValues` per child
  with `BulkDirectoryLister.list(folderURL)`. Keep every rule the same: skip names starting with `.`, names with control
  characters and symlinks; count `.part`/`.partial`; recurse into folders. Take a subfolder's mtime from its parent's
  entry and pass it down, so `modificationTime(of:)` runs only for the root. Report progress every 1,000 files as now.
- Acceptance: all existing DriveInventory and DriveCheck tests pass unchanged. New test: on a fixture tree (root,
  `2024/07`, hidden files, `.part`, symlink) the `.full` and `.quick` results equal the expected snapshot.
- Measure: `DriveCheckReport.seconds` is already recorded. The owner's Check Backup Folder time before and after.

### R4: Browse index stamps from one listing (Haiku)
- Files: `Uncloud/Export/BrowseIndex.swift`; extend its tests.
- Behaviour: at the start of `update`, group `paths` by parent folder and list each folder once with
  `BulkDirectoryLister`, giving a `[relativePath: (size, modified)]` map. Use the map in place of `fileStamp(of:)`. A
  path missing from the map is gone, with the same driveUnavailable check as now. Pass a `sidecarExists: (URL) -> Bool`
  backed by the same listing into `BrowseMetadata.read`; add a parameter with today's `fileExists` as the default.
  Persist every 1,000 files **and** only if 30 s have passed since the last save; always save at the end and on throw.
- Acceptance: the existing BrowseIndex tests pass. New tests: an unchanged file isn't read again (counting `read`
  closure); a changed size is read again; a removed file is dropped; the `.xmp` fallback still works; persist runs at most once per 30 s with a fake clock.

### R5: Find Duplicates sizes from one listing (Haiku)
- Files: `Uncloud/Model/DuplicateCleanup.swift` (only `scan`); extend the DuplicateCleanup tests.
- Behaviour: list each recorded folder once (`BulkDirectoryLister`) and fill `sizes` from it. A path not listed has no
  size, as today. Report progress per folder or every 1,000 paths, not for every path.
- Acceptance: `findGroups` input is identical to today's on a fixture (a test compares both size maps).

### R6: Newest backed-up photo and the flat "other files" count from one listing (Haiku)
- Files: `Uncloud/Model/ExportSince.swift` (`newestExportedPhoto`); new `Uncloud/Export/FlatFolderCheck.swift` with
  `static func unrecordedEntryCount(in url: URL, records: [String: [String]]) -> Int?` (a copy of
  `ExportModel.unrecordedEntryCount` that takes records and uses `BulkDirectoryLister` names); tests in
  `UncloudTests/ExportSinceTests.swift` and a new `UncloudTests/FlatFolderCheckTests.swift`.
- Behaviour: `newestExportedPhoto` lists the folders of the last `limit` records once and takes mtimes from the listing.
  **ExportModel switch-over (for the other builder, later):** `refreshFlatFolderCheck` calls
  `FlatFolderCheck.unrecordedEntryCount(in:records:)` with the records `refreshProgress` already parsed, and skips the
  listing when the folder's mtime equals the last one it counted (cache `(url, mtime, count)`).
- Acceptance: the same results as the old functions on fixtures (old and new run side by side in the test).

### R7: Manifest cache and fast parser (Haiku, reviewed by Opus)
- Files: `Uncloud/Export/ExportManifest.swift`; new `UncloudTests/ExportManifestParsingTests.swift`.
- Behaviour: add a private `ManifestTextCache` (an `OSAllocatedUnfairLock` dictionary keyed by file path → (size,
  mtime ns, parsed value)) for `records`, `checksums` and `exportedIDs`. Reuse the value when size and mtime didn't
  change. Writes through `ExportManifest` (append, forget, replace) drop the entry for that file. Replace the
  `String.split` parsing with a byte scanner over `Data` that keeps **exactly** today's semantics:
  - the last line is skipped when it has no `\n`;
  - empty fields are dropped in `records` (as `split` drops them);
  - `checksums` splits at the first tab only;
  - a later line wins.
- Tests: a random fixture (10k lines, NFD names, empty fields, a partial last line, duplicate keys) gives an output
  identical to a copy of the old parser kept in the test. The cache is used again after an unchanged stat and dropped
  after an append.
- Measure: a test (behind the `UNCLOUD_BENCH=1` env var) prints the parse time of a 100k-line fixture.

### R9: Bridge timing log (Haiku)
- Files: `Uncloud/Helper/photo_bridge.py`, `UncloudTests/Bridge/test_bridge.py`.
- Behaviour: wrap `PhotoAlbum.photos_request` in a patch, the same way `patch_downloads_for_bridge` does, and count
  queries, records, response bytes (`len(response.content)`) and seconds per bridge request. When each `page`, `stats`,
  `download` walk and `delete` ends, write one stderr line:
  `timing cmd=page queries=2 items=200 bytes=1043112 seconds=1.31`. It ends up in the diagnostics transcript
  (`ICloudBridge.receivedLog`). Add the same fields to the final event as `"timing": {...}`. This is backwards-compatible
  because Swift ignores keys it doesn't know.
  Also log `records_returned` vs `resultsLimit` once per session, to see whether Apple returns fewer than asked.
- Tests: with a fake album whose `photos_request` returns canned records, a `page` request gives the timing line with the right counts.

### R10: Answer browsing between download chunks (Haiku, reviewed by Opus)
- Files: `photo_bridge.py` (`_DownloadRun.between_chunks`), `test_bridge.py`.
- Behaviour: in `between_chunks`, after `answer_pings`, call `self.bridge.serve_waiting()` at most every 0.25 s
  (`time.monotonic`). `handle(..., downloading=True)` already defers `download`/`stats`/`delete`/`restore`, so only
  `page`, `count`, `albums` and `ping` run. The streaming response uses its own pooled connection, so a page query
  opens another.
- Tests: a fake download that yields 50 chunks with a `page` request queued after chunk 5: the page reply comes before
  `done`; a queued `stats` request still runs only after `done`.

### R8: Lean keys for listing requests (Haiku, reviewed by Opus)
- Files: `photo_bridge.py`, `test_bridge.py`.
- Behaviour: `LISTING_KEYS` = the keys `describe()` and `download_bytes()` read through `PhotoAsset`. Derive them from
  `PhotoAsset.filename / asset_date / added_date / size / item_type / versions` (at least `recordName`, `recordType`,
  `masterRef`, `filenameEnc`, `itemType`, `assetDate`, `addedDate`, `resOriginalRes`, `resOriginalFileType`,
  `resOriginalFingerprint`, `resOriginalWidth`, `resOriginalHeight`, `resOriginalAlt*`, `resOriginalVidCompl*`,
  `resJPEGThumbRes`, `adjustmentRenderType`, `isDeleted`, `isHidden`). Before relying on the list, the builder confirms
  it by reading `pyicloud_ipd/services/photos.py` `PhotoAsset` and `version_size.py`.
  `fetch_assets(album, offset, limit, lean=True)` sets `view._uncloud_keys = LISTING_KEYS`. A patched `_list_query_gen`
  uses that list when the attribute is set. `page` and `stats` use `lean=True`; download walks and deletes don't.
- Tests: for a fixture record pair, `describe()` of the full record equals `describe()` of the record filtered to
  `LISTING_KEYS`. The query body of a `page` request contains only `LISTING_KEYS`; a download walk's contains the full list.
- Measure: R9's `bytes=` before and after on the owner's account.

### R11: Pipelined walk pages (Opus designs, Haiku builds; off by default until measured)
- Files: `photo_bridge.py` (`walk`, `fetch_assets`, `stats`), `test_bridge.py`; Swift passes `"prefetch": N` from a
  setting (`ICloudBridgeDownloadOptions`, `ICloudBridge.stats`). The Swift part is a separate small chunk.
- Behaviour: a `PagePrefetcher(album, depth)` uses a `ThreadPoolExecutor(max_workers=depth)` to fetch
  `fetch_assets(copy, offset, 100)` for the next `depth` offsets while the current page is processed. `walk()` keeps its
  overlap/line-up logic on the main thread. When the line-up needs to look back (`back *= 4`), pending prefetches are
  dropped and fetched again from the new offset. Patch `PyiCloudSession.request`'s file saves with a lock (they rewrite
  the same two files). Any `is_run_ending` error in a worker stops the walk as today. A throttle sets depth to 1 for the
  rest of the session.
- Tests: a fake album with 2,050 items and a 20 ms delay per query gives the same (rank, id) sequence with depth 1 and
  depth 3, and depth 3 is at least 2× faster. A removal in the middle of the walk (a fake that shifts after page 4) still
  visits every item once. A 503 raised in a worker ends the download with the throttle error.

### Later chunks (outline; plan them in detail after R9's numbers)
- **R12 Catalog (P2):** R12a `Uncloud/Model/ICloudCatalog.swift` (SQLite3: table `assets(id PRIMARY KEY, master, added,
  created, filename, type, bytes, lat, lon, seenAt)`, upsert in batches of 1,000 in one transaction, queries by added
  and created range); R12b bridge `listed` event per walk page (`photo_bridge.py`, lane P); R12c `NewPhotosCounter` /
  `ExportSince` use the catalog after a top-up; R12d the storage estimate reads bytes from the catalog and runs `stats`
  only for unsized IDs.
- **R13 changes/zone spike (P3):** a Python-only `{"cmd":"changes","syncToken":T?}` request (not called by the app)
  that POSTs `{service_endpoint}/changes/zone` with `zones:[{zoneID, desiredRecordTypes:["CPLAsset","CPLMaster"],
  desiredKeys: LISTING_KEYS, syncToken}]`, follows `moreComing`, and reports record counts, the new token and time.
  Opus runs it once with the owner and writes down whether Apple answers.
- **R14 Verify v2 (P5):** `BackupVerifier.swift`, `FileHasher.swift` (coordinate with the export plan, which may change
  `FileHasher`). Add a checkpoint file under `.photo-export/verify-progress.json`, path order, 4 MB reads with
  `fcntl(F_NOCACHE)`, and `quickVerify` from the lister and `files.tsv`.
- **R15 Browse disk thumbnails (P6):** `BrowsePhotoViews.swift` plus a small `BrowseThumbnailStore`.

### How to measure before and after
1. **Drive:** `readbench` (R0) on the backup folder, plus Check Backup Folder's `seconds` (already in the report), before R1/R2 and after.
2. **Bridge:** R9's `timing` lines in the diagnostics transcript: queries, bytes and seconds per page, walk and stats.
   Record one routine Export New Photos, one Library open, and one storage-estimate walk before R8/R11 and after.
3. **Browse and Duplicates:** time from opening to "done" as shown in their progress. Add an `os.Logger` line at the end
   of `BrowseIndexer.update` and `DuplicateCleanup.scan` (category `reading`):
   `browse index: 104,188 paths, 0 read, 4.1 s`.
4. **Activity list (for the other builder):** after a drive check, add the note "Checked 104,188 files in 7 s." from
   `DriveCheckReport.seconds` (ExportModel).

## 4. Decisions for the owner

1. **Do Q1–Q3 (bulk listing, reuse it, manifest cache) now?** *Recommendation: yes.* It is the biggest win for the least
   risk: the drive check, Browse and Find Duplicates drop from tens of minutes to seconds, with no change to what the app shows.
2. **Parallel iCloud listing (P1): default depth?** *Recommendation: build it off by default, measure with R9, then ship
   depth 2.* That is roughly 2× faster walks with a small throttle risk. Drop to 1 automatically on a 503.
3. **Local iCloud catalog (P2)?** *Recommendation: yes, after R9 and R11.* It removes the separate storage walk and the
   range-sheet walks, opens the Library instantly, and makes Browse almost free (P4). It needs a monthly full walk to stay
   honest, which the app already does.
4. **CloudKit change-token spike (P3)?** *Recommendation: yes, one spike with you present (a sign-in is needed).* If Apple
   answers, "new photos" becomes exact and instant. If not, the catalog plus quick update is already close.
5. **Browse dates and places from iCloud metadata instead of each file's EXIF (P4)?** *Recommendation: yes for
   iCloud-ID records.* They are the same data, and the first Browse build skips reading 93k files. Keep the EXIF read
   for files the catalog doesn't know.
6. **Verify Backup: add a seconds-long "quick check" (sizes and dates) next to the 7–9 h checksum pass, and make the full pass resumable?** *Recommendation: yes.*
7. **Flat folder on exFAT:** *Recommendation: offer "Reorganize into month folders" and the `._` cleanup (export-speed-plan Part 3).*
   Every remaining per-file operation, including downloads, gets ~100× cheaper. Bulk listing fixes listing but not per-file opens.
8. **Possible bugs to confirm first (cheap):** (a) the storage walk resumes at the oldest end when the library grows
   (A8); (b) `ICloudPageCache` page order and comment vs the bridge's rank 0 = newest (A2). *Recommendation: one Opus
   check of each before any catalog work.*

## Owner decisions (2026-10-21): "all"
Q1–Q3 yes (building: lane S R0–R6, lane M R7). P1 parallel listing: build off, measure (R9), ship depth 2 with 503
fallback. P2 local catalog: yes, after R9/R11. P3 change-token spike: yes, owner present for sign-in. P4 Browse from
iCloud metadata: yes. Verify quick check + resumable full pass: yes. Month-folder reorganize + `._` cleanup: yes.
Bugs A2/A8: one Opus check first.
