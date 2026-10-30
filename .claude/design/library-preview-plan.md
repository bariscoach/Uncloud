# Full-size preview from the Cloud Library and Delete from iCloud grids

Browse Backup already previews files on the drive: double-click or Space opens Quick Look
(`BrowseQuickLook` in `Uncloud/Views/BrowsePhotoViews.swift`), and its context menu has Open and Show in Finder.
The library grids (`LibraryGrid`, used by Cloud Library and Delete from iCloud) only show thumbnails. This adds a
full-size preview there, for both sources (iCloud and Photos on This Mac).

## What the user sees

- **Double-click a thumbnail** in Cloud Library or Delete from iCloud: the item is selected (same as a single
  click), and a Quick Look panel opens with the full-size photo, or a playable video.
- While it downloads, the tile shows a small `ProgressView()` (controlSize `.small`) centered over the thumbnail.
  If it fails, show nothing new in the grid; log an activity line through the existing model logger if one is easy
  to reach, else just don't open.
- **Context menu** on a tile: "Preview" (same action). Space keeps its current selection behaviour.
- Quick Look's own arrows aren't needed; it shows the one item.

## Getting the full-size file

New on `LibraryBrowserBackend`:
`func previewFile(for item: LibraryItem) async -> URL?` — a local file Quick Look can open, or nil.
`LibraryBrowser.previewFile(for:)` forwards it (like `thumbnail`).

### iCloud (`ICloudBrowserBackend` → `ICloudPageCache`)

- `photo_bridge.py`: in `describe()`, add `"previewURL"` and `"previewType"`:
  - images: the first present of `resJPEGFullRes`, `resJPEGMedRes`, `resOriginalRes` (with its `…FileType` field
    for the extension: `public.jpeg` → `jpg`, `public.heic` → `heic`, `public.png` → `png`, `com.apple.quicktime-movie`
    → `mov`, `public.mpeg-4` → `mp4`, else `jpg` for images / `mov` for movies);
  - movies: the first present of `resVidMedRes`, `resVidSmallRes`, `resOriginalRes`.
  Look in `asset._asset_record` then `asset._master_record`, like `thumb_url`. `compact()` deletes both keys as it
  deletes `thumbURL`. Keep `LISTING_KEYS` as is (the fields are already requested).
- Swift: decode `previewURL`/`previewType` beside `thumbURL` in `ICloudBridge.swift` (optional, so older replies
  still decode), and carry `previewURL: URL?`, `previewExtension: String?` on `ICloudAsset` next to `thumbnailURL`.
- `ICloudPageCache.previewFile(for asset:)`: mirror `thumbnailData(for:)` / `downloadThumbnail`: cache dir
  `…/Previews/` beside the thumbnail directory, file `<sha256(id)>.<ext>`, dedupe concurrent requests per id, retry
  once with a refreshed page on 403/410. Download with the same `thumbnails` loader but to a temporary file and move
  it into place (don't hold big videos in memory if the loader supports a file download; otherwise Data is OK for
  now — note it). Trim the preview folder to 1 GB after each download, oldest first (reuse `trimDiskCache`).

### Photos on This Mac (`PhotoKitBrowserBackend`)

- Images: `PHImageManager.default().requestImageDataAndOrientation(for:options:)` with
  `isNetworkAccessAllowed = true`, `deliveryMode = .highQualityFormat`, `version = .current`; write the data to
  `FileManager.default.temporaryDirectory/UncloudPreviews/<sanitized id>.<ext>` (ext from the data's UTI via
  `options`' result `dataUTI`, default `jpg`).
- Videos: `requestAVAsset(forVideo:options:)` (network allowed); if the result is an `AVURLAsset`, return its URL;
  otherwise return nil.

## Opening Quick Look

Reuse `BrowseQuickLook.shared.show([url], startingAt: 0)`. Move `BrowseQuickLook` to its own file
(`Uncloud/Views/QuickLookPanel.swift`, renamed `QuickLookPanel`) if it's simpler to share; update Browse's uses.

## LibraryGrid changes

- `@State private var loadingPreview: String?` (item id). Double-click (`.onTapGesture(count: 2)` placed **before**
  the single-tap gesture, as Browse does) → select the item as a plain click would, then
  `Task { loadingPreview = id; let url = await browser.previewFile(for: item); loadingPreview = nil; if let url { QuickLookPanel.shared.show([url], startingAt: 0) } }`.
  Ignore a second double-click while one is loading. Placeholder tiles (items not loaded yet) do nothing.
- Overlay `ProgressView().controlSize(.small)` on the tile whose id is loading.
- `.contextMenu { Button("Preview") { … } }` on each tile.
- Accessibility: add `.accessibilityAction(named: "Preview") { … }`.

## Tests (Swift Testing; no network, no real PhotoKit)

- `photo_bridge.py` has Python tests? If there's a test harness for it (grep `UncloudTests` for photo_bridge or a
  `tests/` folder), add cases for `preview_url` choice order and the extension mapping; otherwise make the choice a
  pure function `preview_version(asset)` and test it the way other bridge functions are tested.
- Bridge decoding: a reply with and without `previewURL` decodes.
- `ICloudPageCache.previewFile`: with a fake loader — downloads once, second call hits the cache, concurrent calls
  share one download, 403 then fresh URL retries once, nil when the asset has no previewURL.
- A fake `LibraryBrowserBackend` returning a file URL: `LibraryBrowser.previewFile` forwards it.

## Constraints

Never touch the running app, `~/Library/Containers/com.example.Uncloud`, `/Volumes`, or Keychain. No real iCloud
requests in tests. Version bump is done by the orchestrator, not here.
