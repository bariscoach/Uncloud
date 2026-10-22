# Reading Speed, Wave 2: Plan

Written against `feature/duplicates-and-icloud-cleanup` at 2bcec83 (main has since moved to 9b953fc, the wordmark
commit, which touches none of the files below). This is a plan only. No app code was changed.
Follows `.claude/design/reading-speed-plan.md` ("Later chunks", §2 P2–P7, and the owner's decisions to do all of it)
and `.claude/design/export-speed-plan.md` Part 3.

**Already in progress elsewhere. These chunks don't edit their files until they land:**
- Lane S: R0–R6 (`BulkDirectoryLister`, `DriveInventory`, `BrowseIndex.swift`, `DuplicateCleanup.swift`,
  `ExportSince.swift`, new `FlatFolderCheck.swift`).
- Lane M: R7 (`ExportManifest.swift`).
- Lane P: R9 → R10 → R8 → R11 (`photo_bridge.py`, `test_bridge.py`, and R11's Swift part in `ICloudBridge.swift`).
- Wordmark: `WelcomeView`, `LandingView`, `AppLogo`, `site/`.
- `ExportModel.swift`, `BackupPane.swift` and `BackupHero.swift` belong to the other builder. Chunks that need a
  change there say so and keep the change to one small, separate step.

Rules for every chunk are the same as in wave 1: Swift 6, sandbox-safe, no new dependencies (`SQLite3`, `Darwin` and
`CryptoKit` are system modules; `import SQLite3` links on its own). Use Swift Testing in `UncloudTests/`. The project is
XcodeGen with `sources: Uncloud`, so new files are picked up after `xcodegen generate`. Python tests use
`Vendor/icloudpd-runtime/python/bin/python3.13 -I -B UncloudTests/Bridge/test_bridge.py Uncloud/Helper/photo_bridge.py`.

---

## 1. Bug checks

### A8: the storage-estimate walk tops up at the wrong end. **Confirmed.**

Evidence:
- The bridge's own protocol says new items are at the top. `Uncloud/Helper/photo_bridge.py:16-17` says: "rank 0 is
  the NEWEST item, and an item added to iCloud is inserted at rank 0, shifting every other rank by one."
  `ResumePoint.swift:3-9` says the same, and the quick update, the new-photo counter and the range sheet all depend
  on it (`ICloudQuickUpdate.swift:60-100`, `NewPhotos.swift:120-150`, `ExportSince.swift:17-48` all walk from rank 0
  to find new items).
- The size index assumes the opposite. `Uncloud/Model/AssetSizeIndex.swift:100-101` says: "A library that grew since
  a complete walk is walked from just before its old end (new items come last in icloudpd's order)".
  `AssetSizeIndex.swift:116-117` does this: `if libraryCount > table.libraryCount { return max(0, table.libraryCount - 100) }`.
- So `ICloudSizeScanner.scan` (`AssetSizeIndex.swift:224-228`) sends `stats` from offset `oldCount − 100`. That
  re-reads the **oldest** 100 + N items, which already have sizes but have moved down by N.
- `endScan(complete: true)` (`AssetSizeIndex.swift:163-172`) then accepts it, because `walk.start > 0`. It marks the
  table `isComplete = true` with `libraryCount = newCount`, but the N new items at ranks 0..<N were never sized.
- Effects:
  - (1) The estimate fills the new items with the average (`StorageEstimate.swift:151-157`) but labels the basis
    `.scanned`.
  - (2) `addSamples` returns early for a complete table (`AssetSizeIndex.swift:86`). Sizes the Library browser sees
    for the new items are thrown away.
  - (3) The gap stays until the library shrinks, which forces a full rewalk.
  - (4) The test encodes the bug: `UncloudTests/StorageEstimateTests.swift:266` expects
    `scanStart(libraryCount: 1050) == 900`.
- A related gap: a library that gained one item and lost one between launches has the same count. `scanStart` then
  returns nil (`AssetSizeIndex.swift:115`), so the new item is never sized.

### A2: the Library grid's page order. **Confirmed. The grid shows the iCloud library oldest first.**

Evidence:
- `ICloudPageFetching.assets` is documented as "in icloudpd's order, **oldest first**" (`ICloudPageCache.swift:21`).
  The real fetcher, `ICloudBridgeFetcher.assets` (`ICloudBridge.swift:1145-1147`), passes offsets straight to the
  bridge `page` command, where offset 0 is the **newest** item (`photo_bridge.py:16-19, 852-860`).
- `ICloudPageCache.page(n)` (`ICloudPageCache.swift:154-160`) computes `upper = total − n·pageSize` and
  `lower = upper − pageSize`, fetches `lower..<upper`, then reverses it. With the bridge's order, page 0 is ranks
  `total−200..<total`, the **oldest** 200 items, and after the reversal they come oldest first. Each page after that
  is the next-older block, so the whole grid runs from the oldest photo to the newest.
- The browser intends newest first: `LibraryBrowser.swift:6, 15, 131` ("0 is the newest"), and the Photos-library
  backend fetches `newestFirst: true` (`LibraryBrowser.swift:278`). So the two sources show opposite orders.
- The test fake has the same wrong model: `UncloudTests/ICloudPageCacheTests.swift:5` ("item-0 (oldest)" at offset
  0), `:72` (`pagesAreNewestFirst`), and `:128` ("Ranks count from the oldest item").
- The rank arithmetic is still right in bridge terms. `rankByID = upper − 1 − position`
  (`ICloudPageCache.swift:170`) equals the bridge offset of that item, and `pageIndex(forID:)`
  (`ICloudPageCache.swift:233-236`) inverts it. So rank hints for downloads and deletes (`rankHints`) and the 403
  thumbnail refresh are **correct**. Only the display order and the comments are wrong.

### FIX-A2: the page cache follows the bridge's order (Haiku, ~1 h)
- Files: `Uncloud/Export/ICloud/ICloudPageCache.swift`, `UncloudTests/ICloudPageCacheTests.swift`.
- Behaviour:
  - Protocol comment (line 21): "Items `offset..<offset + limit` in the bridge's order: rank 0 is the newest item."
  - `page(index)`: `let lower = index * pageSize`, then `guard index >= 0, lower < total else { return [] }` and
    `let limit = min(pageSize, total - lower)`. Fetch `assets(offset: lower, limit: limit)` and **don't reverse** it.
    Set `rankByID[asset.id] = lower + position`.
  - `pageIndex(forID:)`: `guard let rank = rankByID[id], let count, rank < count`, then return `rank / pageSize`.
  - Update the class comment (lines 52-56): "Page `n` holds ranks `n·pageSize ..< (n+1)·pageSize`; rank 0 is the
    newest."
- Note: under the old scheme, adding items didn't move the pages. Now every page moves down by N. That is fine,
  because `LibraryBrowser.reload()` already resets the backend when the count changes (`ExportModel.swift:345, 400`,
  `MainWindow.swift:120`). Recently Deleted (`album: .recentlyDeleted`) goes through the same code and gets the
  bridge's order for that album too. Check it once by eye.
- Tests:
  - Make `FakeLibrary` newest first: `item-0` is the **newest**, at offset 0, and the comment says so.
  - Update the expectations: page 0 = `item-0, item-1, item-2`; page 2 of 7 = `item-6`; the concurrent-fetch test
    expects `item-3, item-4, item-5` for page 1.
  - `rankHintsFindItemsAfterTheirPageLoads`: page 1 gives `["item-3": 3, "item-4": 4]`.
  - The thumbnail tests use `.../0?v=1`, the URL of the item at page(0)[0].
  - New test: `fetchedRanges` for pages 0, 1 and 2 of a 7-item library are `0..<3, 3..<6, 6..<7`.
  - New test: an expired thumbnail on page 1 refreshes page 1 (the `pageIndex` round trip).
- Acceptance: all ICloudPageCache tests pass. In the app, the Library grid's first tile is the newest photo, as in
  Photos on This Mac.

### FIX-A8: the storage-estimate top-up starts at rank 0 (Haiku, reviewed by Opus, ~2 h)
- Files: `Uncloud/Model/AssetSizeIndex.swift`, `UncloudTests/StorageEstimateTests.swift`. Nothing else, so it
  collides with no lane.
- Behaviour:
  - Replace `scanStart(libraryCount:) -> Int?` with
    `scanPlan(libraryCount:) -> ScanPlan`, where
    `enum ScanPlan: Equatable, Sendable { case upToDate, walk(from: Int), topUp }`. Keep `scanStart` as a thin
    wrapper only if other code calls it (grep first).
    - A walk in progress resumes exactly as today (lines 104-113).
    - An incomplete table with no walk gives `.walk(from: 0)`.
    - A complete table whose count **grew** gives `.topUp`, not `oldCount − 100`.
    - A complete table whose count **didn't change** also gives `.topUp`. It costs 1–2 queries and catches the
      "one added, one removed" case.
    - A complete table whose count **shrank** gives `.walk(from: 0)`, as today.
    - `.upToDate` is returned only when `libraryCount` is nil (unknown).
  - New `AssetSizeIndex.topUp(fetcher: any ICloudPageFetching, libraryCount: Int, overlap: Int = 200,
    cap: Int = 5_000) async throws -> Bool`:
    - Page from offset 0 in pages of 200. For each item, `table.set(bytes, for: id)` when `bytes` is non-nil.
    - Count a run of items already in the table.
    - Stop when the run reaches `overlap`, or when the library ends. In that case set `table.libraryCount =
      libraryCount`, keep `isComplete = true`, save, and return true.
    - If `cap` items are scanned without such a run, set `isComplete = false` and
      `walk = Walk(start: 0, libraryCount: libraryCount)`, and return false. The next scan then walks everything,
      which is safe.
  - In `ICloudSizeScanner.scan`, `.topUp` calls
    `index.topUp(fetcher: ICloudBridgeFetcher(bridge: bridge), libraryCount:)`. It returns `.complete` when that
    gives true. When it gives false, it falls through to `.walk(from: 0)` in the same call.
  - Fix the comment at lines 96-102 to say new items are inserted at rank 0.
- Tests (with a fake `ICloudPageFetching`, newest first):
  - A complete table of 1,000 items; the library grows to 1,050 with 50 new IDs at ranks 0..<50. The top-up sizes
    exactly those 50, fetches ≤ 2 pages, and leaves the table complete at 1,050.
  - The count is unchanged but rank 0 is a new ID (one added, one deleted lower down). The top-up sizes the new
    item.
  - 6,000 new items with a cap of 5,000: it returns false, the table is incomplete, and the next plan is
    `.walk(from: 0)`.
  - The library shrank: `.walk(from: 0)`.
  - Replace the expectation at line 266 with `scanPlan(libraryCount: 1050) == .topUp`.
- Acceptance: the existing StorageEstimate tests pass apart from the line-266 change. After a library grows, the
  estimate's `known` count includes the new items without a 932-query walk.

---

## 2. P2: local iCloud catalog (R12a–R12g)

**What it is.** One SQLite file per Apple ID and library zone. It holds every item the app has seen in any `page`
answer, walk page or `stats` page, with the fields the readers need. Each consumer first tops it up from rank 0
until it meets a run of known items (as the quick update already does), then queries it locally. The monthly full
walk is the only thing that proves deletions (with the Recently Deleted prune between walks). Every consumer keeps
its current network path as the fallback, so a missing or untrusted catalog only costs speed.

### Data format

Location: `Application Support/<bundle id>/icloud-catalog/<accountHash>-<zone>.sqlite`. `accountHash` is
`ExportSession.accountHash(appleID:)` (`ExportSession.swift:180`), so the Apple ID itself is never written. `zone` is
`PrimarySync` today. Add `-wal` and `-shm` beside the file. Sign-out deletes the folder (add it to
`ICloudLibrary.clearCaches`, `ICloudLibrary.swift:30`).

```sql
PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;   -- user_version = 1
CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS assets(
  id        TEXT PRIMARY KEY,     -- CPLAsset recordName (the bridge's asset.id)
  master    TEXT,                 -- CPLMaster recordName
  added     REAL,                 -- seconds since 1970, UTC
  created   REAL,                 -- assetDate, seconds since 1970, UTC
  filename  TEXT NOT NULL,
  type      INTEGER NOT NULL,     -- 0 image, 1 movie
  size      INTEGER,              -- the original's bytes
  bytes     INTEGER,              -- what a download writes (original + Live Photo movie)
  lat REAL, lon REAL,             -- from locationEnc; NULL when unknown
  tz        INTEGER,              -- timeZoneOffset in seconds, NULL when unknown
  rank      INTEGER NOT NULL,     -- rank when last seen
  rankCount INTEGER NOT NULL,     -- library count when last seen (to shift old ranks)
  seenAt    REAL NOT NULL         -- when last seen in any listing
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS assets_created ON assets(created);
CREATE INDEX IF NOT EXISTS assets_added   ON assets(added);
CREATE INDEX IF NOT EXISTS assets_seen    ON assets(seenAt);
```

Meta keys: `libraryCount`, `libraryCountAt`, `unlistedCount`, `fullWalkStartedAt`, `fullWalkEndedAt`,
`fullWalkSeen`, `topUpAt`. Migration: if `user_version` isn't 1, or `PRAGMA quick_check` isn't `ok`, delete the files
and create them again. It is a cache, so there is no data to keep. At 93k rows it is about 20 MB.

### Staleness rules (the contract every consumer relies on)
1. **Row freshness.** Every upsert sets `seenAt = now`, `rank`, and `rankCount = libraryCount`. Fields that come in
   as nil keep the stored value (`COALESCE`). `stats` pages update only `bytes`.
2. **Rank hints.** `hint(row) = row.rank + max(0, currentCount − row.rankCount)`. New items only appear at rank 0, so
   this is exact when nothing was deleted above the row, and only a few off otherwise. R12b gives the bridge's
   hinted lookups ±25 of slack to cover that.
3. **Top-up before use.** A consumer that needs completeness first runs `CatalogTopUp`:
   - page from rank 0 (200 per page) until 200 known IDs come in a row, or 5,000 items are scanned;
   - then page the **Recently Deleted** album (≤ 2,000 items, usually one or two queries) and delete those IDs
     from the catalog.
   A top-up that hits the 5,000 cap reports `.tooFar`, and the consumer uses its old network path.
4. **Full walk proves deletions.** When a run has visited every rank (the engine's `visitedEverything`, the same
   moment `ResumePoint` sets `lastFullWalkAt`), or a `stats` walk from offset 0 ends `complete: true`:
   - delete rows with `seenAt < walkStartedAt`. Every item the walk visited has `seenAt ≥ walkStartedAt`. Items
     added during the walk but not visited are kept, because a page saw them after the start.
   - **Guard:** prune only if the rows seen since `walkStartedAt` are at least `0.98 × (libraryCount −
     (unlistedCount ?? 0))`. Otherwise log `catalog: walk saw X of Y, not pruning` and keep everything.
   - Then set `fullWalkEndedAt = now` and `fullWalkSeen = X`.
5. **Trusted** (allowed to answer "everything in a range" or "the size of everything"), when all of these hold:
   - `fullWalkEndedAt` is within `ICloudResumeSettings().fullCheckInterval + 5 days`;
   - a top-up in this session returned `.current`;
   - `|rowCount − (libraryCount − unlistedCount)| ≤ max(50, 0.5 %)`.
   When it isn't trusted, consumers may still use rows as **hints and placeholders**, never as complete answers.
6. **Accounts and libraries.** There is one file per account hash and zone. A destination exported with another
   Apple ID just misses (no rows), and that is fine.

### R12a: `ICloudCatalog` store (Haiku, reviewed by Opus). Can start now; new files only.
- Files: new `Uncloud/Export/ICloud/ICloudCatalog.swift`, new `UncloudTests/ICloudCatalogTests.swift`.
- API:
  ```swift
  actor ICloudCatalog {
      struct Row: Equatable, Sendable {
          var id: String; var master: String?; var added: Date?; var created: Date?; var filename: String
          var isVideo: Bool; var size: Int64?; var bytes: Int64?; var latitude: Double?; var longitude: Double?
          var timeZoneOffset: Int?; var rank: Int; var rankCount: Int; var seenAt: Date
      }
      struct Status: Equatable, Sendable {
          var rowCount: Int; var libraryCount: Int?; var unlistedCount: Int?
          var fullWalkStartedAt: Date?; var fullWalkEndedAt: Date?; var topUpAt: Date?
      }
      enum PruneResult: Equatable, Sendable { case pruned(removed: Int), skipped(seen: Int, expected: Int) }

      static var defaultDirectory: URL { get }
      static func open(account: String, zone: String = "PrimarySync", directory: URL = defaultDirectory,
                       now: @escaping @Sendable () -> Date = Date.init) throws -> ICloudCatalog
      static func removeAll(directory: URL = defaultDirectory)

      func upsert(_ rows: [Row]) throws                 // 1,000 per transaction, prepared statement reused
      func updateBytes(_ sizes: [String: Int64]) throws // stats pages
      func remove(ids: some Collection<String>) throws
      func noteLibraryCount(_ count: Int, unlisted: Int?) throws
      func noteTopUp(at: Date) throws
      func beginFullWalk(at: Date) throws               // stores fullWalkStartedAt
      func completeFullWalk(startedAt: Date, libraryCount: Int, unlistedCount: Int?) throws -> PruneResult
      func rows(ids: some Collection<String>) throws -> [String: Row]   // IN (...) in chunks of 500
      func rows(takenFrom: Date, to: Date, limit: Int) throws -> (rows: [Row], isAtLeast: Bool)
          // WHERE COALESCE(created, added) BETWEEN ? AND ?  ORDER BY rank hint; limit+1 to set isAtLeast
      func page(offset: Int, limit: Int, libraryCount: Int) throws -> [Row]   // ordered by rank hint, then id
      func sizes() throws -> (sizes: [String: Int64], unsized: Int)
      func rankHints(for ids: some Collection<String>, libraryCount: Int) throws -> [String: Int]
      func status() throws -> Status
      func isTrusted(libraryCount: Int, now: Date, maxAge: TimeInterval, toppedUp: Bool) throws -> Bool
  }
  ```
  - Use raw `sqlite3_*` with `SQLITE_OPEN_FULLMUTEX` off, since the actor serializes access.
  - Bind dates as `Double` and missing values with `sqlite3_bind_null`.
  - Use `sqlite3_close_v2` in `deinit`.
  - Errors become `ICloudCatalogError.sqlite(code: Int32, message: String)`.
- Tests (temp folder):
  - Upsert 2,500 rows and read them back.
  - A second upsert with nil `lat` keeps the stored `lat`; a new `rank` replaces the old one.
  - `rows(takenFrom:to:limit:)` returns the right set, and `isAtLeast` is true at limit + 1.
  - `rankHints` adds `currentCount − rankCount`.
  - Prune: rows seen before `startedAt` go when the seen count passes the 98 % guard, and stay (`.skipped`) when it
    doesn't.
  - The trust rules, one case per condition.
  - A file with `user_version = 7` is rebuilt empty.
  - `removeAll` deletes the folder.
  - Bench behind `UNCLOUD_BENCH=1`: 100k upserts take < 2 s and `sizes()` takes < 0.2 s.

### R12b: bridge rows for the catalog (lane P, after R11; Haiku, reviewed by Opus)
- Files: `Uncloud/Helper/photo_bridge.py`, `UncloudTests/Bridge/test_bridge.py`.
- Behaviour:
  - `catalog_fields(asset) -> dict` returns `master` (`asset._master_record["recordName"]`), `lat` and `lon`, and
    `tz` (`timeZoneOffset.value`, an int).
    - `lat` and `lon` come from `locationEnc`: `plistlib.loads(base64.b64decode(value), fmt=plistlib.FMT_BINARY)`,
      keys `lat` and `lon`, exactly as `icloudpd/xmp_sidecar.py:130-136` reads them.
    - If `locationEnc` is missing, use numeric `locationLatitude` and `locationLongitude` when they are there.
    - A value outside ±90/±180, or exactly (0, 0), becomes None.
    - Every field sits in its own try/except and becomes None on any error.
  - `describe()` adds these four keys to every `page` item.
  - **LISTING_KEYS** (R8) gains `locationEnc`, `locationLatitude`, `locationLongitude` and `timeZoneOffset`. R8's
    fixture test (describe of the full record = describe of the filtered record) then covers them.
  - `walk()` gains `on_page: Optional[Callable[[int, List[Any]], None]]`, called on the main thread after each page
    is fetched (R11's prefetcher keeps this order).
  - `_download` in `allExcept` mode, and the closing walk, pass
    `on_page = lambda low, page: channel.send({"id": request_id, "event": "listed", "offset": low,
    "items": [compact(a, low + i) for i, a in enumerate(page)]})`. `compact` is `describe()` without `thumbURL`,
    plus `rank`.
  - `stats` adds `"items": [compact...]` to each `statsProgress`. Swift ignores keys it doesn't know until R12c.
  - **Hint slack:** `HINT_SLACK = 25`. `_hinted` widens each window to `[start − 25, end + 25)`, clamped to
    `start_rank`, merges windows that overlap, and keeps the 30 % rule on the original count.
- Tests:
  - A fake record with a base64 binary-plist `locationEnc` gives `lat` and `lon`. A broken one gives None.
  - A download walk over a 250-item fake album sends 3 `listed` events covering ranks 0..249 once each. The
    overlap may resend a row, which is fine.
  - `statsProgress` carries `items`.
  - A hint that is off by 10 still finds the item without a full walk (count the `fetch_assets` calls).
- Measure: R9's `bytes=` per page before and after. Expect +1–2 % on `page` and about 20 KB per 100-item `listed`
  line.

### R12c: Swift feeds the catalog from every page (Haiku). After FIX-A2 and lane P's Swift part of R11 (both edit nearby code).
- Files:
  - `Uncloud/Export/ICloud/ICloudBridge.swift`: optional `master`, `lat`, `lon`, `tz` on `ICloudBridgeMessage.Item`;
    `Item.asset` maps them.
  - `Uncloud/Export/ICloud/ICloudPageCache.swift`: optional `latitude`, `longitude`, `master`, `timeZoneOffset` on
    `ICloudAsset`, all defaulting to nil.
  - New `Uncloud/Export/ICloud/CatalogFeedingFetcher.swift`.
  - New `Uncloud/Export/ICloud/CatalogTopUp.swift`.
  - The call sites that build `ICloudBridgeFetcher(bridge:)` for the **library** album (`LibraryBrowser.swift:366`,
    `NewPhotosTracker.swift`, `ExportRangeSheet.swift`) wrap it.
  - Tests: new `UncloudTests/CatalogFeedingTests.swift`.
- Behaviour:
  - `struct CatalogFeedingFetcher: ICloudPageFetching { let base: any ICloudPageFetching; let catalog: ICloudCatalog? }`
    - `count()` passes through and calls `noteLibraryCount`.
    - `assets(offset:limit:)` passes through, then upserts the rows (`rank = offset + i`). Upsert errors are logged
      and ignored, so the catalog never fails a page.
    - It is never used for Recently Deleted.
  - `ICloudCatalog.shared(appleID:)` is a lazily opened, process-wide instance per account. It is nil when opening
    fails.
  - `CatalogTopUp.run(fetcher:catalog:recentlyDeleted:overlap: 200, cap: 5_000) async throws -> Result` with
    `enum Result { case current(scanned: Int), tooFar }`. It implements staleness rules 3 and 4 above and calls
    `noteTopUp`.
- Tests:
  - A fake library: pages pass through unchanged and land in the catalog with the right ranks.
  - The top-up stops after 200 known items.
  - Recently Deleted IDs are removed.
  - Hitting the cap gives `.tooFar`.
  - A catalog that can't be opened (read-only folder) still gives pages.

### R12d: storage estimate from the catalog (Haiku). After FIX-A8 and R12c.
- Files: `Uncloud/Model/AssetSizeIndex.swift` (`ICloudSizeScanner`), `Uncloud/Model/StorageEstimator.swift`, tests
  in `StorageEstimateTests.swift`.
- Behaviour:
  - Before planning a scan, if the catalog `isTrusted`, call
    `index.replaceFromCatalog(sizes:libraryCount:)` (the table becomes complete with the catalog's sizes; unsized
    ones stay unknown) and return `.complete` **without** a `stats` walk.
  - Otherwise, today's plan (FIX-A8) runs, and every `statsProgress` also calls `catalog.updateBytes` and upserts
    its `items` when it has them.
  - A `stats` walk from 0 that completes calls `completeFullWalk`.
- Acceptance: with a trusted catalog, the estimate is ready with no `stats` request (a fake bridge counts them). With
  an untrusted one, the behaviour is the same as today.

### R12e: range sheet and suggested date from the catalog (Haiku). After R12c and lane S's R6 (which edits `ExportSince.swift`).
- Files: `Uncloud/Model/ExportSince.swift`, `Uncloud/Views/ExportRangeSheet.swift`, `UncloudTests/ExportSinceTests.swift`.
- Behaviour:
  - New `ExportSince.iCloudItems(takenFrom:to:catalog:fetcher:limit:)`. It runs `CatalogTopUp`. When the catalog
    is trusted, it answers from `catalog.rows(takenFrom:to:limit:)` with `rankHints` as the values. Otherwise it
    calls today's walk unchanged.
  - Same for `iCloudSuggestedDate`: when trusted, take the row with the smallest rank hint whose ID is in `known`
    and use its `added ?? created`.
  - The sheet tops up **once** when it opens, and each From-date change after that is a local query.
- Tests:
  - The trusted path returns the same set as the walk on a fake library of 3,000 items.
  - Changing the date twice sends no further page requests.
  - The untrusted path is identical to today.

### R12f: Library grid opens from the catalog (Haiku, reviewed by Opus). After FIX-A2 and R12c.
- Files: `Uncloud/Model/LibraryBrowser.swift` (the `LibraryBrowserBackend` protocol and `ICloudBrowserBackend`),
  `UncloudTests/LibraryBrowserTests.swift` (or the existing browser tests).
- Behaviour:
  - Add `func placeholderCount() async -> Int?` and `func placeholderPage(_ index: Int, pageSize: Int) async ->
    [LibraryItem]?` to the backend protocol. They default to nil, and the Photos backend keeps nil.
  - The iCloud backend answers from `catalog.status().libraryCount` and `catalog.page(...)`.
  - `LibraryBrowser`:
    - shows the placeholder count right away (`state = .ready`) while the real count loads;
    - when a page starts loading, stores the placeholder page with `isPlaceholder = true`, so tiles show the
      thumbnail already saved on disk (`thumbnailData(forID:)` reads the disk cache by ID);
    - replaces the page when the live page arrives. If the real count differs, it keeps the live count.
  - Placeholders never feed rank hints or selections. Selecting is disabled on placeholder tiles until the live
    page arrives.
- Tests:
  - With a fake backend whose live page is slow, `item(at: 0)` returns the placeholder first and then the live
    item.
  - A count mismatch takes the live count.

### R12g: the export engine feeds the catalog and proves deletions (Haiku, reviewed by Opus). After R12b and R12c.
- Files:
  - `Uncloud/Export/ICloud/ICloudBridge.swift`: a new `ICloudBridgeDownloadEvent.listed(offset: Int, items:
    [ICloudBridgeMessage.Item])`. Grep for every `switch` over the enum and add the case.
  - `Uncloud/Export/ICloud/ICloudExportEngine.swift`: on `.listed`, upsert into `ICloudCatalog.shared`, batched by
    the actor.
  - At the start of a run that may visit everything, call `beginFullWalk(at: runStart)`.
  - Where the run computes `visitedEverything` for `ResumePoint.point(...)`, call
    `completeFullWalk(startedAt:libraryCount:unlistedCount:)`.
  - The quick update's `.only` plan adds `catalog.rankHints` for IDs the plan doesn't already rank. The plan ranks
    are exact and win.
- Tests (with the engine's existing fake bridge):
  - A full walk upserts every item and then prunes a row that wasn't seen.
  - A walk that ends early (cancel or throttle) never prunes.
  - `listed` events don't change any count, progress or activity line.

---

## 3. P4: Browse dates and places from iCloud metadata (R18a–R18b)

### R18a: Browse index uses catalog rows for iCloud-ID records (Haiku). After lane S's R4 (which edits `BrowseIndex.swift`) and R12a.
- Files: `Uncloud/Export/BrowseIndex.swift`, `Uncloud/Model/BrowseBackup.swift` (where `BrowseIndexer.update` is
  called, around line 446), tests in the BrowseIndex test file.
- Behaviour:
  - Add an `iCloudMetadata: [String: BrowseMetadata]` parameter to `BrowseIndexer.update` (default empty). It maps
    a media path to metadata and is built by the caller:
    - for each `icloud-id:` record (`ExportManifest.iCloudItems(in:)`), take its media paths (the same filter as
      `mediaPaths`: no `.xmp`, no Live Photo movie when the photo is recorded);
    - look the IDs up with `catalog.rows(ids:)`;
    - give `BrowseMetadata(latitude: row.latitude, longitude: row.longitude, date: row.created ?? row.added,
      camera: nil)`.
  - In `update`, when a path is new or changed and `iCloudMetadata[path]` has a non-nil date, build the entry from
    it and **don't call `read`**. Set a new `BrowseEntry.source: Source?` (`enum Source: String, Codable { case
    file, iCloud }`; nil means file, so old index files still decode).
  - Paths with no row, a row without a date, `icloud:` legacy records and Photos-library records read the file as
    today (EXIF, then the XMP sidecar).
  - An iCloud row with a date but no location stays without a location. iCloud's location is what Photos shows.
  - Catalog trust doesn't matter here. Rows are per ID and don't need completeness.
- Data notes: `created` is iCloud's `assetDate`, an instant. The EXIF path also produces an instant (with the
  recorded offset), and grouping uses `Calendar.current` in both cases, so the day and month sections stay the
  same. `tz` is stored in the catalog for later use (for example, showing the local time it was taken), but not
  used yet.
- Tests:
  - A record with a catalog row is never read (a counting `read` closure) and gets the row's date and place.
  - A record without a row is read.
  - An old index JSON without `source` decodes.
  - A changed file whose row exists is updated from the row, not read.
- Measure: first Browse build on the owner's drive. Expected about 1 min (catalog lookups plus the lane S listing),
  down from 45–90 min.

### R18b: camera name on demand (Haiku). After R18a.
- Files: `Uncloud/Model/BrowseBackup.swift` (new `func camera(for path: String) async -> String?`),
  `Uncloud/Views/BrowsePhotoViews.swift:274`.
- Behaviour:
  - If the entry's `camera` is nil and `source == .iCloud`, read the file once with `BrowseMetadata.read`, store
    the camera in the entry (and persist with the next save), and show "Reading…" meanwhile. If nothing is found,
    show "Unknown" as now.
  - Store an empty string to mean "looked, none", so the file isn't read again.
- Tests: the second request doesn't read again, and an empty camera shows "Unknown".

---

## 4. Verify v2 (R14a–R14c)

### R14a: resumable full pass in disk order (Haiku, reviewed by Opus). Can start now.
- Files:
  - New `Uncloud/Export/SequentialFileReader.swift`. It is not `FileHasher.swift`, which the export plan may change.
  - New `Uncloud/Export/VerifyCheckpoint.swift`.
  - `Uncloud/Export/BackupVerifier.swift`.
  - New `UncloudTests/BackupVerifierResumeTests.swift`.
- `SequentialFileReader.sha256(of url: URL, bufferSize: Int = 4 << 20) throws -> String`:
  - `open(O_RDONLY)`, `fcntl(F_NOCACHE, 1)`, `fcntl(F_RDAHEAD, 1)`;
  - `read` into one reused 4 MB buffer, feeding `SHA256` with `UnsafeRawBufferPointer`;
  - `Task.checkCancellation()` between buffers. `EINTR` retries.
- Order: items in **first-record order** (`ExportManifest.firstRecordPositions`). Files were written in that order,
  so on a disk this is close to physical order. Within an item, use the record's path order.
- Checkpoint at `Application Support/Uncloud/Verify/<NewPhotosContext.destinationKey(for:)>.json`. It is not on the
  drive, because verifying stays read-only.
  ```json
  {"schema":1,"startedAt":"2026-10-21T10:00:00.000Z","journalBytes":6213377,"journalHead":"<sha256 of first 64 KB>",
   "nextItemIndex":41200,"checkedFileCount":45831,"verifiedCount":41010,
   "damagedItemIDs":[...],"unverifiableItemIDs":[...],"missingFiles":[...],"damagedFiles":[...],"updatedAt":"..."}
  ```
  - Save it every 1,000 files or 60 s (whichever comes first), on cancel, and on throw. Write it atomically.
    Delete it when the pass finishes.
  - It is **valid** when `exported.tsv` is at least `journalBytes` long and its first 64 KB hash to `journalHead`.
    The journal is append-only, so the order up to `nextItemIndex` hasn't changed and items appended since come
    later in the order.
  - It is **invalid** when the journal shrank or its head changed (forget, relocate, Reorganize). The pass then
    starts over and the sheet says why.
- API: `BackupVerifier.verify(destination:itemIDs:libraryIDs:checkpoint: VerifyCheckpointStore?, progress:)`.
  - `itemIDs != nil` (Free Up Space, re-checks of problem items) never uses a checkpoint.
  - When resuming, `verifiedItemIDs` = the IDs before `nextItemIndex` minus the problem sets. The order is
    deterministic, so this can be rebuilt instead of stored.
- Tests:
  - Cancel after 30 of 100 files (a fake clock and a cancel at a set file), resume, and the report equals an
    uninterrupted run.
  - Appending records between runs adds them at the end.
  - A `forget` between runs invalidates the checkpoint.
  - `SequentialFileReader` equals `FileHasher.sha256` on 0 bytes, 1 byte, 4 MB, 4 MB + 1 and 13 MB files.
  - A damaged file is still found after a resume.
- No parallel hashing (wave 1 §2 P5: two readers on one HDD are slower).

### R14b: quick check from one listing (Haiku). After lane S's R1.
- Files: new `Uncloud/Export/QuickVerifier.swift`, new `UncloudTests/QuickVerifierTests.swift`.
- API: `QuickVerifier.check(destination: URL, catalogSizes: [String: Int64]? = nil) throws -> QuickVerifyReport`.
- Behaviour:
  - Read the records (without `icloud-partial:`), `filesSnapshot` (optional) and the catalog sizes (optional; the
    caller passes `catalog.sizes()`).
  - List each folder that holds recorded paths **once** with `BulkDirectoryLister`.
  - For each file, record:
    - **missing:** not in its folder's listing, or not a regular file;
    - **empty:** size 0;
    - **changed:** `files.tsv` has it and the size differs, or the mtime differs by more than 2 s (FAT keeps 2 s);
    - **shortOrLong** (iCloud-ID items only, when the catalog has `bytes`): the sum of the item's media file sizes
      (no `.xmp`) ≠ `bytes`. That is usually a truncated download.
  - Result:
    ```swift
    struct QuickVerifyReport: Equatable, Sendable {
        var checkedFiles: Int; var okItems: Int; var seconds: Double
        var missingFiles: [String]; var emptyFiles: [String]; var changedFiles: [String]
        var sizeMismatchItemIDs: Set<String>   // manifest keys
        var problemItemIDs: Set<String>        // union, for "Check These Fully" / re-export
    }
    ```
  - Read-only: nothing is opened except the folders and the manifest.
- Tests: a fixture with one missing file, one 0-byte file, one file whose size changed since `files.tsv`, one item
  whose sizes don't add up to the catalog `bytes`, and a clean month folder. Each lands in the right list, and the
  clean items count as ok.
- Measure: seconds on the owner's drive. Expected about the lister's time plus the parse, 2–10 s.

### R14c: Verify sheet with Quick and Full (Haiku, design pass by the "designer" agent). After R14a and R14b.
- Files: `Uncloud/Model/BackupVerification.swift`, `Uncloud/Views/VerifyBackupSheet.swift`, tests.
- Behaviour:
  - Two actions: **Quick Check** (default; "Checks that every file is there and the right size. Takes seconds.")
    and **Full Check** ("Reads every file and compares it with its checksum. Takes hours on a large backup. You
    can stop and continue later.").
  - When a valid checkpoint exists, Full Check reads "Continue Full Check (44 % done)", with a secondary "Start
    Over".
  - Quick-check problems offer "Check These Fully" (`verify(itemIDs: problemItemIDs)`) and the existing re-export.
  - Progress shows files, GB read and an ETA from the measured rate.
  - The paywall (`PaidFeature.verifyBackup`) covers both actions, as now.
- Tests:
  - State machine: quick → finished; full cancel → `.ready` with `canContinue`; a stale checkpoint shows "Start
    Over" only.

---

## 5. Hidden `._` files (R16a–R16c)

**Background.** On exFAT/FAT, macOS stores extended attributes in an AppleDouble companion `._NAME`. Every file the
sandboxed app writes gets `com.apple.quarantine`, and a sandboxed process may not remove that attribute (EPERM; see
the 0.1.12 result in export-speed-plan Part 2). So every photo has a 4 KB `._` file. Deleting the `._` file *is*
removing the attribute on these volumes, and it is a plain unlink in a folder the user chose. Whether the sandbox
allows it is **not yet proven** (R16b).

**What else a `._` file can hold** (and why the classifier must parse it, not guess from the name):
- the **Finder info** (32 bytes: type and creator codes, Finder flags such as hidden, the colour label, and the
  "extension hidden" flag);
- a **resource fork** (entry ID 2, often length 0, sometimes real data: old Mac files, custom icons, fonts);
- **any extended attribute**: Finder tags (`com.apple.metadata:_kMDItemUserTags`), "Where from"
  (`kMDItemWhereFroms`), `com.apple.lastuseddate#PS`, `com.apple.provenance`, `com.apple.macl`,
  `com.apple.FinderInfo`, `com.apple.ResourceFork`, or an app's own attributes.
Any of these can be the user's data, or something macOS needs. Only **quarantine-only** (or completely empty)
companions are deleted.

### Byte format (as XNU's `vfs_xattr.c` and `copyfile` write it). R16a confirms it against a real file.
- Header (big-endian): `magic u32 = 0x00051607`, `version u32 = 0x00020000`, `filler[16]` ("Mac OS X" + spaces),
  `numEntries u16`, then `numEntries × {id u32, offset u32, length u32}`.
- Entries macOS writes: ID **9** (Finder info) at offset 50 (0x32), and ID **2** (resource fork), usually at the end
  of the file with length 0.
- When there are xattrs, the Finder-info entry is longer than 32 bytes. After the 32 Finder-info bytes and 2 pad
  bytes (so at offset 84), comes the attribute header: `magic u32 = 'ATTR' (0x41545452)`, `debug_tag u32`,
  `total_size u32`, `data_start u32`, `data_length u32`, `reserved[3] u32`, `flags u16`, `num_attrs u16`.
- Then `num_attrs` entries: `{offset u32, length u32, flags u16, namelen u8, name[namelen] (NUL included)}`, each
  padded to a 4-byte boundary. Values sit at `offset` and run for `length` bytes from the start of the file.

### R16a: AppleDouble classifier (Haiku, reviewed by Opus). Can start now; pure code.
- Files: new `Uncloud/Export/AppleDouble.swift`, new `UncloudTests/AppleDoubleTests.swift`, and fixtures under
  `UncloudTests/Fixtures/AppleDouble/`.
- API:
  ```swift
  enum AppleDouble {
      enum Verdict: Equatable, Sendable {
          case quarantineOnly          // safe to delete
          case empty                   // valid header, zero Finder info, no resource fork, no attributes: safe
          case keep(reason: String)    // anything else: other attributes, Finder info, resource fork, malformed
      }
      static let deletableAttributes: Set<String> = ["com.apple.quarantine"]
      static func classify(_ data: Data) -> Verdict
      static func attributeNames(_ data: Data) -> [String]?   // for the R16b histogram and logs
  }
  ```
- Rules. The answer is `keep` unless **all** of these hold:
  - `data.count ≤ 65_536`;
  - the magic and version are right;
  - there are 1–2 entries, with IDs only from {9, 2};
  - every entry's range lies inside the data;
  - entry 2 (if present) has length 0;
  - entry 9 has length ≥ 32 and its first 32 bytes are all zero;
  - if entry 9 is longer than 32 bytes: `ATTR` magic at offset `entry9.offset + 34`, `num_attrs ≤ 64`, every
    attribute entry and value inside the data, every name NUL-terminated within `namelen`, and every name in
    `deletableAttributes`.
  Zero attributes gives `.empty`. One or more attributes, all allowed, gives `.quarantineOnly`.
- Tests:
  - Builders in the test create byte-exact files: quarantine only; quarantine plus tags; non-zero Finder info (a
    colour label); a resource fork of 10 bytes; truncated; a wrong magic; an attribute name not NUL-terminated; an
    attribute offset beyond the end; 0 attributes.
  - **Plus one real fixture:** `appledouble-quarantine.bin`, a `._` file made on an exFAT disk image by a sandboxed
    write (from R16b). It must classify as `.quarantineOnly`, and `attributeNames` must equal what `xattr -l`
    listed for its photo.

### R16b: sandbox experiment on a scratch exFAT image (Opus with the owner, 30 min). Before R16c.
Nobody has shown yet that a sandboxed Uncloud may unlink `._X` in its chosen folder.
- Opus, in Terminal, outside the app:
  1. `hdiutil create -size 200m -fs ExFAT -volname UNCLOUDTEST <scratch>/test.dmg`
  2. `hdiutil attach <scratch>/test.dmg -mountpoint <scratch>/mnt` (not `/Volumes`). Check with `mount` that the
     driver is FSKit `exfat`, the owner's driver.
- A debug-only hook (`#if DEBUG`, in a new `Uncloud/Export/AppleDoubleProbe.swift` and called from a hidden Debug
  menu item that ships in no release):
  - in the user-chosen folder (the owner picks `<scratch>/mnt` in the folder picker, so it is a real sandbox
    grant), write `probe.jpg`;
  - list the folder;
  - read `._probe.jpg`, classify it and copy its bytes to `<container tmp>/appledouble-quarantine.bin`;
  - `unlink("._probe.jpg")`;
  - `getxattr("probe.jpg", "com.apple.quarantine")`;
  - list again;
  - also `renameatx_np("probe.jpg" → "2024/07/probe.jpg", RENAME_EXCL)` and report where `._probe.jpg` ended up
    (whether the kernel moves the companion on rename, which R17b needs);
  - print one result line per step to the activity list.
- On the owner's real drive, a **read-only** histogram:
  `readbench appledouble <folder>` (an R0 extension). It reads the first 64 KB of each `._` file and prints counts
  per attribute-name set. This tells us whether `com.apple.provenance` or anything else sits next to the
  quarantine flag.
- Outcomes:
  - (a) unlink works and quarantine reads ENOATTR afterwards: build R16c.
  - (b) EPERM: stop and report it, as Part 2 did. The options are a Developer ID (non-sandboxed) build, or telling
    the owner the files are harmless. Don't invent a workaround.
  - (c) The histogram shows `com.apple.provenance` on most files: the owner decides whether to add it to
    `deletableAttributes`. It is a system provenance tag, not user data.
- Detach the image afterwards: `hdiutil detach <scratch>/mnt`.

### R16c: "Remove Hidden Helper Files" (Haiku, design by "designer"). After R16a, R16b (a) and lane S's R1.
- Files:
  - new `Uncloud/Export/AppleDoubleCleanup.swift` (engine);
  - new `Uncloud/Model/HelperFileCleanup.swift` (`@Observable` model);
  - new `Uncloud/Views/HelperFileCleanupSheet.swift`;
  - `Uncloud/Model/BackupTools.swift` (a new `Sheet.helperFiles`, `canOpenHelperFiles`, and joining
    `isExportBlocked`);
  - `Uncloud/Views/BackupToolSheets.swift` (the sheet case, and a button shown only when the volume needs it);
  - tests.
- Engine:
  - `AppleDoubleCleanup.isNeeded(at url: URL) -> Bool`: `getattrlist` volume capabilities. True only when
    `VOL_CAP_INT_EXTENDED_ATTR` is **not** set. On APFS and HFS+, `._` files are ordinary user files and the tool
    never runs.
  - `scan(destination:records:) async throws -> Plan` lists every folder of the backup once with
    `BulkDirectoryLister`. Candidates are regular files named `._X` where `X` is in the same listing **and** is a
    recorded path. Read each candidate (≤ 64 KB) and classify it.
    `Plan { deletable: [String]; keptOther: Int; orphans: Int; bytes: Int64 }`.
  - `remove(plan:progress:)` re-reads and re-classifies each file right before `unlinkat`, so the check isn't
    stale. Never follow symlinks. Stop on the first EPERM or EROFS with a clear message. Report progress every 500
    files.
  - Also `cleanFilesOfRun(paths:destination:)`: the same check for the files one export just wrote. ExportModel
    calls it after a run in a later one-line change (owner option "Remove helper files after each export", on by
    default once R16b passes).
- Sheet text:
  - Example: "Your backup drive keeps a hidden helper file next to each photo (104,188 files). Each one only notes
    that the photo was saved by Uncloud. Removing them makes the folder about twice as fast to read. 12 helper
    files hold other information and are kept."
  - Buttons: Remove and Cancel. Show progress and the result.
- Tests:
  - On a temp folder: an APFS temp folder is `isNeeded == false`, so the tests call the engine with
    `force: true`.
  - Deletable, kept, orphan and not-recorded companions are each handled correctly.
  - A file changed between scan and remove is kept.
  - EPERM from a fake `unlink` stops the run.
- Cost on the owner's flat folder: one open per `._` file, an exFAT lookup at ~10–20 ms each, so about 30–60 min.
  After Reorganize (§6), lookups are in folders of about 100–1,500 entries and take seconds. **Recommended order:
  Reorganize first, which handles companions as it moves (R17b).**

---

## 6. Reorganize into Month Folders (R17a–R17e)

**Goal.** A flat (`All in One Folder`) backup becomes `YYYY/MM/NAME`, the paths icloudpd's `{:%Y/%m}` layout uses.
Every file is moved with `rename` on the same volume (no copying, no download), and the manifest, `files.tsv`,
`resume.json`, `layout` and the Browse index are updated, so the next export continues in month layout without
fetching anything again. Every step is resumable from a journal on the drive.

### Rules
- **What moves.** Every top-level path listed in a record of `exported.tsv` (`icloud-id:`, `icloud:`,
  `icloud-partial:` and Photos-library IDs) that exists in the root listing. Unrecorded files (the user's own files,
  the "other files" of `ExportModel.flatFolderOtherFiles`) and `.photo-export` **never move**.
- **The item's month:**
  - `icloud-id:` items use the catalog's `created` if it has a row. Otherwise they use the primary media file's
    mtime, which is exactly icloudpd's `created` because `download.update_mtime` sets it
    (`photo_bridge.py:598`, `icloudpd/download.py:23-43`).
  - `icloud:` and `icloud-partial:` items use the mtime.
  - Photos-library items use `PHAsset.creationDate` when Photos access is granted. Otherwise EXIF
    `DateTimeOriginal`. Otherwise `Undated/`.
  - All are formatted in `Calendar.current` as `%04d/%02d`, the same as `ExportEngine.folderPath`
    (`ExportEngine.swift:135-137, 161-162`) and icloudpd (`base.py:587, 601`).
  - iCloud items never go to `Undated/`, because `DriveCheck.isItem(paths:in: .month)` (`DriveCheck.swift:34-38`)
    requires `YYYY/MM/name`.
  - Caveat to tell the owner: a photo near a month boundary that was downloaded in another time zone may land
    one month off compared with a fresh icloudpd run. Uncloud itself finds items by ID, so it is unaffected.
- **Grouping.** All files of an item go to that item's month: the photo, its Live Photo movie and its XMP sidecar.
  A movie-only item uses its own date.
- **Names.**
  - Plan the names of every target folder up front, against the folder's current listing plus all names already
    planned for it. The plan is deterministic: plain names first, in path order, then suffixed ones.
  - *icloudpd compatibility:* a flat file named `S-N.E`, where `N` equals the file's own size, carries icloudpd's
    `name-size-dedup-with-suffix` suffix (`base.py:673-681`; Live Photo movies the same way, `base.py:791-797`).
    If `S.E` is free in the target month, it is renamed to `S.E`, which is what icloudpd's month run would name
    it. Otherwise it keeps `S-N.E`, which is also what icloudpd would produce.
  - A plain name that is taken in the target becomes `S-<size>.E`. If that is taken too, it becomes
    `S-<size>_2.E`, `_3` and so on.
  - Sidecars follow their media: `<oldStem>.xmp` becomes `<newStem>.xmp`, and `<oldName>.xmp` becomes
    `<newName>.xmp`, with the same collision rule.
- **Companions (`._X`).**
  - After each batch of 500 moves, list the root again. For each moved `X` whose `._X` is still in the root
    (R16b tells us whether the kernel moves companions on rename):
    - if `AppleDouble.classify` says quarantine-only or empty **and** the owner ticked "also remove hidden
      helper files" (default on when R16b passed), unlink it;
    - otherwise rename it next to the moved file as `._<newName>` (`RENAME_EXCL`). If that name is taken, leave
      it and log it.
  - Never delete a companion that holds other data.
- **Safety.**
  - Use `renameatx_np(rootFD, old, rootFD, new, RENAME_EXCL)` only. Never overwrite and never copy. `EXDEV` aborts
    with "the folder spans two drives".
  - Refuse to start when:
    - the layout isn't flat;
    - an export, drive check, verify, duplicates scan or Browse build is running;
    - `run-in-progress` exists (`ExportManifest.hasIncompleteRun`);
    - free space is below 50 MB (for new directory entries);
    - the volume is read-only.

### Journal format: `.photo-export/reorganize.journal` (UTF-8, tab-separated, append-only)
```
uncloud-reorganize	1	2026-10-21T10:00:00.000Z	flat	month	<planned file count>	<removeHelpers 0|1>
plan	<index>	<old relative path>	<new relative path>	<item key>
...
planned	<count>
done	<index>
renamed	<index>	<newer relative path>          (an EEXIST found while moving; this name replaces the plan's)
companion	<index>	deleted|moved|kept
...
moves-finished
manifest-finished
finished
```
- Write the header and plan lines, then `fsync`, then `planned`, then `fsync`, and only then move anything.
- After moves, `done` lines are appended and `fsync`'d every 200 moves and at every pause.
- **Recovery** (on launch, when the destination is chosen, or when the sheet opens) for a journal without
  `finished`:
  - for each planned index without `done`, look it up in the listings of the root and the target folder:
    - old present, new absent: pending;
    - old absent, new present: done, because it crashed before the journal line;
    - both present: a conflict. Stop and show both paths. It can only happen through outside changes.
    - neither present: skipped and logged.
  - Then continue from the first phase that hasn't finished.
- Phases are idempotent. The old paths have no `/` and every new path has one, so a mapping can never chain.
- **Undo** (offered while the journal isn't `finished`, and for 7 days after, from the `.done` copy): move every
  `done` file back new → old with `RENAME_EXCL`, rewrite the manifest with the inverse map, and restore the
  `layout`.
- On `finished`: rename the journal to `reorganize-<yyyyMMdd-HHmmss>.done`, kept for history and Undo.

### R17a: planner (Haiku, reviewed by Opus). Can start now; pure code, new files.
- Files: new `Uncloud/Export/ReorganizePlanner.swift`, new `UncloudTests/ReorganizePlannerTests.swift`.
- API:
  ```swift
  enum ReorganizePlanner {
      struct Input: Sendable {
          var records: [String: [String]]                  // exported.tsv (keys with prefixes)
          var rootListing: [String: (size: Int64, modified: Double)]   // regular files in the root
          var targetListings: [String: Set<String>]        // "YYYY/MM" → names already there
          var createdByKey: [String: Date]                 // catalog / PhotoKit dates, by record key
          var calendar: Calendar
      }
      struct Move: Equatable, Sendable { var index: Int; var old: String; var new: String; var key: String }
      struct Plan: Equatable, Sendable { var moves: [Move]; var months: [String]; var renamedForICloud: Int; var collisions: Int; var staying: Int }
      static func plan(_ input: Input) -> Plan
  }
  ```
- Tests:
  - a Live Photo pair and its sidecar go to one month;
  - `IMG_1-2483921.HEIC` (with a 2,483,921-byte file) becomes `IMG_1.HEIC` when that name is free, and keeps its
    name when `IMG_1.HEIC` is already in that month;
  - two items both called `IMG_2.JPG` in the same month: the first keeps the name and the second becomes
    `IMG_2-<size>.JPG`;
  - an item already in a subfolder isn't moved;
  - unrecorded and `.photo-export` files stay;
  - an `icloud-id` item with no catalog date uses the mtime, in a test calendar fixed to `America/New_York`, near
    a month boundary;
  - a Photos-library item with no date goes to `Undated/`;
  - the output is deterministic: the same input gives the same plan.

### R17b: journal, mover, recovery, undo (Haiku, reviewed by Opus). After R17a, R16a and lane S's R1.
- Files: new `Uncloud/Export/ReorganizeJournal.swift` (read, append, fsync, recover), new
  `Uncloud/Export/ReorganizeExecutor.swift`, new `UncloudTests/ReorganizeExecutorTests.swift`.
- API:
  ```swift
  actor ReorganizeExecutor {
      enum Phase: Equatable, Sendable { case planning, moving(done: Int, total: Int), updatingRecords, finished, paused, failed(String) }
      init(destination: URL, removeHelpers: Bool, fs: ReorganizeFileSystem = .live)
      func start(plan: ReorganizePlanner.Plan) async throws
      func resume() async throws      // recovery, as above
      func undo() async throws
      static func pendingJournal(in destination: URL) -> ReorganizeJournal?   // for gating and launch recovery
  }
  ```
  - `ReorganizeFileSystem` is a small protocol (`rename`, `unlink`, `mkdir`, `list`, `read`, `fsync`) so tests can
    inject a crash after the Nth rename or an EEXIST.
  - The manifest phase calls R17c.
- Tests:
  - A crash (a thrown injected error) after rename 37, before its `done` line: `resume` finishes, nothing is lost
    or moved twice, and the result equals an uninterrupted run.
  - A crash after the moves, before the manifest phase: `resume` runs only the manifest phase.
  - An EEXIST during the move writes `renamed` and the file lands at the next free name.
  - A companion that holds tags is moved, never deleted.
  - Undo restores the tree byte for byte (checked against a snapshot of the names and sizes).
  - A conflict stops the run with both paths.

### R17c: manifest relocation (Haiku). After lane M's R7 (both edit `ExportManifest.swift`, and R7's cache must be dropped on write).
- Files: `Uncloud/Export/ExportManifest.swift` (one new static function), tests in `ExportManifestTests`.
- `static func relocate(_ map: [String: String], in destination: URL, layout: FolderLayout) throws`. Each step uses
  the existing `replaceFile` (atomic and fsync'd) and drops R7's cache entries:
  1. `exported.tsv`: replace every path field found in `map` on **every** line. Keys stay the same and lines stay in
     order, so `firstRecordPositions` doesn't change.
  2. `checksums.tsv`: replace the path in the first field.
  3. `files.tsv`: re-key the `file` lines and drop every `dir` line. The next drive check rescans the folders.
     With R1/R2 that takes seconds.
  4. `resume.json`: when it exists and its `layout == "flat"`, set `layout = "month"` and keep everything else
     (`ICloudResumePoint.load/save`). Ranks don't depend on paths.
  5. `layout`: write `month`.
  - It is idempotent: running it twice gives the same files.
- Tests: a fixture manifest with all record kinds, a partial last line (kept as it was) and duplicate keys. The
  output equals a hand-written expected manifest, and a second run changes nothing.

### R17d: sheet, gating and Browse index remap (Haiku, design by "designer"). After R17b, R17c and R16c (both edit `BackupTools.swift`).
- Files:
  - new `Uncloud/Model/BackupReorganize.swift` (`@Observable`);
  - new `Uncloud/Views/ReorganizeSheet.swift`;
  - `Uncloud/Model/BackupTools.swift` (a new `Sheet.reorganize`, joining `isExportBlocked` while a journal is
    pending, and the can-open rules);
  - `Uncloud/Views/BackupToolSheets.swift` (the case, and a button shown only for the flat layout);
  - `Uncloud/Export/BrowseIndex.swift` (`BrowseIndexStore.remap(key:map:)` re-keys the entries; size and mtime
    survive a rename, so nothing is read again; after lane S's R4);
  - tests.
- UI flow:
  1. A dry run (read-only, seconds with the lister). Example: "Move 104,188 files into 212 month folders, like
     2024/07. Nothing is downloaded or copied. 37 files get their simpler iCloud names back. 3 files of your own
     stay where they are. Estimated time: about 1–2 hours. You can stop and continue later. Exports wait until it
     finishes." The "Also remove hidden helper files" checkbox is shown only when R16c is available and the volume
     needs it.
  2. **Reorganize**.
  3. Progress: files moved of the total, the month being filled, the rate and an ETA, and a **Pause** button.
     Pause is safe. Exports stay blocked until the reorganize finishes or is undone.
  4. Done: "Your backup is now organized by month." Show a **Undo** button for 7 days.
  - Interrupted state, on launch: a banner in the sheet and on the tool button: "Reorganizing was interrupted.
    Continue or Undo."
- Paywall: an **owner question**. Recommendation: free, since it repairs slowness the sandbox causes.

### R17e: ExportModel adopts the new layout (whoever holds `ExportModel.swift`; Haiku, ~20 lines).
- Add `func adoptReorganizedLayout(_ layout: FolderLayout, movedCount: Int)`. It sets `layout` without the
  confirmation of `requestLayoutChange` (the files are already where the month layout expects them), records the
  activity line "Reorganized into month folders: 104,188 files moved.", and calls `refreshProgress()`.
- `startExport` refuses while `ReorganizeExecutor.pendingJournal(in:)` isn't nil, with the message "Finish or undo
  the reorganize first." This also covers a crash that left a journal before `BackupTools` exists.
- Test: after adopt, `layout == .month` and no `pendingLayoutChange`.
- Measure on the owner's drive, before and after: Check Backup Folder, Browse first build, and a routine Export New
  Photos (the per-item `os.path.isfile` lookups get about 100× cheaper).

---

## 7. P3: CloudKit change-token spike (R13)

**Question.** Will Apple's web endpoint accept `changes/zone` (or `changes/database`) from pyicloud_ipd's session?
If so, does it return new, changed and deleted records since a token in one or a few requests?

Facts from the code:
- pyicloud_ipd sends `getCurrentSyncToken: True` on every request (`pyicloud_ipd/services/photos.py:408`), and its
  own TODO asks whether the token changes (`photos.py:415-418`). So every `records/query` answer may already carry
  a `syncToken`.
- The bridge already POSTs its own CloudKit bodies through `library.session` to
  `f"{library.service_endpoint}/records/modify?{urlencode(library.params)}"` with `library.zone_id`
  (`photo_bridge.py:1164-1185`). The spike uses the same path with `changes/zone`.

### R13: spike script (Haiku writes it, Opus runs it once with the owner)
- Files: new `Tools/ChangesSpike/changes_spike.py` and `Tools/ChangesSpike/README` (5 lines). **It doesn't edit
  `photo_bridge.py`**: it imports it (`sys.path` insert, then `import photo_bridge`) and reuses its `authenticate()`.
  So it doesn't collide with lane P and isn't part of the app.
- Sign-in (owner present, in Terminal, into a **temporary** cookie folder; never the app container, never the
  Keychain):
  ```
  PY=Vendor/icloudpd-runtime/python/bin/python3.13
  $PY -I -B -c 'import sys; from icloudpd.cli import cli; sys.argv=["icloudpd"]+sys.argv[1:]; sys.exit(cli())' \
      --auth-only -u "$APPLE_ID" --cookie-directory "$SCRATCH/spike-cookies"
  ```
  The owner types the password and the 2FA code. Afterwards: `rm -rf "$SCRATCH/spike-cookies"`. The owner may see
  a "new sign-in" notice.
- Script steps (each step's result is written to `$SCRATCH/spike-<step>.json`, with tokens shortened to their
  first 12 characters and no record contents beyond counts, types and field names):
  1. **Token in the query answer.** Fetch one page (`fetch_assets(library.all, 0, 10)`) with a patched
     `photos_request` that keeps the raw JSON, and report `"syncToken" in response` and its length.
     Also POST `zones/list` and report each zone's keys (is `syncToken` there?).
  2. **`changes/zone` with no token.** POST `f"{library.service_endpoint}/changes/zone?{urlencode(library.params)}"`
     with:
     ```json
     {"zones":[{"zoneID": <library.zone_id>, "desiredRecordTypes":["CPLAsset","CPLMaster"],
                "desiredKeys":["recordName","recordType","addedDate","assetDate","isDeleted","masterRef","resOriginalRes"],
                "reverse":false}],
      "resultsLimit":200}
     ```
     Record: the HTTP status; the body's top-level keys; per zone `syncToken`, `moreComing` and `len(records)` by
     type; how many records are `deleted: true`; and the seconds. Follow `moreComing` for at most **5** pages
     (enough to see it page; this isn't a full sync).
  3. **`changes/zone` with the token from step 1** (if any), and with the token from step 2. Same output. If it
     answers, does it return only a few records (good), or everything again?
  4. **`changes/database`** (`{"syncToken": null}`, then with its own token): which zones does it list, and does it
     return a token?
  5. **A real delta.** The owner takes or imports **one** test photo on the iPhone and waits about 1 min for it to
     upload. Repeat step 3 with the token saved after step 3. Expected: one `CPLAsset` and one `CPLMaster`.
     Optional: the owner moves that photo to Recently Deleted, and we look for `isDeleted = 1` on the asset (or
     `deleted: true`). **The spike never deletes anything itself.**
  6. Write `$SCRATCH/spike-summary.json` with every step's status and counts, and the time of each request.
- Success means all of these:
  - (a) step 3 or step 5 answers 200 with a `syncToken`;
  - (b) a token from step 1 or step 2 gives a **small** delta (≤ 10 records when nothing changed, and exactly the
    new asset plus master in step 5);
  - (c) a deletion shows up (an `isDeleted` change on the asset, or a `deleted` record);
  - (d) no 401/421 and no re-authentication.
  - If only the no-token call works (the full zone has to be paged first), that is a **partial** success: the
    first sync costs about one full walk of all record types (albums, relations, and so on), and later syncs are
    cheap.
- What we'd build if it works (R13b, outline; plan it in detail after the spike):
  - A bridge `changes` command: `{"cmd":"changes","syncToken":T}` returns `{"event":"changes","added":[compact
    rows],"changed":[...],"deleted":[ids],"syncToken":T2,"moreComing":false}`.
  - The catalog stores `syncToken` in `meta`, and the next token is saved only after the delta is applied.
  - `CatalogTopUp` becomes "apply the delta". New-photo counts are exact (`added` since the token), the quick
    update needs no scan, and deletions are known without the monthly walk. The monthly walk stays as a safety
    net (a token can expire; CloudKit answers `ZONE_NOT_FOUND`/`CHANGE_TOKEN_EXPIRED`, and we then fall back to
    the walk).
  - Ranks still come from the query walk, because a change feed has no ranks. Downloads keep using hint windows,
    which the catalog's shifted ranks plus R12b's slack serve.
- If it fails (403, `BAD_REQUEST` or an empty answer), write it down in this file and stop. Catalog plus top-up
  (P2) is already close.

---

## 8. Order and parallel lanes

| Lane | Chunks, in order | Waits on | Files it owns |
|---|---|---|---|
| **F** (fixes, Swift) | FIX-A2 ‖ FIX-A8 (in parallel) | nothing: start now | `ICloudPageCache.swift` + test; `AssetSizeIndex.swift` + `StorageEstimateTests.swift` |
| **C** (catalog, Swift) | R12a now → R12c → (R12d ‖ R12e ‖ R12f) → R12g | R12c: FIX-A2 + **lane P landed (R11's Swift part)**; R12d: FIX-A8; R12e: **lane S's R6**; R12g: R12b | new `ICloudCatalog*`, `CatalogTopUp`, `CatalogFeedingFetcher`; then `LibraryBrowser.swift`, `ExportSince.swift`, `ExportRangeSheet.swift`, `StorageEstimator.swift`, `ICloudExportEngine.swift` |
| **P** (bridge, Python) | after R11: R12b | **R9, R10, R8, R11** and the export-throughput plan's bridge chunks | `photo_bridge.py`, `test_bridge.py` |
| **K** (spike) | R13 script now; the owner session after R9 lands (its timing lines help) | the owner present | `Tools/ChangesSpike/` |
| **V** (verify) | R14a now; R14b after **lane S's R1**; R14c after both | R1 | new `SequentialFileReader`, `VerifyCheckpoint`, `QuickVerifier`; `BackupVerifier.swift`, `BackupVerification.swift`, `VerifyBackupSheet.swift` |
| **D** (`._`) | R16a now; R16b (Opus + owner); R16c | R16c: R16a, R16b (a), **R1** | new `AppleDouble*`, `HelperFileCleanup*`; `BackupTools.swift`, `BackupToolSheets.swift` |
| **G** (reorganize) | R17a now → R17b → R17c → R17d → R17e | R17b: R17a, R16a, **R1**; R17c: **lane M's R7**; R17d: R16c (same files) and **R4** (BrowseIndex remap); R17e: the ExportModel holder | new `Reorganize*`, `BackupReorganize`, `ReorganizeSheet`; one function in `ExportManifest.swift` |
| **B** (Browse from iCloud) | R18a → R18b | **lane S's R4** and R12a; it pays off once R12c/R12g have filled the catalog | `BrowseIndex.swift`, `BrowseBackup.swift`, `BrowsePhotoViews.swift` |

**Start now, with no collisions:** FIX-A2, FIX-A8, R12a, R13 (script only), R14a, R16a, R17a. That is up to 7 Haiku
builders at once. Each touches only its own new files or files no other lane holds.

**Sequenced after other lanes land:**
- **P2 is sequenced after R9 and R11** as the owner asked. It works without them (pages are just slower to fill),
  but its numbers are judged with R9's `timing` lines, and R12b must build on R11's `walk()`.
- R12e waits for R6. R18a and R17d wait for R4. R17c waits for R7. R14b, R16c and R17b wait for R1.

**File conflicts to watch inside wave 2:**
- `BackupTools.swift` and `BackupToolSheets.swift`: R16c, then R17d.
- `BrowseIndex.swift`: R4 (lane S), then R18a, then R17d's `remap` (any order after R4, but one at a time).
- `ICloudBridge.swift`: R11 Swift, then R12c, then R12g.
- `AssetSizeIndex.swift`: FIX-A8, then R12d.
- `ICloudPageCache.swift`: FIX-A2, then R12c.

**Recommended order for the owner's drive (measure each with R0 `readbench` and the R9 timing lines):**
1. Lane S (bulk listing).
2. **Reorganize** with "remove helper files" ticked: one pass of about 1–2 h. After that every lookup is cheap.
3. The catalog fills on the next full check.
4. Browse and Quick Verify become seconds.

## 9. Open questions for the owner
1. Paywall for Reorganize and the helper-file cleanup. Recommendation: free (they fix slowness the sandbox causes).
   Quick Check sits inside Verify Backup (paid), as now.
2. If R16b finds `com.apple.provenance` next to the quarantine flag on most files: may it be removed too? It is a
   system tag, not your data.
3. Remove helper files after each export automatically (once R16b passes)? Recommendation: yes. It costs about one
   extra file read per new photo.
