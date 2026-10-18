# New Photos: make incremental export visible, and remind the user

The engine already exports incrementally:
- the manifest skips items already exported
- the iCloud resume point plus the closing walk find new items quickly
- the drive check re-downloads files missing from the drive

Automatic export (daily, or when the drive connects) exists in AutoBackupSettings and AutoBackupController.
This feature makes that **visible and obvious**, and adds a **reminder notification**.

User decisions:
1. Show "N new photos since your last export on <date>" and an **Export New Photos** button.
2. Photos missing from the destination, including ones the user deleted from the drive, are copied again (the current
   behaviour). "New" in the UI means new in the library since the last export. The run itself still fills any gaps.
3. New photos go into the user's chosen layout folders, as today. No separate "new" folder.
4. Add a notification when there are new photos and the drive isn't connected.

## 1. Knowing what's new: the watermark

At the end of every **complete** export (all selected items processed, not cancelled) of an `.everything` selection,
save a per-destination, per-source, per-account **watermark** in the app's Application Support (not on the drive, so
it can be read while the drive is disconnected). It holds:
- the last complete export date
- the library count at that time
- for iCloud: the newest item's asset ID and its **added date** (the iCloud "All Photos" order is newest-added first;
  check what `describe()` / the asset record exposes, such as `addedDate` or `asset.added_date`, and add it to the
  page items if needed)
- for the Photos library: the exported localIdentifier set, stored as a compact file. PhotoKit has no public added
  date, and set difference with `BackupFiles.allLibraryIDs()` is exact and cheap.

Key it the way sessions identify destinations (look at SessionStore and ExportSession for an existing destination
identity, such as the volume UUID plus path). Use a small Codable store, `Uncloud/Model/NewPhotosStore.swift`.

**Counting new items:**
- iCloud: page from rank 0, using the existing bridge `page`, and count the items whose added date is newer than the
  watermark. Stop at the first page that reaches the watermark. Use the existing ICloudPageCache where possible.
  - Cap it at a sensible maximum walk (e.g. 5,000 items). Beyond that, show "5,000+ new photos".
  - If added dates aren't available, fall back to the newest asset ID: count the items above it.
- Photos library: library IDs minus the stored set.

The result is `NewPhotosStatus { count: Int, isAtLeast: Bool, since: Date }`, or nil when no complete export exists yet.

Refresh it:
- at launch, once the source is ready
- after any export finishes
- when the library browser reloads (new photos, Clean Up iCloud deletions)
- every 6 h while the app runs

Don't run it while an export or a cleanup is running, and keep it cheap and cancellable.

## 2. UI (follow .claude/agents/designer.md)

When a watermark exists and nothing is running:
- **Backup pane / ProgressCard idle status:**
  - "**1,243 new photos** since your last export on 17 Sep." (relative wording for recent dates: "yesterday", "3 days ago")
  - With zero new: "Up to date. Last export 17 Sep."
- **The primary button**, in the Library toolbar, Backup pane and Export menu, when the selection is everything:
  **"Export New Photos"**, instead of "Export All Photos". With 0 new it's still enabled: it checks the drive and
  fills gaps. A menu and toolbar subtitle or help text says it skips photos already on the drive.
- **The sidebar:** a small count badge on the Backup item while new photos exist.
- Precedence: when an interrupted run exists, **Resume Export** wins (another agent is building it in a parallel
  branch; keep your title logic in one function, so the merge is simple). Paused shows "Resume". No folder shows
  "Choose Folder…".

## 3. Notification

- A new setting in Settings › Automatic Backup: **"Remind me about new photos"** (on by default once notifications
  are allowed), with a frequency of **Weekly** (default) or **Daily**.
- The check runs on the existing `NSBackgroundActivityScheduler` path in AutoBackupController. It only runs while the
  app is running; the app already stays running when automatic backup or the menu bar is on. Say so in the setting's
  footnote.
- When the count is at least 1, the **destination isn't connected** (when it is connected and automatic backup is on,
  just back up; when it's connected with automatic backup off, notify too), and the last reminder is older than the
  frequency, post:
  - Title: "New photos to back up"
  - Body: "1,243 new photos since your last export. Connect your backup drive to save them." (use the right wording
    when connected)
  - Clicking it opens the app on the Backup pane. Use UNUserNotificationCenter, as the existing notifications do.
- Never prompt for sign-in or 2FA from a background check. If the iCloud session needs sign-in, skip silently and log it.
- The diagnostic log gets counts only.

## 4. Tests

- The watermark is saved only after complete `.everything` runs, not after cancelled or partial ones.
- Counting for iCloud with the fake bridge: stops at the watermark, the cap gives isAtLeast, and the fallback to the newest ID.
- Counting for the Photos library uses set difference.
- Primary title precedence: paused, then no folder, then new photos, then the default.
- The notification decision function is pure and testable: frequency, drive connected or not, auto backup on or off,
  zero new, and a sign-in-needed skip.
- Status text formatting.

The full suite must pass: xcodebuild test and scripts/test-bridge.sh.
