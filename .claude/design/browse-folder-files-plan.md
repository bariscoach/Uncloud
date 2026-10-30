# Browse Backup shows every photo in the backup folder

## Problem

Browse Backup lists only the paths recorded in `.photo-export/exported.tsv` (`BrowseIndexer.mediaPaths(in:)`). Photos
that are in the backup folder but weren't recorded (copied with Finder, exported by another app, an older backup, a
manifest that was lost) never show, so the pane says "Nothing to Browse Yet" over a folder full of photos.

## Change

`BrowseIndexer.update` indexes the union of:
1. the recorded media paths (as today), and
2. every media file found by walking the backup folder.

### Walking the folder (`BrowseIndexer.folderMediaPaths(in:)`, new, `Uncloud/Export/BrowseIndex.swift`)

- `FileManager.default.enumerator(at:includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])`.
  Hidden folders (`.photo-export`, `.Trashes`, `.Spotlight-V100`, `.fseventsd`, `.photo-export/set-aside`) are skipped
  by `.skipsHiddenFiles`; packages (`.photoslibrary`, `.app`, …) by `.skipsPackageDescendants` — also skip the package
  itself. Don't follow symlinks. Errors on a subfolder are ignored (`errorHandler` returns true).
- Keep a file when `ICloudDownloadPaths.hasDownloadExtension` and not `isSidecar`. Paths are relative to the
  destination, same form as manifest paths (forward slashes, no leading slash; use the existing relative-path helper if
  one exists, e.g. in `BackupFiles`, else `String(url.path.dropFirst(base.count + 1))` with standardized paths).
- `Task.checkCancellation()` every 500 entries.
- Runs after `waitWhilePaused()` (so it lists after an export writes), before `BrowseDriveListing.build`.

### Merging

`let paths = mediaPaths(among: recorded ∪ walked)` — the existing `mediaPaths(among:)` already drops sidecars and Live
Photo movies whose photo is present, and sorts. Everything downstream (stamps, metadata reads, iCloud catalog rows,
progress, persist) is unchanged. Entries for files that no longer exist must not be kept (check the current behaviour
and keep it).

### Copy

The empty state stays "Nothing to Browse Yet", but its description becomes "Export some photos, or add photos to your
backup folder, then see where they were taken." (only when the folder has no media at all).

## Tests (`UncloudTests/`, Swift Testing, temp folders only)

- A destination with **no manifest** and photos in `2024/07/` and the root → all indexed.
- Recorded + unrecorded photos together → union, no duplicates.
- Hidden folders (`.photo-export/set-aside/x.jpg`, `.hidden/y.jpg`), a `Library.photoslibrary/` package, `.xmp`
  sidecars and non-media files (`notes.txt`) → not indexed.
- Live Photo pair `IMG_1.HEIC` + `IMG_1.MOV` found by walking → only the photo is listed (same rule as recorded).
- A file deleted after a first index → gone from the second index.
- Use the existing fake metadata reader hooks in the BrowseIndexer tests, so no real image decoding is needed.

## Constraints

Read-only on the drive. Never touch the running app, `~/Library/Containers/com.example.Uncloud`, `/Volumes`, or
Keychain. Tests with the lock script.
