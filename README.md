# Photo Export

A macOS 14+ SwiftUI app that copies your whole photo library, including originals, edits, RAW pairs and Live Photo videos, into a folder or external drive you choose. Items stored only in iCloud are downloaded as needed.

## Build

Open `PhotoExportApp.xcodeproj` in Xcode, set your team under Signing & Capabilities, and run. The project is generated from `project.yml`; after changing it, regenerate with:

```sh
brew install xcodegen   # once
xcodegen generate
```

Change `PRODUCT_BUNDLE_IDENTIFIER` (currently `com.example.PhotoExportApp`) before you distribute the app.

## How exports are laid out

```
<destination>/
  2024/07/IMG_0001.HEIC
  2024/07/IMG_0001.MOV            Live Photo video
  2024/07/IMG_0001 (Edited).HEIC  current edit, if any
  Undated/…
  .photo-export/
    exported.tsv                  journal: localIdentifier, then the files written
    run-in-progress               present until a run finishes with no failures
```

- **Resume:** items listed in `exported.tsv` are skipped. A later run picks up where the last one stopped and exports only new items. If `run-in-progress` is present, the main button reads "Resume".
- **Partial files:** each file is streamed to a hidden `.partial` file and renamed only once it's complete. If one file for an item fails, the item's other files are removed, so a retry doesn't create duplicates.
- **Stops the run:** a full disk or a destination that has gone away. Any other per-item error is logged in Activity, and Resume retries it.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘O | Choose destination |
| ⌘R | Start / Resume |
| ⌘. | Cancel export |
