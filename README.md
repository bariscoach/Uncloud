# Photo Export

A macOS 14+ SwiftUI app that copies your whole photo library, including originals, edits, RAW pairs and Live Photo videos, into a folder or external drive you choose. Items stored only in iCloud are downloaded as needed.

## Build

Open `PhotoExportApp.xcodeproj` in Xcode, set your team under Signing & Capabilities, and run. The project is generated from `project.yml`; after changing it, regenerate with:

```sh
brew install xcodegen   # once
xcodegen generate
```

The app bundles [icloudpd](https://github.com/icloud-photos-downloader/icloud_photos_downloader) (MIT) to sign in to iCloud and download photos directly. The first build runs `scripts/build-icloudpd.sh`. The script downloads a pinned, checksum-verified standalone Python ([python-build-standalone](https://github.com/astral-sh/python-build-standalone)) and the pinned icloudpd source, then builds them into `Vendor/icloudpd-runtime/`. That folder isn't committed. The build step copies the runtime into the app's Resources and signs it. Its interpreter inherits the app's sandbox (`PhotoExportApp/Helper.entitlements`).

Two details are needed to make it work inside the sandbox:
- icloudpd is installed from source. The PyPI wheels wrap a PyInstaller binary whose launcher uses System V semaphores, which the sandbox forbids.
- A small launcher replaces icloudpd's `multiprocessing.Lock` with a thread lock, because named POSIX semaphores are forbidden too.

Change `PRODUCT_BUNDLE_IDENTIFIER` (currently `com.example.PhotoExportApp`) before you distribute the app.

## Flow

On first launch, a welcome screen and a four-page introduction carousel come before the steps below. **Help → Welcome to Photo Export** replays them. Back and Forward in the toolbar (⌘[ / ⌘]) move between screens, and Forward revisits screens you've already seen, like a browser.

1. **Connect:** grant access to the photo library. With iCloud Photos turned on in Photos, this includes your iCloud library. The app never asks for Apple ID credentials.
2. **Overview:** the item count and an animated preview of up to 5,000 recent thumbnails.
3. **Set up:** pick the destination folder and a folder layout.
4. **Export:** progress, pause, cancel, resume, and an activity log.

## Folder layouts

| Layout | Example |
| --- | --- |
| By Month | `2024/07/IMG_0001.HEIC` |
| By Place | `Italy/Rome/IMG_0001.HEIC` |
| By Place, Then Month | `Italy/Rome/2024-07/IMG_0001.HEIC` |
| By Album | `Trips/Rome 2024/IMG_0001.HEIC` (items in several albums go in each one; APFS clones take no extra space) |

Place names come from reverse geocoding each photo's GPS location: MapKit on macOS 26+, `CLGeocoder` on earlier versions. Coordinates are grouped into cells of about 10 km, so nearby photos share one lookup, and results are cached in the app's Application Support folder. When the service rate-limits requests, the export waits and retries. If it stays unreachable, the run stops and can be resumed. Items without a location go in `Unknown Location`.

## Backup features

- **Automatic backup** (Settings, ⌘,): back up when the destination drive is connected and/or once a day. While it's on, the app stays in the menu bar after its window closes. It can open at login and sends a notification when a backup finishes.
- **Metadata sidecars** (optional): an `.xmp` file next to each item with its albums, favorite status, hidden status, location and dates, which Lightroom and similar apps can read. Titles, captions, keywords and people aren't available through Apple's public API, so they aren't included.
- **Checksums:** every file is hashed while it downloads and again after it's written, so a bad copy is caught right away. **Verify Backup…** re-reads the whole backup later and offers to re-export anything damaged or missing.
- **Free Up Space…:** removes items from the photo library only after their backup copies are re-verified, skipping items edited since the backup. You can keep favorites, hidden items, or anything newer than 1, 2 or 5 years. It asks for confirmation, and then macOS asks again. Removed items stay in Recently Deleted for 30 days. With iCloud Photos on, removal also applies to iCloud, to every device and to Shared Library participants.

## Files in the destination

Alongside the exported photos, a hidden `.photo-export/` folder holds:

- `exported.tsv`: journal of exported items (`localIdentifier`, then the files written)
- `run-in-progress`: present until a run finishes with no failures
- `layout`: the layout used by the most recent run
- `checksums.tsv`: SHA-256 of every exported file (`relative path`, then the checksum)

## Resuming and errors

- **Resume:** items listed in `exported.tsv` are skipped. A later run picks up where the last one stopped and exports only new items. If `run-in-progress` is present, the main button reads "Resume".
- **Partial files:** each file is streamed to a hidden `.partial` file and renamed only once it's complete. If one file for an item fails, the item's other files are removed, so a retry doesn't create duplicates.
- **Stops the run:** a full disk or a destination that has gone away. Any other per-item error is logged in Activity, and Resume retries it.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘[ / ⌘] | Back / Forward |
| ⌘O | Choose destination |
| ⌘R | Start / Resume |
| ⌘. | Cancel export |
