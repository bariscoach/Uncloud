# Import from Google Photos (via Google Takeout)

## Why Takeout, not the Google Photos API

Since March 31, 2025 Google removed the `photoslibrary.readonly` scopes. The Library API now only lists items the app
itself created, and the Picker API only hands over the items a user ticks in a Google-hosted picker, one session at a
time. Neither can back up a whole library. Google Takeout is the only complete, full-quality export Google offers, and it
needs no Google Cloud project, no OAuth client, no app verification, and nothing leaves the Mac. So Uncloud imports
Takeout downloads (zip files or the folders Finder extracts from them) into the backup folder.

## What the user sees

New sidebar pane **Google Photos** (SF Symbol `square.and.arrow.down.on.square`), second in the list:

Cloud Library ⌘1 · Google Photos ⌘2 · Browse Backup ⌘3 · Delete from iCloud ⌘4 · ─ · Export Settings ⌘5

Pane content (`GoogleImportView`, a `Form`/grouped layout like Export Settings, HIG, no Google logo):

1. **Get your photos from Google** — "Google Takeout makes a copy of your Google Photos library you can download."
   Button **Open Google Takeout** → `https://takeout.google.com/settings/takeout/custom/photos`.
   Help text: "Choose Google Photos, export once, file type .zip. Larger files (50 GB) mean fewer downloads."
2. **Choose the downloaded files** — Button **Choose Takeout Files…** (NSOpenPanel: multiple selection, `.zip`
   files and folders). A list of chosen items (name, size) with a remove (minus) button each. Selection lives for the
   session only (security-scoped URLs from the panel; call `startAccessingSecurityScopedResource` while importing).
3. **Import** — Primary button **Import to Backup**. Under it: "Photos go to <backup folder name>, arranged like the
   rest of your backup." Disabled, with a reason line, when: no backup folder ("Choose a backup folder in Export
   Settings first." + button that selects the Export Settings pane), an export is running ("Wait for the export to
   finish."), or no files chosen.

While running: a progress view "Importing 1,234 of 5,000" + "12 already in your backup", Pause/Resume and Stop.
Scanning phase: indeterminate "Reading your Takeout files…".

Finished: "Imported 4,988 photos and videos. 12 were already in your backup." (+ "3 couldn’t be imported" with a
disclosure listing names and reasons) and a **Show in Browse Backup** button.

Footer, small secondary text: "Uncloud reads these files on your Mac. Nothing is sent to Google or to Uncloud.
Google Photos is a trademark of Google LLC. Uncloud isn’t affiliated with Google."

Copy rules: same voice as the app (plain, short, "photos and videos", curly apostrophes, `formatted()` numbers).

## Architecture

All new code under `Uncloud/Export/Google/` (engine) and `Uncloud/Model/GoogleImportModel.swift`,
`Uncloud/Views/GoogleImportView.swift`. Run `xcodegen generate` after adding files.

### 1. `ZipArchiveReader.swift` (read-only zip, streaming, no subprocess)

The app is sandboxed, so don't shell out to `ditto`/`unzip`. Implement a small reader:

- `final class ZipArchiveReader { init(url: URL) throws; let entries: [ZipEntry]; func extract(_ entry: ZipEntry, to handle: FileHandle, chunk: (Data) -> Void) throws }`
  (the `chunk` callback lets the caller hash while writing).
- `struct ZipEntry: Sendable, Hashable { path: String; compressedSize: UInt64; uncompressedSize: UInt64; crc32: UInt32; method: UInt16; localHeaderOffset: UInt64; isDirectory: Bool; isEncrypted: Bool }`
- Find the End Of Central Directory record by scanning the last 64 KiB + 22 bytes backwards for `0x06054b50`. If any
  field is `0xFFFF`/`0xFFFFFFFF`, read the ZIP64 EOCD locator (`0x07064b50`) and ZIP64 EOCD (`0x06064b50`).
- Parse central directory headers (`0x02014b50`); read ZIP64 extra field (id `0x0001`) for sizes/offset when the
  32-bit fields are `0xFFFFFFFF` (order: uncompressed, compressed, offset — only those that are saturated).
- Names: UTF-8 (flag bit 11, and in practice always — decode as UTF-8, fall back to Latin-1 string).
- To extract: seek to local header (`0x04034b50`), skip 30 + name length + extra length (from the *local* header),
  then stream `compressedSize` bytes. Method 0 = copy; method 8 = raw DEFLATE via `Compression`'s
  `compression_stream` with `COMPRESSION_ZLIB` (it's raw deflate). Anything else, or encrypted (flag bit 0) →
  `ZipError.unsupported(entry.path)`.
- Verify CRC-32 (implement a table-driven CRC-32, polynomial 0xEDB88320) and the uncompressed size → `ZipError.corrupt`.
- Read in 1 MiB chunks; `try Task.checkCancellation()` between chunks. Use `FileHandle` + `seek(toOffset:)`.
- Reject entry paths that are absolute or contain `..` components (never write outside the destination anyway).

Tests `UncloudTests/ZipArchiveReaderTests.swift`: fixtures made with `python3 zipfile` at authoring time and stored as
base64 strings in `UncloudTests/ZipFixtures.swift`: stored entry, deflated entry, UTF-8 name ("Café.jpg"), a
directory entry, a ZIP64 archive (`zipfile.ZipFile(..., allowZip64=True)` and `zf.open(name, "w", force_zip64=True)`),
a corrupted CRC, and an unsupported method. Each test writes the fixture to a temp dir and checks entries + bytes.

### 2. `TakeoutMetadata.swift` + `TakeoutSidecarMatcher.swift`

`struct TakeoutMetadata: Decodable, Sendable, Equatable` — fields from Google's JSON sidecars:
`title: String?`, `description: String?`, `photoTakenTime.timestamp` (a **string** of seconds), `creationTime.timestamp`,
`geoData {latitude, longitude, altitude}`, `geoDataExif {…}`, `favorited: Bool?`, `url: String?`.
Computed: `takenDate: Date?` (photoTakenTime, else creationTime), `coordinate: (lat, lon, alt)?` (geoData unless both
lat and lon are 0, else geoDataExif unless 0/0, else nil). Unknown keys ignored; malformed JSON → nil, never throws up.

`enum TakeoutSidecarMatcher { static func sidecar(for mediaName: String, among jsonNames: Set<String>) -> String? }`
(names only, within one folder). Rules, in order:
1. Split a trailing duplicate counter from the media stem: `IMG_1(1).JPG` → name `IMG_1.JPG`, counter `(1)`.
2. Strip an edited suffix: `IMG_1-edited.JPG` → `IMG_1.JPG` (only the English `-edited`).
3. For each json name: drop `.json`; split off a trailing `(n)` counter; the json counter must equal the media counter.
   The remaining stem matches when it equals `name`, or `name + ".supplemental-metadata"` has it as a prefix and it is
   at least `name.count` long, or (truncation: Google cuts json file names to 51 characters) the full json file name is
   ≥ 46 characters and `name + ".supplemental-metadata"` starts with the stem.
4. Live-photo movie: if nothing matched and the media is a movie (`.mp4`, `.mov`), retry with each image extension
   sibling's name of the same stem (`IMG_1.HEIC`, `IMG_1.JPG`, …) present in the folder (pass the folder's media
   names as a second parameter).
5. Otherwise nil. (The importer has a last fallback: a json in the folder whose `title` equals the media name.)

Tests `UncloudTests/TakeoutMetadataTests.swift`: JSON parsing (string timestamps, 0/0 geo, geoDataExif fallback,
missing fields), and a table for the matcher covering every rule above, including
`"Screenshot_20190101-123456_Some long app name.jpg"` truncated cases and `IMG_1.JPG(1).json` /
`IMG_1.JPG.supplemental-metadata(1).json`.

### 3. `TakeoutSource.swift`

Turns the chosen inputs into a flat list of media items:

```swift
struct TakeoutItem: Sendable {
    enum Origin: Sendable { case file(URL); case zip(archive: URL, entry: ZipEntry) }
    let origin: Origin
    let name: String            // last path component
    let folder: String          // parent folder name inside Takeout, e.g. "Photos from 2019" or "Rome 2024"
    let size: UInt64
    let metadata: TakeoutMetadata?
    var album: String?          // folder name when the folder is an album (see below), else nil
    let sourceKey: String       // "<input file name>|<path inside input>|<size>", for the resume journal
}
```

- Folders: enumerate recursively (skip hidden files and packages). Zips: `ZipArchiveReader.entries`.
  Multi-part Takeout downloads (`takeout-…-001.zip`, `-002.zip`) are just several inputs; sidecars can live in a
  different part than their photo, so **collect json files across all inputs first**, keyed by the folder path inside
  Takeout (e.g. `Takeout/Google Photos/Rome 2024`), then match per folder.
- Media = `ICloudDownloadPaths.hasDownloadExtension(name)` (same rule as the rest of the app). Everything else
  (json, html, `print-subscriptions.json`, …) is skipped silently.
- Album rule: a folder is an album unless its name matches `^Photos from \d{4}$` (or the localized variants we
  can't know — so also treat a folder as an album only when it contains a `metadata.json` sidecar). In practice:
  album = folder has `metadata.json` (album metadata) AND name isn't `Photos from YYYY`.
- Sidecar json is parsed lazily but once (cache by folder+name). Reading json from a zip: extract to `Data` in memory
  (they're tiny; cap at 1 MiB, else ignore).

### 4. `TakeoutImporter.swift` (the engine)

Mirrors `ExportEngine`: `struct TakeoutImporter: Sendable { destination; layout; inputs: [URL]; gate: PauseGate;
func start() -> ExportRun }`, emitting the existing `ExportEvent`s (`prepared`, `exported`, `skipped`, `failed`,
`note`). Steps:

1. Scan inputs → `[TakeoutItem]` (emit `.note("Reading your Takeout files…")` first).
2. Load the import journal `<destination>/<manifest folder>/google-imported.tsv` (one `sourceKey<TAB>sha256` per
   line, append-only, same folder as the other manifest files; add a small helper on `ExportManifest` for its URL).
   Items whose `sourceKey` is in it are already done. Emit `.prepared(total: items.count, alreadyExported: done)`.
3. For each remaining item (await `gate.waitWhilePaused()`, `Task.checkCancellation()`):
   a. Copy into a staging file `<manifest folder>/google-staging/<UUID>` on the destination while hashing with
      `StreamingHasher` (file input: read 1 MiB chunks; zip input: `extract(…, chunk:)`).
   b. Key = `"google:" + sha256`. If the manifest already contains that key, or `ExportManifest.checksums(in:)`
      already has a file with this sha256 (the same photo exported from iCloud/Photos earlier) → delete staging,
      append to the journal, emit `.skipped`. (Load the checksum set once at start; add new ones as you go.)
   c. Folder: date = `metadata.takenDate` ?? file EXIF/creation date (`BrowseMetadata` reader) ?? the zip entry/file
      modification date. Coordinates from metadata. Reuse `ExportEngine.folderPath(for:monthKey:place:)` (it's
      already static) and `PlaceResolver` for place layouts, and `AlbumIndex.notInAlbumFolder` for the album layout
      (album items go into `item.album`, sanitized like other album folder names; others into notInAlbumFolder).
   d. Move staging → `FileManager.default.availableURL(in: folder, for: name)` (same volume, a rename).
      Set the file's creation and modification dates to the taken date when known.
   e. Sidecar: when metadata has a date or location, write `<name>.xmp` beside it with `XMPSidecar.xml(for:)` using
      `AssetMetadata`'s memberwise init (date, location, favorite, description/title, album). Browse Backup reads
      dates/places from the .xmp when the file has none — Google often strips EXIF — so this is written regardless of
      the "write sidecars" setting.
   f. `manifest.recordChecksums([mediaPath: sha])`, `manifest.recordExport(of: key, files: [mediaPath, xmpPath?])`,
      append journal line, emit `.exported(name:, fileCount:, bytes:)`.
   g. Errors: same mapping as `ExportEngine` (cancel → rethrow; out of space → `ExportError.destinationFull`;
      destination gone → `.destinationUnavailable`; `ZipError` or read error → `.failed(name, reason)` and continue).
      Always remove the staging file on failure. On start, delete leftover `google-staging` contents.
4. Don't call `markRunFinished()` (that's the iCloud/Photos run marker) — the importer has its own journal.

### 5. Manifest consumers must ignore `google:` records

Audit every reader of manifest records/ids and make Google records neutral where they would be miscounted:
`ICloudItemCount.count` / `itemsByLayout` (ExportModel 1738, 2282, 2307), `PhotoLibrary` exported ids,
`ExportRangeSheet`, `FlatFolderCheck`, `DriveCheck` (Google files are recorded files — fine to check for missing
files), `ReorganizePlanner` (a layout change must **leave Google files where they are**, not move them to
"unknown"; skip `google:` records and say nothing), `ICloudCleanup` ("backed up" must not count Google photos as
iCloud photos). `BrowseIndex.mediaPaths` *should* include them (that's how they show in Browse Backup). Add a
`static let googleKeyPrefix = "google:"` on `ExportManifest` and use it everywhere. Unit-test the counts with a
manifest containing google records.

### 6. `GoogleImportModel` (`@Observable @MainActor final class`)

Owned by `ExportModel` (property `googleImport`), so it can read `destination`, `layout`, `isExporting`, and so
`ExportModel` can refuse to start an export while an import runs (`isImportingFromGoogle` — both write the manifest).
State: `inputs: [URL]`, `phase: idle | scanning | importing | paused | finished(Summary) | failed(String)`,
counts `total`, `done`, `skipped`, `failures: [(name, reason)]`. Methods `addInputs()` (shows NSOpenPanel),
`remove(_:)`, `start()`, `pause()`, `resume()`, `stop()`. Holds security-scoped access on inputs and destination for
the run's duration. On finish call `onFinished` (wired in `BackupTools` like `onRunFinished`, to `browse.refresh()`).
Inject a `startRun` closure for tests (like other models do) so tests don't touch real files outside temp dirs.

### 7. Sidebar and menus

- `ExportModel.Pane`: add `case google` between `export` and `browse`; title "Google Photos", symbol above,
  shortcuts renumbered 1–5. `SidebarPaneRows` row like the others. The sidebar must still fit without scrolling at
  the minimum window height — check the min height in `MainWindow` and raise it by one row if needed.
- `MainWindow` detail switch: `.google` → `GoogleImportView()`.
- File menu (ExportCommands): "Import from Google Photos…" selects the pane (no shortcut).
- Update snapshot/content tests that enumerate panes.

### 8. Copy elsewhere

- `server/uncloud-api/public/terms.html` §2 list: add "import photos and videos from a Google Takeout download".
  §1 add: "Uncloud is also not affiliated with Google LLC. Google Photos and Google Takeout are trademarks of Google
  LLC." Privacy: under "stays on your Mac" add Google Takeout files ("Uncloud reads them on your Mac; nothing is sent
  to Google or to us"). Update `server/uncloud-api/test/pages.test.js` if it pins copy. Run `npm test` there.
- Site: not in this change.

### 9. Version

`project.yml` MARKETING_VERSION 0.1.25, CURRENT_PROJECT_VERSION 26; `xcodegen generate`.

## Build order (Haiku agents, worktrees)

- **A** (parallel): §1 ZipArchiveReader + fixtures + tests.
- **B** (parallel): §2 TakeoutMetadata + matcher + tests.
- **C** (after A+B merged): §3, §4, §5 + tests (importer end-to-end on temp folders: a folder input and a zip input
  with an album, a `Photos from 2019` folder, a duplicate in both, a truncated sidecar, a live photo pair, a photo
  already exported (same sha in checksums) → skipped, resume via journal, place layout off).
- **D** (after C): §6, §7, §8, §9 + tests.
- Opus reviews each merge; full test run; then `scripts/make-dmg.sh --account-mode live`.

Constraints for every agent: never touch the running app, `~/Library/Containers/com.example.Uncloud`, `/Volumes`,
or Keychain; tests only use temp directories; run tests with the lock script.
