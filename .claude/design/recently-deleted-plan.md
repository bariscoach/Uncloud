# Clean Up iCloud: Recently Deleted and Recover

This extends Clean Up iCloud (.claude/design/icloud-cleanup-plan.md). The user can browse iCloud's **Recently Deleted**
album inside Uncloud and recover items from it, in bulk with no 1,000 limit, like deleting.

The scope is recovery only. There is **no "Delete Permanently"** (it's irreversible; out of scope unless the user asks).

## How it works in iCloud

pyicloud_ipd already defines the album: `PhotoLibrary.RECENTLY_DELETED`, obj_type `CPLAssetDeletedByExpungedDate`,
list_type `CPLAssetAndMasterDeletedByExpungedDate`, reachable as `library.albums["Recently Deleted"]`.

Recovering is the reverse of our delete: a CloudKit `records/modify` `update` setting `fields.isDeleted.value = 0`
on the `CPLAsset` record, with its current `recordChangeTag`. Like the delete response format, this is an assumption
until it's checked on a real account. Keep the code in one place, so it is easy to adjust after the user's live test.

## Bridge (photo_bridge.py)

- `page` and `count` take an optional `"album": "recentlyDeleted"`. If it's missing, the album is the library, as
  today. They use `self.albums()["Recently Deleted"]`, or construct it the way pyicloud does.
- `describe()` items from that album may carry the days left if the record has an expunge or deleted date. Investigate
  the record fields in pyicloud's asset (`_asset_record`, `_master_record`). If the fields aren't reliably available,
  leave it out. Don't guess.
- A new `restore` command shares the delete machinery. Generalise `delete` into a helper parameterised by:
  - the source album: library for delete, Recently Deleted for restore
  - the `isDeleted` value: 1 or 0
  - the event names: reuse `deleteProgress`/`deleteTargets`/`deleted`/`deleteFailed`/`deleteDone` with an
    `"action": "delete"|"restore"` field, or add parallel `restore*` events. Pick the cleaner one for the Swift
    decoder and document it.

  The same rules apply as for delete:
  - resolve the targets first, then batch them
  - `confirmedCount` guard (stops as `"changed"`)
  - throttle stop and the 3-consecutive-failures stop
  - pause, cancel and pacing

  For restore, `allExcept` walks the Recently Deleted album.
- Python tests mirror the delete tests that matter:
  - the body has `isDeleted: 0`
  - restore walks Recently Deleted, not the library
  - the confirmedCount guard
  - throttle
  - partial failures
  - `page`/`count` with `album: recentlyDeleted`
  - an unknown album value is rejected

  Extend fake_bridge.py so it keeps a recently-deleted list: delete moves items into it, restore moves them back.

## Swift

- `ICloudBridge`: `page(offset:limit:album:)`, `count(album:)`, `restore(_ options:)` (or one `modify` with an action).
  `ICloudPageCache` and `LibraryBrowser` must keep the two albums' pages separate. Either key the cache by album,
  or use a second browser instance for Recently Deleted.
- `ICloudCleanup` gains a **mode**, Library or Recently Deleted, each with its **own selection**.
  - The restore flow uses the same state machine and retries.
  - Its confirmation is a simple alert, "Recover N items?" with "They'll return to your library on all your
    devices", and **no typed number**, because recovering isn't destructive.
  - It still sends `confirmedCount` = N.
  - After a delete or a restore, reload **both** albums' browsers and counts, and the export-side library browser
    and size caches (as delete already does).
- Exports stay blocked while either action runs, and a delete and a restore can't run at the same time.

## UI (follow .claude/agents/designer.md)

- Top of the Clean Up iCloud pane: a segmented control, **Library | Recently Deleted (N)**.
- The Recently Deleted grid uses the same grid component, with Select All and Deselect All, and "N selected". The
  backed-up badge still applies.
  - If days left is available, show a small "12 days" caption on each tile.
  - The banner reads: "Items are permanently removed by iCloud after 30 days."
- Its primary button is **"Recover N Items"**, prominent and not destructive. The progress card says
  "Recovering… n of t". The finish message is "Recovered N items. They're back in your library."
- The empty state reads: "Recently Deleted is empty."
- After a delete finishes, the summary gets a **"View Recently Deleted"** button that switches the segment.

## Tests (Swift)

- Separate selections per mode.
- Restore flow: confirm (no typing), progress, finish.
- Restore sends confirmedCount.
- After a restore, both browsers reload.
- Delete and restore exclude each other.
- The throttle retry works for restore.
- The page cache keeps the albums separate.

Gated snapshots of the Recently Deleted grid, the recover alert and the finished state, in light and dark mode,
written to scratchpad/recently-deleted-snapshots/.

The full suite must pass: xcodebuild test and scripts/test-bridge.sh.
