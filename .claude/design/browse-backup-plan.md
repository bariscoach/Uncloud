# Browse Backup: map and places from exported photos

A new sidebar section, **Browse Backup** (symbol `map`), that shows the photos **on the destination drive**, by where
they were taken. It reads only the drive, with no iCloud and no bridge. Reverse geocoding is the only network use,
and its results are cached.

This will later be a paid feature, so keep it self-contained: one model, a few views, and one entry in the sidebar
enum. A future paywall can then gate it in one place.

## Data

### 1. File list
- Take the files from the manifest (`ExportManifest.records(in:)`): every recorded media path, without `.xmp`
  sidecars, and without Live Photo movies whose photo is also recorded (`DriveCheck`'s grouping helpers already know
  that pairing; reuse them).
- Skip paths that don't exist anymore.
- Untracked files are out of scope.

### 2. Location per item
Read it in this order:
- **Embedded metadata.** Use `CGImageSourceCopyPropertiesAtIndex` (`kCGImagePropertyGPSDictionary`: Latitude,
  LatitudeRef, Longitude, LongitudeRef) for HEIC, JPEG, PNG and RAW. For movies, use AVFoundation
  (`AVURLAsset` `.commonMetadata` / `quickTimeMetadataLocationISO6709`, async `load(.metadata)`) and parse the
  ISO 6709 string.
- **Fallback:** the `.xmp` sidecar next to the file (`exif:GPSLatitude` / `exif:GPSLongitude` in the
  "DD,MM.mmN" form that `XMPSidecar.swift` writes). Parse it with `XMLParser`. Reuse or mirror `XMPSidecar`'s
  formatting, so reading and writing stay consistent.
- Also read the **date taken** (EXIF DateTimeOriginal, or the movie's creation date), and the camera make and model
  where cheap.

### 3. Index cache
- Keep it per destination, in Application Support/Uncloud/BrowseIndex/<destination key>.json (or a binary plist).
  Reuse the destination key that NewPhotosStore uses.
- Each entry: path, size, mtime, latitude, longitude, date, camera.
- Re-read only files whose size or mtime changed.
- **Never write to the drive.**
- Index in the background with `Task.detached` at utility priority, with progress ("Reading locations… 12,340 of
  48,312"), cancellable, and paused while an export runs. Persist partial progress every 1,000 files, so a large
  drive resumes.

### 4. Places
- Group by `PlaceResolver` (`Uncloud/Export/PlaceResolver.swift`): it already turns coordinates into a country and
  city with ~10 km cells and a disk cache.
- Resolve lazily, only the cells that are shown or listed. Respect its rate limiting.
- Offline, show coordinates or "Unknown place" and retry later.

## UI (follow .claude/agents/designer.md and .claude/design/ui-refresh-plan.md tokens)

**Toolbar:** a segmented control, **Map | Places**, and a search field that filters places by name.
The window title is "Browse Backup", with the destination name as the subtitle.

**Map**
- Use an `MKMapView` through `NSViewRepresentable`, for native **clustering** (`clusteringIdentifier`). SwiftUI
  `Map` on macOS 14 has no clustering.
- Annotations show a count badge. Clicking a cluster or pin opens a side **inspector panel** with a thumbnail grid
  of those photos, using the place name as the title.
- The map fits all located photos initially.

**Places list**
- A sidebar-style list of Country › City with counts, sorted by count. Selecting one shows its thumbnail grid.
- Include "No Location (N)" for photos without GPS.

**Thumbnail grid and details**
- Thumbnails come from `QLThumbnailGenerator`, loaded lazily, with an LRU memory cache.
- Double-click or Space opens Quick Look (`QLPreviewPanel`).
- The context menu has Open, Show in Finder and Copy Location.
- Selecting a photo shows a small **detail** pane with:
  - the place name
  - coordinates
  - date taken
  - camera
  - file name and folder
  - size

**States**
- No destination: "Choose a backup folder to browse it."
- Drive not connected: "Connect <drive> to browse your backup."
- Indexing: progress, while what's already indexed stays browsable.
- Nothing located: an explanatory empty state.

**Navigation:** add View › Browse Backup (⌘4) and the sidebar row. Don't change the other panes.

## Rules
- Read-only on the drive.
- No changes to export, deletion or manifest logic.
- Use `PlaceResolver` without changing its folder behaviour. Adding read-only lookup helpers is fine.
- Swift 6 concurrency; macOS 14+ with no `#available` gating required.

## Tests
Use temp folders with generated fixture images written via CGImageDestination, with GPS dictionaries:
- GPS read from JPEG and HEIC (if HEIC encoding is available, otherwise PNG with GPS)
- N/S/E/W signs
- a movie's ISO 6709 parsing (a pure string parser test)
- XMP fallback parsing, round-tripped with `XMPSidecar`'s writer
- Live Photo movie and sidecar exclusion
- the incremental index: an unchanged file isn't re-read, and a changed mtime is
- missing files skipped
- place grouping with a fake resolver
- the "No Location" bucket
- search filtering

Gated snapshots of Map (with fake annotations if the map can't render in the harness, note it), Places, details and
the empty states, in light and dark mode, into scratchpad/browse-snapshots/.

The full suite must pass, run alone.
