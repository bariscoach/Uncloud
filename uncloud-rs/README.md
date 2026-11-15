# uncloud-rs

A command-line version of Uncloud for macOS. It copies your Photos library into a folder you
choose: originals, edits, RAW+JPEG pairs and Live Photo movies. Each file is checksummed, and
re-running picks up where the last run stopped.

The output folder uses the same `.photo-export/` format as the SwiftUI app, so either tool can
verify a destination the other wrote.

## Run with Cargo

You need Rust 1.83 or later (`rustup update stable`). SQLite is bundled, so nothing else to install.

Run from this folder (`uncloud-rs/`). Everything after `--` goes to the program:

```sh
# Count what would be copied, without copying anything
cargo run --release -- export --to ~/Backups/Photos --dry-run

# Copy into year/month folders
cargo run --release -- export --to ~/Backups/Photos

# Copy into year/month folders, with .xmp sidecars (dates, favorite, location)
cargo run --release -- export --to ~/Backups/Photos --xmp

# Copy everything into one folder with no subfolders
cargo run --release -- export --to /Volumes/Drive/Photos --layout flat

# Check every exported file against its recorded checksum
cargo run --release -- verify --to ~/Backups/Photos

# Show the item count and whether the last run finished
cargo run --release -- status --to ~/Backups/Photos

# Show all options
cargo run -- --help
```

Leave out `--release` while you're developing; the debug build starts faster but copies more slowly.

To use a library other than `~/Pictures/Photos Library.photoslibrary`, add `--library <path>` to
`export`.

To install the binary once and run it as `uncloud-rs`:

```sh
cargo install --path .
uncloud-rs export --to ~/Backups/Photos
```

## Options

| Option | Commands | Meaning |
| --- | --- | --- |
| `--to <folder>` | export, verify, status | Destination folder. Created if needed. |
| `--library <path>` | export | Photos library. Defaults to `~/Pictures/Photos Library.photoslibrary`. |
| `--layout month\|flat` | export | `month` (default) writes `2024/07/IMG_0001.HEIC`; `flat` writes everything in one folder. |
| `--xmp` | export | Writes an `.xmp` sidecar next to each exported file. |
| `--dry-run` | export | Counts what would be copied without writing anything. |

Exit codes: `0` success, `1` error (for example, a missing library), `2` some items failed or
`verify` found problems.

## macOS permissions

Reading the library needs **Full Disk Access** for the app that runs the command (Terminal, iTerm,
or the binary) under System Settings → Privacy & Security. You don't need to quit Photos: the
database is read from a copy.

## How it works

- The library database (`database/Photos.sqlite` and its write-ahead log) is copied to a temporary
  folder and opened read-only. The live library is never modified.
- Each file is streamed to a hidden `.partial` file while it's hashed, renamed into place, and then
  re-read and hashed again to confirm the copy.
- An item is written to `exported.tsv` only after all its files are in place. If one of its files
  fails, the files this run made for it are removed, and the item is retried next time.
- A full disk stops the run and leaves `run-in-progress` in place, so the next run resumes there.
- Name clashes get ` (1)`, ` (2)` and so on. An identical file already at the target is reused, not
  duplicated, which covers a run that stopped after copying a file but before recording it.
- Items whose original isn't on this Mac (iCloud-only) are counted and skipped. Download them in
  Photos, then run again.

## Output folder

```
<destination>/
  2023/03/IMG_0001.HEIC        exported files (layout dependent)
  2023/03/IMG_0001.MOV         companions: Live Photo movie, RAW+JPEG pair
  2023/03/IMG_0001-edited.jpeg edited render
  .photo-export/
    exported.tsv               one line per item: UUID, then its files
    checksums.tsv              SHA-256 of every file: path, then hash
    run-in-progress            present until a run finishes cleanly
    layout                     layout used by the last run
```

## Differences from the SwiftUI app

The Swift app reads originals through PhotoKit and downloads iCloud-only items with icloudpd. This
tool has no PhotoKit binding, so it works from the library files directly.

| Feature | SwiftUI app | uncloud-rs |
| --- | --- | --- |
| Originals, RAW pairs, Live Photo movies | Yes | Yes (companions matched by file name) |
| Edited renders | Yes | Yes (`resources/renders/`) |
| Month and flat layouts | Yes | Yes |
| By Place and By Album layouts | Yes | Not yet |
| iCloud-only items downloaded automatically | Yes (icloudpd) | No. Download in Photos, then run again |
| `.xmp` sidecars | Yes | Dates, favorite, GPS. No albums or people |
| Checksums, verify, resume | Yes | Yes |
| Menu bar, scheduled backups, pause | Yes | No |

## Check it on your library first

Photos' database schema isn't a public API and changes between macOS releases. The crate reads the
`ZASSET` columns it has used for several releases (`ZUUID`, `ZFILENAME`, `ZDIRECTORY`,
`ZDATECREATED`, `ZKIND`, `ZTRASHEDSTATE` and others), and the edited-render file names
(`<UUID>_1_201_a.jpeg`, `_2_201_a.mp4` for video) come from observed layouts. Before a full copy:

1. Run `--dry-run` and compare its counts with Photos.
2. Export a small test destination and run `verify` on it.

## Tests

```sh
cargo test
```

The integration tests build a fake `.photoslibrary` (database, originals, companions and renders),
then check resume, layouts, name clashes, sidecars, dry runs and verify.
