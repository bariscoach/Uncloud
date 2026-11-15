# uncloud-rs

A Rust command-line version of Uncloud for macOS. It copies your Photos library into a folder you
choose: originals, edits, RAW+JPEG pairs and Live Photo movies. Re-running picks up where the last
run stopped, and each file is checksummed.

It writes the same `.photo-export/` folder as the SwiftUI app (`exported.tsv`, `checksums.tsv`,
`run-in-progress`, `layout`), so a destination can be checked by either one.

## Build

```sh
cargo build --release
# binary: target/release/uncloud-rs
```

Requires Rust 1.83 or later. SQLite is bundled, so there's nothing to install with Homebrew.

## Use

```sh
# Count what would be copied, without copying
uncloud-rs export --to ~/Backups/Photos --dry-run

# Copy into year/month folders, with .xmp sidecars
uncloud-rs export --to ~/Backups/Photos --xmp

# Copy everything into one folder, no subfolders
uncloud-rs export --to /Volumes/Drive/Photos --layout flat

# Check every exported file against its recorded checksum
uncloud-rs verify --to ~/Backups/Photos

# See the item count and whether the last run finished
uncloud-rs status --to ~/Backups/Photos
```

By default the library is `~/Pictures/Photos Library.photoslibrary`. Use `--library` to pick another.

Exit codes: `0` success, `1` error (for example, a missing library), `2` some items failed or verify
found problems.

## macOS permissions

Reading the library needs **Full Disk Access** for the terminal app (or the binary) under
System Settings → Privacy & Security. Quit Photos first if you want the most consistent copy; the
database is read from a copy, so Photos doesn't have to be closed.

## How it works

- The library database (`database/Photos.sqlite`, plus its write-ahead log) is copied to a temporary
  folder and opened read-only. The live library is never written to.
- Each item's files are streamed to hidden `.partial` files, hashed, renamed into place, and then
  re-read and hashed again to confirm the copy.
- An item is recorded in `exported.tsv` only after all its files are in place. If one file fails,
  the files this run made for that item are removed and the item is retried next time.
- A full disk stops the run and leaves `run-in-progress` in place, so the next run resumes there.
- Name clashes get ` (1)`, ` (2)` and so on. An identical file already at the target is reused, not
  duplicated. This covers a run that stopped after writing a file but before recording it.
- Items whose original isn't on this Mac (iCloud-only) are counted and skipped. Download them in
  Photos, then run again.

## What's different from the SwiftUI app

The Swift app reads originals through PhotoKit and downloads iCloud-only items with icloudpd. Rust
has no PhotoKit binding here, so this tool works from the library files directly. That means:

| Feature | SwiftUI app | uncloud-rs |
| --- | --- | --- |
| Originals, RAW pairs, Live Photo movies | Yes | Yes (companions are matched by file name) |
| Edited renders | Yes | Yes (`resources/renders/`) |
| Month and flat layouts | Yes | Yes |
| By Place and By Album layouts | Yes | Not yet |
| iCloud-only items, downloaded automatically | Yes (icloudpd) | No. Download them in Photos, then run again |
| Metadata sidecars (`.xmp`) | Yes | Dates, favorite, GPS. No albums or people |
| Checksums, verify, resume | Yes | Yes |
| Pause, menu bar, scheduled backups | Yes | No |

## Verifying on a real library

The Photos database schema isn't a public API and changes between macOS releases. This crate reads
the `ZASSET` columns used by the schema Photos has used for several releases (`ZUUID`,
`ZFILENAME`, `ZDIRECTORY`, `ZDATECREATED`, `ZKIND`, `ZTRASHEDSTATE` and others). The edited-render
file names (`<UUID>_1_201_a.jpeg`, and `_2_201_a.mp4` for video) are also from observed Photos
layouts. Try `--dry-run` first and compare its counts with Photos. Then run `verify` on a small
destination before trusting it with the whole library.

## Tests

```sh
cargo test
```

The integration tests build a fake `.photoslibrary` (database, originals, companions and renders),
then check resume, layouts, name clashes, sidecars, dry runs and verify.
