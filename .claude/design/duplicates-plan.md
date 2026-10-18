# Find Duplicates — Level 1 (exact duplicates)

Goal: find items on the destination drive whose files are byte-for-byte identical to another item's, show them,
and let the user move the extra copies to the Trash. Works for both sources (iCloud and the Photos library).
Only the drive changes; the photo library and iCloud are never touched.

## Definitions

- **Item** = one manifest record from `ExportManifest.records(in:)`:
  - `icloud-id:<asset>` records (iCloud), and
  - unprefixed Photos library records (`localIdentifier`).

  Excluded and counted as "not checked":
  - `icloud:` path-only records
  - `icloud-partial:` records
  - any item where a media file has no recorded checksum in `checksums.tsv`
- **Media files** of an item = its paths minus `.xmp` sidecars.
- **Fingerprint** of an item = the sorted list of the SHA-256s of its media files, from `checksums.tsv`. Nothing is re-read to build it.
- **Duplicate group** = two or more items with the same fingerprint and in the same folder.
  - The folder is the parent folder of the item's first media path, for both iCloud and Photos library items. The flat layout's folder is the top of the destination.
  - Items in different album folders never group, even with identical bytes: the same photo in two albums is in both on purpose, and removing one would take it out of an album. A true duplicate import lands in the same month or flat folder, so this also keeps layouts apart.
  - Matching whole items (not single files) means:
    - A Live Photo only matches another Live Photo with the same photo **and** movie.
    - A plain photo never matches the still half of a Live Photo.
    - An original never matches its edited version.
    - An album-layout item copied into several album folders is one record, so it is never its own duplicate.
  - Items that share a path with another item, such as a record already re-pointed by an earlier run, are the same files, not duplicates. Skip them, so a group only counts copies that occupy separate files.

## Keeper choice (the user can change it per group)

1. Fewest "copy" markers in the file names: ` (1)`, `-1`, ` copy`, and an icloudpd size suffix like `IMG_0001-123456.JPG`.
2. Then the shortest path.
3. Then the earliest line in `exported.tsv`.

## Removing duplicates (only after confirmation)

For each duplicate item D in a group with keeper K:

1. Check that D's and K's media files exist. Re-hash them and require that they still match the recorded checksums, so nothing stale gets deleted. If anything fails, skip D and count it as "skipped".
   K is checked once per group, not once per duplicate. If K fails, every copy in its group is skipped.
2. Move all of D's files, sidecars included, to the Trash with `FileManager.trashItem`. Only paths inside the destination are allowed (`ExportManifest.isSafeRelativePath`, plus the containment check used by `setAside`). If trashing fails, the file stays where it is and is reported; the files already moved stay moved.
3. Re-point D's record at K's paths by appending a new line with `ExportManifest.appendRecords`: `icloud-id:D<TAB>K's paths` or `localID<TAB>K's paths`. A later line wins in `records(in:)`, so:
   - the next export still counts D as exported and doesn't download it again;
   - Verify Backup verifies D against K's identical files;
   - the drive check sees D's paths present.

   Only re-point when every file of D was trashed. If some failed, append nothing for D and report it.
4. Never run while an export or engine is running. While scanning or removing, block exports the way `BackupTools` already does (`model.isExportBlocked`).
5. Log one line per run in the diagnostic log, giving counts only and no file names.

## UI (follow the designer principles in .claude/agents/designer.md and the HIG)

- A new **"Find Duplicates…"** row in `BackupToolButtons`, for both sources. Its caption: "Finds items saved more than once in your folder, so you can move the extra copies to the Trash."
- A matching Export-menu command next to Verify Backup. Use a `BackupTools.Sheet.duplicates` case and `canOpen` rules like Verify.
- A `FindDuplicatesSheet` with these states:
  - **ready**: an explanation and a "Find Duplicates" button.
  - **scanning**: a progress bar (manifest plus stat; it should be quick).
  - **noneFound**: "No duplicates found", plus "N items couldn't be checked because they were saved by an older version" when N > 0.
  - **found**:
    - A summary: "**1,240 duplicate copies** using **18.2 GB**", using ByteCountFormatter on the duplicates' file sizes.
    - A scrollable list of groups. Each row shows a small thumbnail (`QLThumbnailGenerator`, loaded lazily) and each copy's file name, folder and size.
    - The keeper is marked "Keep" and the others "Move to Trash". A control lets the user pick a different keeper, and a checkbox includes or excludes the whole group.
    - A "Show in Finder" context menu.
    - The primary button "Move N Copies to Trash…" opens a confirmation. Its message: "Uncloud will move N copies (X GB) from “<folder>” to the Trash. One copy of each is kept. Your photo library isn't changed. Empty the Trash to free the space."
  - **removing**: progress.
  - **done**: "Moved N copies (X GB) to the Trash." If any were skipped or failed, add "N copies were left in place because they changed or couldn't be moved." Offer "Open Trash" if that's simple; otherwise just explain it.
  - **failed**: an error message.
- Width about 560. The sheet can't be dismissed while removing. Cancel stops a scan.

## Code layout

- Logic goes in `Uncloud/Export/DuplicateFinder.swift`. Keep it pure and testable:
  - `findGroups(records:checksums:sizes:)` returns groups plus a not-checked count.
  - `keeper` ranking.
  - `remove(groups:in destination:hasher:trasher:progress:)`, with the hasher and trasher injectable for tests.
- The state machine goes in `Uncloud/Model/DuplicateCleanup.swift` (`@MainActor @Observable`), modelled on `BackupVerification`.
- The view goes in `Uncloud/Views/FindDuplicatesSheet.swift`.
- Run `xcodegen generate` after adding files.

## Tests (UncloudTests/DuplicateFinderTests.swift)

Grouping:
- Identical photos become one group.
- Different checksums don't.
- A Live Photo vs a plain photo with the same still: no group.
- A Live Photo vs a Live Photo: a group.
- XMP files are ignored for matching.
- Missing checksums are not grouped and are counted.
- Path-only and partial records are excluded.
- Different layouts are not grouped.
- Records sharing paths are not grouped.

Keeper ranking cases.

Removal (in a temp folder):
- Files are trashed.
- The record is re-pointed: `records(in:)` returns K's paths for D.
- `BackupVerifier` then reports D as verified.
- `DriveCheck.count` still counts D.
- A changed file (hash mismatch) is skipped and its record left unchanged.
- A trash failure on one file means no re-point.
- Unsafe paths are rejected.

The full suite must pass: `xcodebuild test -scheme Uncloud -destination 'platform=macOS'`, as the project already runs it.
