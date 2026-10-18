# Clean Up iCloud: bulk delete from iCloud Photos

A separate feature from exporting. The user browses iCloud thumbnails, selects (or Select All / Deselect All),
and Uncloud deletes the selection in batches automatically. This replaces iCloud.com's manual 1,000-at-a-time limit.

The user decided: **any item can be deleted, with no backup requirement** (option 3). The backup state is shown only
as information. Deleting moves items to iCloud's **Recently Deleted** album (`isDeleted = 1`, the same mechanism as
icloudpd's `delete_photo`), where they can be recovered for 30 days. Nothing is ever deleted without the
typed confirmation below.

## Bridge (Uncloud/Helper/photo_bridge.py)

Add a new command, `delete`:
`{"cmd":"delete","id":N,"mode":"only"|"allExcept","ids":[assetID…],"hints":{assetID:rank},"batchSize":100}`.

Like `download`, it is deferred while another long request runs (`handle(..., downloading=True)` appends it to
`_deferred`). It also answers `ping`, `pause`, `resume` and `cancel` the way downloads do (`Channel.is_paused` /
`is_cancelled`, `serve_waiting` between batches).

**Phase 1, resolve the targets.**
- `only`: reuse `_hinted` windows, then `walk` for the rest.
- `allExcept`: `walk(self.library.all)` and collect every asset not in `ids`.

Keep the asset objects, because the batches need `_asset_record["recordName"]` and `["recordChangeTag"]`.
- Emit `{"event":"deleteProgress","phase":"finding","done":n,"total":t}` every page.
- When done, emit `{"event":"deleteTargets","ids":[…]}` with the resolved IDs, so the app can resume an
  `allExcept` run as `only`.
- IDs not found count as `missing`: already deleted, or no longer in the library.

Never delete while walking. The offsets would shift and items would be skipped.

**Phase 2, delete in batches** of `batchSize` (default 100, max 200).
- Each batch sends one `POST {library.service_endpoint}/records/modify?{params}`. The body has `atomic: false`,
  `zoneID: library.zone_id`, `desiredKeys: ["isDeleted"]`, and one `update` operation per asset (recordType
  `CPLAsset`, recordName, recordChangeTag, `fields.isDeleted.value = 1`).
- **Check the response.** A non-2xx HTTP status fails the batch. In the JSON `records` array, an entry with
  `serverErrorCode` means that asset failed (send its `reason`). Otherwise the asset was deleted. An asset missing
  from the response counts as failed with "no response".
- Emit `{"event":"deleted","ids":[…]}` and `{"event":"deleteFailed","items":[{"id":…,"reason":…}]}` for each batch,
  plus `deleteProgress` with `phase: "deleting"`.
- Before each batch, honour pause and cancel. Pace about 1 s between batches.
- Throttle and connection errors (`is_run_ending`: 503, 429, connection) end the run with
  `{"event":"deleteDone", …, "stopped":"throttled"}` and the error message. The app retries.
- Finally emit `{"event":"deleteDone","deleted":n,"failed":n,"missing":n,"cancelled":bool,"stopped":null|"throttled"|"error","message":…}`.
- After any deletion, drop the cached library and album state so `count` and `page` reflect the deletions. Check
  how pyicloud caches `library.all` and its `len`, then re-fetch or reset that state.

Tests go in `UncloudTests/Bridge/test_bridge.py`, with the fake library and session:
- batching (250 items at size 100 make 3 posts)
- the request body shape
- partial failures through `serverErrorCode`
- an HTTP error on a batch
- cancel between batches
- pause and resume
- a throttle stopping the run
- `allExcept` resolution with exclusions
- missing IDs
- no posts at all when the target set is empty
- deferral while a download runs

Also extend `UncloudTests/Bridge/test_fake_bridge.py` and the fake bridge the Swift tests use, so it supports `delete`.

## Swift

**`ICloudBridge`.** Add `delete(_ options: ICloudBridgeDeleteOptions) -> ICloudBridgeDeletion`, mirroring `download`:
an event stream plus pause, resume and cancel by request ID. Add `ICloudBridgeDeleteEvent` cases: `finding(done,total)`,
`targets([String])`, `deleted([String])`, `failed([(id, reason)])`, `progress(done,total)`, and
`done(deleted, failed, missing, cancelled, stopped, message)`.

**Model `Uncloud/Model/ICloudCleanup.swift`** (`@MainActor @Observable`).
- It has its **own** `LibrarySelection`, never the export selection.
- States: idle, confirming, finding, deleting(done,total,paused), waitingAfterThrottle(until,attempt), finished(summary), failed(message).
- The remaining IDs are tracked from `targets` and `deleted`.
- After a throttle, retry automatically with backoff (1, 2, 5, 10, 15 min; at most 8 attempts) as an `only` delete of
  the remaining IDs. Show a countdown with "Try Now".
- Prevent idle sleep while running (`ProcessInfo.beginActivity`, as exports do).
- Exports and cleanup exclude each other: no delete while `model.isExporting || model.isEngineRunning`, and exports are
  blocked while cleanup runs (extend `model.isExportBlocked` the way `BackupTools` does).
- When it finishes or is cancelled after any deletion:
  - invalidate `ICloudPageCache` and any count or size caches (StorageEstimator / AssetSizeIndex if they key on the library)
  - reload the library browser
  - remove the deleted IDs from the export selection
- Log counts only (no names) with os.Logger, category "cleanup".
- **Never touch the destination drive or the export manifest.** The backed-up files stay; this feature only changes iCloud.

**UI** (follow .claude/agents/designer.md and the HIG):
- **Sidebar:** add a third item, **"Clean Up iCloud"** (symbol `trash` or `icloud.slash`). It's available only when
  the source is iCloud and the user is signed in. Otherwise show an explanatory empty state.
- **The grid:** reuse the iCloud thumbnail grid from `LibraryView` (extract or parameterise it; don't duplicate it)
  with the cleanup selection. Each thumbnail has a small badge when the item is backed up on the current destination
  (from `ExportManifest` `icloud-id:` records). It's information only.
- **The toolbar:**
  - Select All, Deselect All, and "N selected · X GB" (sizes where known).
  - A filter menu: All / Backed Up / Not Backed Up.
  - A destructive, red primary button: **"Delete N from iCloud…"**.
- **The confirmation sheet:**
  - Title: "Delete N items from iCloud?"
  - Body: the items move to Recently Deleted on all your devices and can be recovered there for 30 days. If any
    selected items aren't backed up, add the warning "N of them aren't backed up to your drive."
  - The user must **type the number N** to enable the destructive "Delete N Items" button. Cancel is the default.
- **Progress:** a card like the export ProgressCard, with phases "Finding items… n of t" and "Deleting… n of t".
  It has Pause/Resume and Cancel, and shows the throttle countdown.
- **Finished:** "Deleted N items from iCloud. They're in Recently Deleted for 30 days." Add the failed and missing
  counts, and a "Show Details" list of failures with their reasons.

## Safety rules (non-negotiable)

- Tests use only the fake bridge and fake sessions. Nothing in the test suite or the agent's work may contact
  iCloud or run the real app against a real account.
- No deletion starts without the typed confirmation. It never auto-starts, at launch or on resume.
  Throttle retries continue a run the user already confirmed, and only until it finishes or is cancelled.
- Cancel stops before the next batch. A batch already sent can't be recalled; say so in the UI.
- Deleted IDs are never re-sent. Failed IDs are retried only by the automatic throttle retry, or when the user runs
  Clean Up again.

## Tests (Swift)

- The `ICloudCleanup` state machine with the fake bridge: the confirm → finding → deleting → finished flow.
- Pause and resume.
- Cancel.
- A throttle, then a backoff retry with only the remaining IDs.
- Partial failures in the summary.
- Its selection is independent of the export selection.
- Caches invalidated after a deletion.
- Exports blocked while running.
- Confirmation enabled only when the typed number matches.

The full suite must pass (`xcodebuild test -scheme Uncloud -destination 'platform=macOS'`, plus `scripts/test-bridge.sh`).
