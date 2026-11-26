# Uncloud

A macOS 14+ SwiftUI app that exports iCloud Photos originals, including edits, RAW pairs and Live Photo videos, to a folder or external drive you choose. Items stored only in iCloud are downloaded as needed. Photos go from Apple to that drive. They are not uploaded to Uncloud.

The app is free to start, with no account. Free covers a manual export of about 1,000 items, or a date range, and browsing the backup by date. Plus ($29), Pro ($49), and Family ($69) are one-time purchases: the whole library, automatic backups, every layout, map and place browse, and XMP on Plus; verified iCloud cleanup, verify backup, a second destination, two Macs, and email support on Pro; five Macs on Family. People who already use Uncloud can get a lifetime Plus key. Those limits are not enforced yet. `UncloudLicenseGating` in `Info.plist` defaults to false, so this build does not lock anything that works today. The marketing site is [https://www.tryuncloud.com](https://www.tryuncloud.com). Its version line matches `MARKETING_VERSION` in `project.yml` (0.1.27, build 28).

## Build

Open `Uncloud.xcodeproj` in Xcode, set your team under Signing & Capabilities, and run. The project is generated from `project.yml`; after changing it, regenerate with:

```sh
brew install xcodegen   # once
xcodegen generate
```

The app bundles [icloudpd](https://github.com/icloud-photos-downloader/icloud_photos_downloader) (MIT) to sign in to iCloud and download photos directly. The first build runs `scripts/build-icloudpd.sh`. The script downloads a pinned, checksum-verified standalone Python ([python-build-standalone](https://github.com/astral-sh/python-build-standalone)) and the pinned icloudpd source, then builds them into `Vendor/icloudpd-runtime/`. That folder isn't committed. The build step copies the runtime into the app's Resources and signs it. Its interpreter inherits the app's sandbox (`Uncloud/Helper.entitlements`).

Two details are needed to make it work inside the sandbox:
- icloudpd is installed from source. The PyPI wheels wrap a PyInstaller binary whose launcher uses System V semaphores, which the sandbox forbids.
- A small launcher replaces icloudpd's `multiprocessing.Lock` with a thread lock, because named POSIX semaphores are forbidden too.

Change `PRODUCT_BUNDLE_IDENTIFIER` (currently `com.example.Uncloud`) before you distribute the app.

## Flow

The window opens on the export screen. **Help → Getting Started** shows the three steps again. An Uncloud account is optional and is not required to export or to enter a license key. **Uncloud → Upgrade…** opens Settings → License.

1. **Connect photos.** Sign in to iCloud Photos, or use Photos on this Mac. An Apple ID used for iCloud stays in the macOS Keychain on this Mac. It is not sent to Uncloud. Photos on this Mac uses the Photos library permission instead.
2. **Choose a backup folder** and a folder layout.
3. **Export.** Progress, pause, cancel, resume, and an activity log. Export by date is a separate control.
4. **Browse the backup** on the drive, and, if you ask, delete selected photos from iCloud. Deleted photos move to Recently Deleted for about 30 days. The backup on the drive is not changed.

## Folder layouts

| Layout | Example |
| --- | --- |
| By Month | `2024/07/IMG_0001.HEIC` |
| By Place | `Italy/Rome/IMG_0001.HEIC` |
| By Place, Then Month | `Italy/Rome/2024-07/IMG_0001.HEIC` |
| By Album | `Trips/Rome 2024/IMG_0001.HEIC` (items in several albums go in each one; APFS clones take no extra space) |
| All in One Folder | `IMG_0001.HEIC` |

iCloud downloads can use By Month, By Album, or All in One Folder. By Place and By Place, Then Month are for Photos on this Mac.

Place names come from reverse geocoding each photo's GPS location: MapKit on macOS 26+, `CLGeocoder` on earlier versions. Coordinates are grouped into cells of about 10 km, so nearby photos share one lookup, and results are cached in the app's Application Support folder. When the service rate-limits requests, the export waits and retries. If it stays unreachable, the run stops and can be resumed. Items without a location go in `Unknown Location`.

## Backup features

- **Automatic backup** (Settings, ⌘,): back up when the destination drive is connected and/or once a day. While it's on, the app stays in the menu bar after its window closes. It can open at login and sends a notification when a backup finishes.
- **Metadata sidecars** (optional): an `.xmp` file next to each item with its albums, favorite status, hidden status, location and dates, which Lightroom and similar apps can read. Titles, captions, keywords and people aren't available through Apple's public API, so they aren't included.
- **Checksums:** every exported file’s SHA-256 is stored in `checksums.tsv` as it is written, so a bad copy can be spotted. A separate **Verify Backup** command, which would re-read the drive later, is part of Pro and is not in the app yet.
- **Delete from iCloud:** you pick photos and confirm. They move to Recently Deleted, where Apple keeps them for about 30 days, and they leave every device that uses that iCloud Photos library. Uncloud does not delete anything during export.

## Licenses

A license key is not an account. Settings → License saves it on this Mac (`uncloud.license.v1` in UserDefaults) and asks `POST /v1/licenses/verify` on the API. If that request cannot be completed, a well-formed key is still saved and marked unconfirmed. Buy buttons on the website use `UNCLOUD_CHECKOUT_PLUS_URL`, `UNCLOUD_CHECKOUT_PRO_URL`, and `UNCLOUD_CHECKOUT_FAMILY_URL` on the Vercel project `uncloud`, falling back to `site/checkout.config.json`. Empty values show “Checkout isn’t connected yet.”

The key shape, shared with `server/uncloud-api/lib/licenses.js`, is `UC1.<tier>.<seats>.<flag>.<nonce>`: `plus` with 1 seat, `pro` with 2, `family` with 5, flag `s` or `g` (grandfathered lifetime Plus). Example: `UC1.plus.1.g.EXISTING1`. The verify route is a stub: it checks the shape, stores nothing, and uses no payment secret. `POST /v1/webhooks/payments` accepts a Lemon Squeezy-style or Paddle-style body, does not check a signature, and does not issue a key. Replace that stub before setting `UncloudLicenseGating` to true.

## Files in the destination

Alongside the exported photos, a hidden `.photo-export/` folder holds:

- `exported.tsv`: journal of exported items (`localIdentifier`, then the files written)
- `run-in-progress`: present until a run finishes with no failures
- `layout`: the layout used by the most recent run
- `checksums.tsv`: SHA-256 of every exported file (`relative path`, then the checksum)

## Resuming and errors

Diagnostic logs of the last iCloud helper runs stay on this Mac, in the app's Caches folder (Help > Show Diagnostic Logs). They are redacted, and you can share them when reporting a problem.

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
