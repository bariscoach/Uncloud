# Export Speed — Plan

Branch `feature/duplicates-and-icloud-cleanup` at b055d32 (0.1.11). Owner: "export is still very slow… think out of the box".

## Measured on the owner's setup (2026-10-19)

- Backup drive: 5 TB USB, **exFAT**. Layout **flat** ("All in One Folder"): one folder, ~104,000 photos.
- `ls -f` of that folder: **208,378 entries in 6.4 s**. Half are `._NAME` AppleDouble files.
- Stat-ing every entry (what `DriveInventory .full` does): **> 12 minutes** and still not done when stopped.
- Every photo carries `com.apple.quarantine: 0082;…;Uncloud;`. exFAT can't hold xattrs, so macOS writes a 4 KB
  `._NAME` file per photo. That doubles the entries in the folder, doubles file creations per download, and
  slows every name lookup in a huge exFAT directory (linear scans).
- `ExportModel.startExport` runs a **drive check before every run**, and for the flat layout it's
  `DriveInventory.Mode.full` (quick mode can't help: the one folder always changed). So every Export New Photos
  pays the 10+ minute stat pass before the quick update even starts. Its `forgottenItemIDs` can also make the
  quick update ineligible (`missing` must be empty).
- Also seen: two app copies running at once against the same folder (owner action, not code).

## Part 1 — No drive check before a routine quick update (biggest win)

In `ExportModel.startExport` (the "Check the drive first" block, ~line 800), skip `performDriveCheck` when **all** hold:
- `source == .iCloud`, `selection.isEverything`, `!resumesInterrupted`, `!forcesFullCheck`;
- `ICloudResumePoint.load(in: destination.url)` has the current account hash (`ExportSession.accountHash(appleID:)`)
  and layout, and `lastFullWalkAt` within `ICloudResumeSettings().fullCheckInterval` (0 ≤ age ≤ interval) —
  i.e. the engine is going to try a quick update. Put this predicate in a small pure static function (for example
  `ICloudQuickUpdate.skipsDriveCheck(point:account:layout:now:maxAge:)`) so it is unit-tested.
When skipped: `report = nil` (the engine already falls back to `known.count`), and log one activity line:
"Looking for new photos only. Your backup folder is checked in full about once a month."
(then the engine's own "Looking for new photos only…" note is redundant; drop the engine's note text to avoid two
lines, or keep only one of them).
A full check (Check Whole Library, the monthly one, an interrupted run's resume, Photos on This Mac) keeps the
drive check exactly as today. Backup › Check Backup Folder is unchanged.

Tests: the predicate (fresh / stale / nil point / other account / other layout / future date); and if
`ExportModel` tests can observe whether a drive check ran for an iCloud quick run, add one (skip if there's no
existing seam — don't build a big harness).

## Part 2 — Stop the `._` shadow files (quarantine)

Goal: files Uncloud writes into the backup folder carry no `com.apple.quarantine`, so exFAT/FAT drives get no
`._` companion per photo. Investigate in this order, with a real experiment in the sandboxed test host
(`UncloudTestHost` has the app's entitlements; write a file in a temporary folder and read
`getxattr(path, "com.apple.quarantine")`):

1. **Entitlement** `com.apple.security.files.user-selected.executable` (true) in `Uncloud/Uncloud.entitlements`
   and `Uncloud/Helper.entitlements` (the Python helper inherits the sandbox). Apple's description: files the app
   writes to user-selected locations aren't quarantined. Check whether the test host's own files lose the flag.
   Note: the test host's temp folder isn't "user-selected", so this may not be observable in a test — if so, say so.
2. **Remove the attribute after writing**: in `photo_bridge.py`, after a file is moved to its final name, call
   `os.removexattr(path, "com.apple.quarantine")` inside try/except (OSError ignored). Same for files Swift writes
   into the destination (XMP sidecars, `ResourceWriter` for Photos on This Mac): `removexattr(path, "com.apple.quarantine", 0)`.
   Check in the test host whether a sandboxed process may remove it (write a file, remove the xattr, read it back).
3. If the sandbox forbids both, report that clearly with the evidence; don't invent a workaround.

Implement whichever works (both is fine: the entitlement avoids the write; removal covers anything left).
Add a Python test in `UncloudTests/Bridge/test_bridge.py` that a finished download has no quarantine xattr when
one was set on it (simulate by setting it with `os.setxattr` before the finish step, if the code path allows).

## Part 3 — Later, owner decides (not in this build)

- **Parallel downloads** in the bridge (2–4 at once). Speeds up copying many new photos; risk: Apple throttling.
- **One-time cleanup** of the existing ~104,000 `._` files on the owner's drive (they only hold the quarantine
  flag). Needs the owner's OK; could be a button in Check Backup Folder ("Remove 104,188 hidden helper files").
- **CloudKit change feed** (sync token) instead of scanning: exact "what changed since last time" with no walk.
  Research spike first.
- **Month folders / APFS**: a flat folder of 100k+ files on exFAT will always be slow. Offer "Reorganize into
  month folders" (moves within the drive, no re-download), and/or tell Mac-only users APFS is much faster.

## Result (2026-10-19, 0.1.12)
- Part 1 shipped (dd91c94); resumes also use the quick update when the last full check is recent.
- Part 2: impossible inside the App Sandbox. In the sandboxed test host every file written (Data.write, createFile,
  POSIX open, hard link, the bundled Python child) gets `com.apple.quarantine`; `removexattr`/`setxattr` return
  EPERM even on files without the attribute; `files.user-selected.executable` changed nothing in the temp folder
  (inconclusive for user-selected folders). Only options: leave the sandbox (Developer ID app, not App Store), or
  clean up `._` files afterwards, or a different layout/drive format.
