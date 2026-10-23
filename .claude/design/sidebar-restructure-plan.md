# Sidebar restructure plan: Cloud Library, Export Settings, Browse Backup, Tools, Delete from iCloud

Branch `feature/duplicates-and-icloud-cleanup`. Written 2026-10-22. PLAN ONLY.

Owner requests covered:
- **R1.** "rename library as Cloud Library and make it first menu, second menu call it export settings, move tools
  out of it and make it a new menu on the left bar, make export folder organization a separate menu within export
  settings, redesign and make it easier to understand for users. and then remove icloud as a separate menu add it to
  the other options on the left menu and call it delete from icloud"
- **R2.** "merge icloud account menu (where icloud menu is visible) and app account profile management menu in one
  menu and move it to bottom. redesign it and then use haiku to build."
- **R3.** "Make uncloud logo visible statically on top of menu options on top left."

**Precondition.** A builder is changing the Export New Photos sheet into "Export Photos by Date…". It touches
`ExportRangeSheet.swift`, `ExportSince.swift`, `ExportModel` (primary title), `NewPhotos.swift`, `ExportCommands.swift`
and `MenuBarContent.swift`. **No chunk here starts before that work is merged.** After that, the primary action
everywhere (the Cloud Library toolbar, the Export Settings hero and Backup › ⌘R) opens the date-range sheet, and this
plan does not change it. This plan does not touch `ExportRangeSheet.swift`, `ExportSince.swift` or `NewPhotos.swift`.

HIG and copy rules from `hig-redesign-plan.md` §3.2, §3.8 and §3.9 still apply:
- Title Case for rows, buttons and headers. Sentence case for captions, toggles and help.
- Tooltips start with a verb and are at most 75 characters.
- Locked rows keep a trailing lock and say "Requires Uncloud Plus". Choosing a locked row never opens the paywall
  on its own.
- Colour is never the only signal, so warnings carry a symbol.

---

## 1. Information architecture

### 1.1 Sidebar (top to bottom)

```
┌──────────────────────────────┐
│ ● ● ●                  [⊟]   │  titlebar: traffic lights + system sidebar toggle (unchanged)
│ [icon] Uncloud               │  R3: static brand header, top safe-area inset (does not scroll)
│ ──────────────────────────── │
│ ☁  Cloud Library             │  ⌘1  default pane
│ ⚙  Export Settings     99%   │  ⌘2  badge: % while exporting, else new-photo count
│ ▦  Browse Backup        🔒   │  ⌘3
│ 🧰 Tools                🔒   │  ⌘4  lock only when every tool is locked
│ ⌫☁ Delete from iCloud   🔒   │  ⌘5  same list, no "iCloud" section header
│                              │
│ ──────────────────────────── │
│ (B•) barishiz@gmail.com    ⌃ │  R2: one account control, bottom safe-area inset
│      Free · iCloud Photos    │
└──────────────────────────────┘
```

| # | Row | Enum case (kept) | Symbol | Shortcut | Detail title | Badge / lock |
|---|---|---|---|---|---|---|
| 1 | Cloud Library | `.export` | `photo.on.rectangle` | ⌘1 | the source name: "iCloud Photos" or "Photos on This Mac" (decision D1) | — |
| 2 | Export Settings | `.backup` | `gearshape` | ⌘2 | "Export Settings" | today's Backup badge, prominence and accessibility value move here unchanged |
| 3 | Browse Backup | `.browse` | `photo.stack` | ⌘3 | "Browse Backup" | lock when `!allows(.browseBackup)` |
| 4 | Tools | `.tools` (**new**) | `wrench.and.screwdriver` | ⌘4 | "Tools" | lock when none of `.verifyBackup`, `.findDuplicates`, `.freeUpSpace` is allowed |
| 5 | Delete from iCloud | `.cleanup` | `xmark.icloud` | ⌘5 | "Delete from iCloud" | lock when `!allows(.cleanUpICloud)` |

Why it's built this way:
- **One flat list, five rows.** HIG *Sidebars* says to keep the hierarchy shallow and to use a section header only
  when it helps people scan. With five rows, the "iCloud" header only took space, and the owner asked to remove it.
  The row stays the last one so the only destructive pane sits furthest from the default pane.
- **Symbols.** `gearshape` is the system symbol for settings. `xmark.icloud` reads as "remove from iCloud". Plain
  `icloud` read as "go to iCloud", and `icloud.slash` means offline. All rows use the accent colour, with no fixed
  colours.
- **Shortcuts.** ⌘1–⌘5 follow the visual order, as Finder and Mail do.

### 1.2 Export Settings sub-sections: segmented control in the toolbar

The mechanism is a two-segment control, **General | Folder Organization**, placed at `ToolbarItem(placement:
.principal)` of the Export Settings pane. Each segment shows its own grouped `Form`.

Why this one:
- **HIG *Segmented controls*.** A segmented control switches between closely related views of the same thing, and
  in a macOS toolbar it is the native way to switch views inside one pane. Finder's view switcher and Xcode's
  inspector tabs work this way. The app already uses it: Delete from iCloud's "All Photos | Recently Deleted" picker
  sits in the same place. Two consistent patterns are easier to learn than three.
- **Not sidebar children.** They would add a disclosure level, and the sidebar would grow to seven rows for one
  pane. The Export Settings badge also needs a single row to sit on. HIG *Sidebars* says to avoid hiding primary
  navigation inside disclosures.
- **Not a TabView.** A TabView inside a grouped form draws a second chrome bar inside the pane. On macOS that is
  the look of a Settings window, and the app already has one, so the two would be easy to confuse.

The selected segment lives in `ExportModel.exportSettingsSection` (`.general` / `.folders`). It is not persisted, so
it always opens on General. The model owns it so that code can switch to Folder Organization. The **layout-mismatch
confirmation dialog** moves from `layoutPicker` up to the pane root, so it shows whichever segment is visible. When
`startRun` finds a mismatch it sets `pane = .backup` **and** `exportSettingsSection = .folders`. Today this
confirmation is attached to the picker, so moving the picker without moving the dialog would silently break it.

### 1.3 Persisted state

- **The selected pane is not persisted.** See the `ExportModel.swift:36` comment, "Nothing persists the selected
  pane". `@SceneStorage` and `@AppStorage` don't store it either. No migration is needed.
- **Keep the enum case names** `.export`, `.backup`, `.browse` and `.cleanup`, and add `.tools`. Renaming them would
  touch about 12 files, several of them the other builder's, for no user-visible gain. Instead:
  - Make `Pane` `CaseIterable`, with its cases declared in sidebar order.
  - Add `title`, `symbol` and `shortcut` to `Pane`.
  - The sidebar and the View menu both read `Pane.allCases`, so the order is defined once, and tests assert it.
  - Add a doc comment mapping each case to its row name.
- **Default pane** changes from `.backup` to `.export` (Cloud Library).
- **Still loaded unchanged:** `layoutKey`, `writesSidecarsKey`, `sourceKey`, `activityExpanded` and
  `SettingsTab.storageKey`.

### 1.4 What moves where

| Thing | Before | After |
|---|---|---|
| Photo grid | "Library" (2nd) | **Cloud Library** (1st, default) |
| Hero status + export button, backup folder, Space, drive summary, history, activity | Backup pane | Export Settings › **General** |
| Folder layout picker + explanation, flat-folder notice, layout-switch notice, XMP toggle, file-name rule | Backup › "Folders" | Export Settings › **Folder Organization** |
| Verify Backup, Find Duplicates, Free Up Space buttons | Backup › "Tools" row | **Tools** pane, one card each. They stay in the Backup menu too. |
| Clean Up iCloud | own "iCloud" section | **Delete from iCloud**, 5th row in the same list |
| Automatic backups | Settings › Backups | Unchanged. Export Settings › General adds a status row with "Change…", which opens Settings › Backups (decision D3). |
| Apple ID / source footer + toolbar avatar | two controls | **one account control** at the sidebar bottom (§6) |

### 1.5 View menu (`CommandGroup(before: .sidebar)`)

```
Cloud Library          ⌘1
Export Settings        ⌘2
Browse Backup          ⌘3
Tools                  ⌘4
Delete from iCloud     ⌘5
─────────
Sort ▸                      (unchanged, Browse Backup only)
─────────
Show/Hide Sidebar      ⌃⌘S  (system)
```

These are built by `ForEach(ExportModel.Pane.allCases)`, using `pane.title` and `KeyEquivalent(pane.shortcut)`.
Locked panes stay enabled, because they open the locked view, the same as clicking the row.

Other menus:
- **The Backup menu keeps its name and items.** "Backup" is still the right noun for export, pause, check and the
  tools, and HIG *The menu bar* says to list commands in the menu bar even when they are also in a pane.
- The Edit menu's "Delete from iCloud…" ⌘⌫ is unchanged. It now matches the pane name.

---

## 2. Per-pane layouts

### 2.1 Cloud Library (`.export`, `ExportView.swift`)

**First thing seen:** the grid of the whole library. The subtitle reads "All 93,015 photos selected · about 412 GB".
**Main action:** the prominent toolbar button. After the other builder's change it is "Export Photos by Date…" or
"Export N Photos", whichever `primaryExportTitle` returns.

```
┌ iCloud Photos ─ All 93,015 photos selected · about 412 GB ──── [Select All] (◔) │ [Export Photos by Date…] ┐
│ ▢ ▢ ▢ ▢ ▢ ▢ ▢ ▢                                                                                         │
│ ▢ ▢ ▢ ▢ ▢ ▢ ▢ ▢     grid (unchanged)                                                                    │
└──────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

Changes:
- Only copy changes. The progress ring and "Waiting to Resume" now open **Export Settings** instead of Backup.

Empty states, all existing:

| State | Shows |
|---|---|
| No source ready | `LandingView` |
| Photos access blocked | `PhotosAccessView` |
| Loading | "Loading your library…" |
| Sign-in expired | "Sign In to iCloud Again" |
| Failed | "Couldn't Open Your Library" + Try Again |

New: an empty library (count 0) shows `ContentUnavailableView("No Photos Yet", systemImage: "photo.on.rectangle",
description: "Photos you add to <source> appear here.")`.

### 2.2 Export Settings (`.backup`, `BackupPane.swift` → `ExportSettingsPane`)

The toolbar has the segmented control `[ General | Folder Organization ]` at principal, and "Show in Finder" at
primary, as today.

**General.** **First thing seen:** the hero, with the backup status in one line. **Main action:** the hero button.

```
┌ Export Settings ─ My Passport ───────────── [ General | Folder Organization ] ───── [📁] ┐
│ ┌─────────────────────────────────────────────────────────────────────────────────────┐ │
│ │ (✓) Your backup is up to date                          [Export Photos by Date…]     │ │  hero (unchanged)
│ │     Last export today.                                                              │ │
│ └─────────────────────────────────────────────────────────────────────────────────────┘ │
│ Backup Folder                                                                           │
│   💽 My Passport  /Volumes/My Passport/Photos                          [Change…]        │
│   Space                                  412 GB needed · 1.2 TB free                     │
│   On drive         91,772 photos · Checked today                     [Check Now]        │
│ Automatic Backups                                                                       │
│   Off                                                                  [Change…]        │  D3
│ History  (unchanged ExportHistoryView)                                                  │
│ ▸ Activity                                                                              │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

Changes to General:
- The "Tools" section is removed, along with `BackupToolButtons` from this pane.
- The "Folders" section moves to Folder Organization.
- An **Automatic Backups** section with one row is added:
  - The `LabeledContent` reads "On: when the drive connects and daily", "On: when the drive connects", "On: once a
    day" or "Off".
  - A "Change…" button opens Settings › Backups: set `SettingsTab.backups` in `SettingsTab.storageKey`, then
    `openSettings()`.
  - For free accounts the row shows a lock and the value "Part of Uncloud Plus". "Change…" still opens Settings,
    which already shows the locked row there.
  - This needs `AutoBackupSettings` in the environment. `RootView` already provides it. If not, read
    `UserDefaults` the same way `AutoBackupSettings` does.

General empty states:
- No source ready: `LandingView`, as today.
- No folder: the hero shows "Choose a backup folder" and the History section is hidden, as today.

**Folder Organization.** **First thing seen:** "How your backup folder is organized", the current choice with a
live example path, and the files inside it.
**Main action:** picking a layout. It's a radio group, so every option and its example are visible at once,
replacing a menu whose explanation was hidden in a tooltip.

```
┌ Export Settings ─ My Passport ───────────── [ General | Folder Organization ] ───── [📁] ┐
│ ⚠ This folder is organized by month. Uncloud keeps using By Month here. ...              │  layoutSwitchNotice (if any)
│ Folders                                                                                 │
│   (•) By Month                 2024 / 07 / IMG_0001.HEIC                                │
│   ( ) By Place                 Italy / Rome / IMG_0001.HEIC                             │
│   ( ) By Place, Then Month     Italy / Rome / 2024-07 / IMG_0001.HEIC                   │
│   ( ) By Album                 Trips / Rome 2024 / IMG_0001.HEIC                        │
│   ( ) All in One Folder        IMG_0001.HEIC                                            │
│   Place names come from each photo's location. Photos without one go in "Unknown        │  explanation, visible
│   Location".                                                                            │
│   ⚠ Lots of files in one folder can make Finder slow.                                    │  flatFolderWarning (if any)
│ File Names                                                                              │
│   Files keep their original names, like IMG_0001.HEIC.                                 │
│   If two files share a name, the second gets a number: IMG_0001 (1).HEIC.              │  source-specific
│ Extras                                                                                  │
│   [ ] Save an XMP file with each photo                                                  │
│       Keeps albums, favorites, places and dates for apps like Lightroom.                │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

Changes to Folder Organization:
- **Picker.** `Picker("Folders", …).pickerStyle(.radioGroup)`. Each option's label is an `HStack` of the title and
  `Text(layout.example)` in `.secondary` monospaced caption, showing the path with " / " separators. Options not
  available for the source are left out, as today.
- **Explanation.** `layoutExplanation` moves from `.help` to a visible caption under the picker.
- **File Names section.** It is read-only. Uncloud has no naming setting, and decision D2 is not to add one. Its
  first line is fixed. The second comes from a new `FolderLayout.clashRule(for:)`, which takes the clash sentence
  out of `caption(for:)`:
  - iCloud: "the second gets its size added: IMG_0001-2483921.HEIC."
  - Photos on This Mac: "the second gets a number: IMG_0001 (1).HEIC."

  `caption(for: .flat)` then only says "Everything goes straight into your backup folder, with no subfolders."
- **Extras.** The XMP toggle and its caption. The "Titles, captions…" sentence stays in `.help`.
- **Disabled state.** While exporting, the picker and toggle are disabled, as today, with the footer caption "You can
  change this when the export finishes."
- **Empty state.** With no folder, the pane still works: the choice applies to the first export. The layout-switch
  notice can't appear without a folder.

### 2.3 Browse Backup (`.browse`)

Unchanged except for copy. "Nothing to Browse Yet" → button "Go to Cloud Library" (`pane = .export`), because that is
where exporting starts.

### 2.4 Tools (`.tools`, new `ToolsPane.swift`)

**First thing seen:** two or three cards, one per tool, each saying what it does in one line. **Main action:** each
card has exactly one button, which opens the existing sheet through `account.require(feature) { tools.showX() }`.

```
┌ Tools ─ My Passport ─────────────────────────────────────────────────────────────────────┐
│ ┌───────────────────────────────────────────────────────────────────────────────────────┐ │
│ │ [✓🛡] Verify Backup                                                  🔒 Plus           │ │
│ │       Checks that every photo in your backup opens and matches the original.         │ │
│ │       Use it after moving your backup or if a drive acts up.                          │ │
│ │       Last check: today, 91,772 files OK.                         [Verify Backup…]    │ │
│ ├───────────────────────────────────────────────────────────────────────────────────────┤ │
│ │ [⧉]  Find Duplicates                                                                  │ │
│ │       Finds photos saved more than once in your backup.                               │ │
│ │       Use it to win back space on your drive.                                         │ │
│ │       Not run yet.                                               [Find Duplicates…]   │ │
│ ├───────────────────────────────────────────────────────────────────────────────────────┤ │
│ │ [💾] Free Up Space                         (only when Photos on This Mac)             │ │
│ │       Removes photos from this Mac once they're safely in your backup.               │ │
│ │       Use it when your Mac is running out of room.                                    │ │
│ │       Last run: today, 2,310 photos removed.                     [Free Up Space…]     │ │
│ └───────────────────────────────────────────────────────────────────────────────────────┘ │
│ Tools work on the backup folder chosen in Export Settings.                               │  footer caption
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

Layout:
- A grouped `Form` with one `Section` per tool, so it matches Export Settings.
- Each card is a `ToolCard(title:symbol:summary:whenToUse:lastResult:isLocked:buttonTitle:isEnabled:disabledReason:action:)`.
- The symbol tile reuses the existing feature symbols from `PaidFeature.symbol`.
- **Lock.** When the tool is locked, a `LockGlyph()` + "Plus" sits at the trailing edge of the title. The button
  stays enabled and opens the paywall through `account.require`. Its accessibility value is "Requires Uncloud
  Plus".
- **Last result** reads from a new `lastResult: ToolResult?` (`date`, `text`, `isProblem`) on `BackupVerification`,
  `DuplicateCleanup` and `LibraryCleanup`:
  - It is set when a run reaches `.finished`, `.quickFinished`, `.noneFound`, `.reexported` or `.failed`.
  - `reset()` does **not** clear it.
  - It lives in memory for this session (decision D4).
  - Verify also shows `savedCheck` when there's no `lastResult`: `.resumable(p, _)` → "Paused at p%. Continue it from
    the sheet."
  - With no result at all the line reads "Not run yet."
  - A problem result gets the warning symbol.
- **Disabled reason**, shown as a caption under the button when `canOpenX` is false and the tool is allowed:
  - Exporting: "Available when the export finishes."
  - `destinationIssue`: the issue text.
  - Free Up Space without Photos access: "Needs access to Photos."
- **Free Up Space card** only appears when `model.source == .photosLibrary`.
- **Empty state.** With no backup folder: `ContentUnavailableView { Label("No Backup Folder", systemImage:
  "externaldrive") } description: { Text("Choose a backup folder to check it, find duplicates and free up space.") }
  actions: { Button("Choose Folder…") { model.beginChoosingDestination() }.buttonStyle(.borderedProminent) }`. With
  no source ready: `LandingView`.
- **Toolbar.** "Show in Finder", the same as Export Settings.
- **The sheets.** `.backupToolSheets()` is applied at the window root today. Check `RootView` and keep it there.

### 2.5 Delete from iCloud (`.cleanup`, `CleanupView.swift`)

**First thing seen:** the iCloud grid, with backed-up photos marked, and the segmented control in the toolbar.
**Main action:** the trash toolbar button "Delete from iCloud…", which opens the typed confirmation.

Changes:
- **Rename.** Every "Clean Up iCloud" becomes "Delete from iCloud" in view titles, comments, the locked view and the
  paywall.
- **Mode picker.** "Library | Recently Deleted (n)" → "All Photos | Recently Deleted (n)". This avoids a second
  "Library" next to "Cloud Library".

Empty states:

| State | Title | Text | Buttons |
|---|---|---|---|
| Photos on This Mac | "Delete from iCloud" | "This works with iCloud Photos. To make room on this Mac, use Free Up Space in Tools." | Switch to iCloud Photos (prominent) · Free Up Space… |
| Signed out | "Sign In to iCloud" | unchanged | unchanged |
| Recently Deleted empty | "No Recently Deleted Photos" | unchanged | none |
| Locked | `LockedFeatureView(feature: .cleanUpICloud)` | new title via `PaidFeature.title` | none |

---

## 3. Copy deck (old → new)

### Sidebar and window titles (`MainWindow.swift`, `ExportModel.Pane.title`)

| Old | New |
|---|---|
| Row "Backup" | "Export Settings" |
| Row "Library" | "Cloud Library" |
| — | Row "Tools" |
| Section "iCloud" + row "Clean Up iCloud" | Row "Delete from iCloud" (no section) |
| navigationTitle "Backup" | "Export Settings" |
| navigationTitle "Clean Up iCloud" (both branches) | "Delete from iCloud" |
| — | navigationTitle "Tools" |
| Announcement "Export started. Progress is in Backup." | "Export started. See progress in Export Settings." |
| Doc comment "a sidebar with the Backup, Library, Browse Backup and Clean Up panes" | "…the Cloud Library, Export Settings, Browse Backup, Tools and Delete from iCloud panes" |

### View menu (`ExportCommands.swift`)

| Old | New |
|---|---|
| "Backup" ⌘1 | "Cloud Library" ⌘1 |
| "Library" ⌘2 | "Export Settings" ⌘2 |
| "Browse Backup" ⌘3 | "Browse Backup" ⌘3 |
| — | "Tools" ⌘4 |
| "Clean Up iCloud" ⌘4 | "Delete from iCloud" ⌘5 |
| comment "Published by Clean Up iCloud" | "Published by Delete from iCloud" |

### Paid feature (`AccountTypes.swift`)

| Field | Old | New |
|---|---|---|
| `cleanUpICloud.title` | "Clean Up iCloud" | "Delete from iCloud" |
| `cleanUpICloud.symbol` | "icloud" | "xmark.icloud" |
| `cleanUpICloud.summary` | "Deletes backed-up photos from iCloud, and recovers them if you change your mind." | "Deletes backed-up photos from iCloud to free up storage. You can recover them for 30 days." |
| `verifyBackup.summary` | "Checks that every file in your backup is intact." | unchanged |

### Export Settings › General (`BackupPane.swift`)

| Old | New |
|---|---|
| — | Segmented "General" / "Folder Organization" (accessibility label "Section") |
| Section "Tools" + three buttons | removed (moved to the Tools pane) |
| — | Section "Automatic Backups": value "Off" / "On: when the drive connects" / "On: once a day" / "On: when the drive connects and daily" / "Part of Uncloud Plus"; button "Change…"; help "Open Settings to change automatic backups" |
| "No backup folder chosen" | "No folder chosen yet" |
| Section "Backup Folder" | unchanged |
| "Space" row | unchanged |

### Export Settings › Folder Organization

| Old | New |
|---|---|
| Section "Folders", menu picker, example in caption, explanation in `.help` | Section "Folders": radio group, each with its example path; explanation as a visible caption |
| `FolderLayout.caption(.flat)` "Everything goes straight… When two files share a name, the second gets…" | "Everything goes straight into your backup folder, with no subfolders." |
| — | Section "File Names": "Files keep their original names, like IMG_0001.HEIC." + `clashRule`: "If two files share a name, the second gets a number: IMG_0001 (1).HEIC." (Mac) / "…the second gets its size added: IMG_0001-2483921.HEIC." (iCloud) |
| Toggle "Save XMP metadata files" | "Save an XMP file with each photo" |
| Caption "Adds a small file beside each photo with its albums, favorites, location and dates, for apps like Lightroom." | "Keeps albums, favorites, places and dates for apps like Lightroom." |
| Section header for XMP (was inside "Folders") | Section "Extras" |
| — | Footer while exporting: "You can change this when the export finishes." |
| Place explanation "Place names come from each photo's location, which Apple looks up. Photos without one go in "Unknown Location"." | "Place names come from each photo's location. Photos without one go in "Unknown Location"." |

### Tools (new `ToolsPane.swift`)

| Tool | Summary | When to use | Button |
|---|---|---|---|
| Verify Backup | "Checks that every photo in your backup opens and matches the original." | "Use it after moving your backup or if a drive acts up." | "Verify Backup…" |
| Find Duplicates | "Finds photos saved more than once in your backup." | "Use it to win back space on your drive." | "Find Duplicates…" |
| Free Up Space | "Removes photos from this Mac once they're safely in your backup." | "Use it when your Mac is running out of room." | "Free Up Space…" |

Shared strings for the cards:
- Last result: "Last check: {day}, {text}." / "Last run: {day}, {text}." / "Not run yet." /
  "Paused at {p}%. Continue it from the sheet."
- Locked: "Plus", with the lock glyph.
- Disabled: "Available when the export finishes." / "Needs access to Photos." / the `destinationIssue` text.
- Footer: "Tools work on the backup folder chosen in Export Settings."
- Empty state: "No Backup Folder" / "Choose a backup folder to check it, find duplicates and free up space." /
  "Choose Folder…".

`BackupToolButtons` help strings are retired with the view.

### Delete from iCloud (`CleanupView.swift`)

| Old | New |
|---|---|
| "Clean Up iCloud" (empty-state title) | "Delete from iCloud" |
| "Clean Up iCloud works with iCloud Photos. To make room on this Mac instead, use Free Up Space." | "This works with iCloud Photos. To make room on this Mac, use Free Up Space in Tools." |
| Picker "Library" | "All Photos" |
| Comments "Clean Up iCloud" | "Delete from iCloud" (also `Components.swift`, `LibraryGrid.swift`, `DesignTokens.swift`, `BrowseBackupView.swift`) |

### Other panes and announcements

| File | Old | New |
|---|---|---|
| ExportView | a11y "Export waiting to resume. Show Backup." | "Export waiting to resume. Show Export Settings." |
| ExportView | help "Show export progress" | unchanged |
| BrowseBackupView | "Go to Backup" (`.backup`) | "Go to Cloud Library" (`.export`) |
| ExportModel | log "…while the Folders setting is {layout}." | "…while Folder Organization is set to {layout}." |
| ExportModel | comment "The question is asked on the Backup pane" | "…on Export Settings › Folder Organization" |

### Account control and brand header

See §6.3 and §7.

---

## 4. Build chunks (Haiku-sized)

The model split follows memory: Haiku builds, a quality-control agent reviews, and a designer agent checks
snapshots.

Run every chunk with `xcodebuild test -scheme Uncloud` (or the repo's `scripts/` test command). Snapshot suites are
env-gated, so the snapshot chunk sets their env var.

### 4.1 Order and parallel lanes

```
S0 (other builder merges) ──► S1 ──┬─► S3 ─┐
                                   ├─► S4 ─┤
                                   ├─► S5 ─┼─► S2 ──► A2 ──► T1
                                   ├─► S6 ─┘
                                   └─► A1 ───────────┘
```

| Lane | Chunk | Files it alone owns |
|---|---|---|
| — | S1 | `ExportModel.swift`, `ExportCommands.swift`, `ExportPaneRenameTests.swift`, `LayoutChangeConfirmationTests.swift`, plus a one-line stub case in `MainWindow.swift` |
| parallel | S3 | `BackupPane.swift`, `FolderLayout.swift`, new `FolderOrganizationTests.swift` |
| parallel | S4 | new `ToolsPane.swift`, `BackupToolSheets.swift`, `BackupVerification.swift`, `DuplicateCleanup.swift`, `LibraryCleanup.swift`, new `ToolsPaneContentTests.swift` |
| parallel | S5 | `AccountTypes.swift`, `CleanupView.swift`, `Components.swift`, `LibraryGrid.swift`, `DesignTokens.swift`, `EntitlementGatingTests.swift`, `CleanupSnapshotTests.swift` (suite name only) |
| parallel | S6 | `ExportView.swift`, `BrowseBackupView.swift`, `NewPhotosTracker.swift` (comment only) |
| parallel | A1 | new `Views/Account/AccountFooter.swift`, `Views/Account/AccountButton.swift`, new `AccountFooterContentTests.swift` |
| after all above | S2 | `MainWindow.swift`, `AppLogo.swift` (adds `SidebarBrandHeader`), `brand/README.md` (one line) |
| after S2 | A2 | `MainWindow.swift` |
| last | T1 | `UIRefreshSnapshotTests.swift`, `NewPhotosSnapshotTests.swift`, `AccountSnapshotTests.swift`, `DesignSnapshotTests.swift` |

S3, S4, S5, S6 and A1 share no files and can run at once, each in its own worktree. S2 and A2 both edit
`MainWindow.swift`, so they run one after the other. A2 can be folded into S2 if one agent does both.

### S1. Pane model, default pane, View menu

Files:
- `Uncloud/Model/ExportModel.swift`
- `Uncloud/App/ExportCommands.swift`
- `UncloudTests/ExportPaneRenameTests.swift`

Changes:
1. Update `enum Pane`:
   - Make it `enum Pane: Hashable, CaseIterable { case export, backup, browse, tools, cleanup }`. The order is the
     sidebar order. **Note:** today's declaration order is export, backup, cleanup, browse, so reorder it.
   - Add `var title: String`: "Cloud Library", "Export Settings", "Browse Backup", "Tools", "Delete from iCloud".
   - Add `var symbol: String`: `photo.on.rectangle`, `gearshape`, `photo.stack`, `wrench.and.screwdriver`,
     `xmark.icloud`.
   - Add `var shortcut: Character`: "1" to "5".
   - Update the doc comment (`.export` = Cloud Library, `.backup` = Export Settings).
2. Add `enum ExportSettingsSection: Hashable, CaseIterable { case general, folders }` with `title` "General" /
   "Folder Organization", and `var exportSettingsSection: ExportSettingsSection = .general`.
3. Change `var pane: Pane = .backup` to `= .export`. Update the comment to "Cloud Library is the home pane…".
4. In `startRun`'s mismatch branch, after `pane = .backup`, add `exportSettingsSection = .folders`. Update the comment
   and log copy (§3).
5. ExportCommands: replace the four `Button`s in `CommandGroup(before: .sidebar)` with
   `ForEach(ExportModel.Pane.allCases, id: \.self) { pane in Button(pane.title) { model.pane = pane
   }.keyboardShortcut(KeyEquivalent(pane.shortcut)) }`. Update the `cleanup` FocusedValue comment.
6. Add `case .tools: EmptyView().navigationTitle("Tools")` to `MainWindow`'s detail `switch`, only so it compiles
   until S2. This is the one allowed touch of `MainWindow` here.

Acceptance:
- The app builds.
- The View menu lists five items, ⌘1–⌘5, in the new order.
- `ExportModel().pane == .export`.

Tests:
- `ExportPaneRenameTests`: rename the test to "The first pane is Cloud Library, the home screen" and
  `#expect(ExportModel().pane == .export)`.
- Add `#expect(ExportModel.Pane.allCases == [.export, .backup, .browse, .tools, .cleanup])` and
  `#expect(ExportModel.Pane.allCases.map(\.title) == ["Cloud Library", "Export Settings", "Browse Backup", "Tools",
  "Delete from iCloud"])`.
- Add `#expect(ExportModel().exportSettingsSection == .general)`.
- Run the suite and fix anything that assumed `.backup` as the default: `grep -rn "\.pane\b" UncloudTests`. Known
  sites set the pane explicitly, so none are expected.
- In `LayoutChangeConfirmationTests`, assert that a mismatch sets `exportSettingsSection == .folders`.

### S3. Export Settings: General | Folder Organization

Files:
- `Uncloud/Views/BackupPane.swift` (keep the file name, since the project uses synchronized folders and a rename is
  churn; rename the struct to `ExportSettingsPane` and keep `typealias BackupPane = ExportSettingsPane` so tests and
  S2 compile)
- `Uncloud/Model/FolderLayout.swift`
- new `UncloudTests/FolderOrganizationTests.swift`

Changes:
1. **Body.** `form` becomes `Form { switch model.exportSettingsSection { case .general: generalSections; case .folders:
   folderSections } }`.
2. **Toolbar.** Add `ToolbarItem(placement: .principal) { Picker("Section", selection: $model.exportSettingsSection) {
   ForEach(ExportModel.ExportSettingsSection.allCases, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
   .labelsHidden().accessibilityLabel("Section") }`.
3. **`generalSections`.** Hero, Backup Folder, the new Automatic Backups section (§2.2, §3), `ExportHistoryView` and
   Activity. Delete the Tools section.
4. **`folderSections`.**
   - Optional `layoutSwitchNotice` at the top.
   - Section "Folders": a radio `Picker`, each label `HStack { Text(layout.title); Spacer(); Text(layout.example
     .replacingOccurrences(of: "/", with: " / ")).font(.caption.monospaced()).foregroundStyle(.secondary) }`. Then
     the explanation `Text` as a caption, then `flatFolderWarning`.
   - Section "File Names".
   - Section "Extras" with the XMP toggle.
   - A footer caption while `model.isExporting`.
5. **Dialog.** Move the `.confirmationDialog` from `layoutPicker` to the `Form` (pane root) and keep its contents
   byte-for-byte.
6. **FolderLayout.** Split the clash sentence into `static func clashRule(for source: LibrarySource) -> String`.
   `caption(for:)` keeps only the first sentence for `.flat`.
7. **Copy.** Apply all §3 Export Settings rows.

Acceptance:
- Switching segments keeps the scroll position sensible.
- A layout mismatch from ⌘R on Cloud Library lands on Folder Organization with the dialog open.
- The XMP toggle and picker are disabled while exporting.
- VoiceOver reads the segments as "Section, General, 1 of 2".

Tests:
- `FolderOrganizationTests`: `clashRule` for both sources, and `caption(.flat)` has no clash sentence.
- Run the suites that cover this code: `FolderLayoutAndSelectionTests`, `FlatFolderCheckTests` (asserts caption
  text, so update if it does: `grep -n "caption" UncloudTests/*.swift`), `LayoutChangeConfirmationTests` and
  `XMPSidecarTests`.

### S4. Tools pane

Files:
- new `Uncloud/Views/ToolsPane.swift`
- `Uncloud/Views/BackupToolSheets.swift`
- `Uncloud/Model/BackupVerification.swift`
- `Uncloud/Model/DuplicateCleanup.swift`
- `Uncloud/Model/LibraryCleanup.swift`
- new `UncloudTests/ToolsPaneContentTests.swift`

Changes:
1. **Model.** Add `struct ToolResult: Equatable { let date: Date; let text: String; let isProblem: Bool }` in
   `BackupToolSheets.swift`. Add `private(set) var lastResult: ToolResult?` to each of the three models.
   - Set it where each reaches a terminal state (§2.4). The text comes from the existing summary values, for example
     "91,772 files OK", "3 files need attention", "No duplicates", "12 duplicates removed" or "2,310 photos removed".
   - Do not clear it in `reset()`.
2. **Content.** Add `enum ToolsPaneContent` as pure data: `static func cards(source:allows:canOpen:isExporting:
   destinationIssue:hasPhotosAccess:results:savedCheck:now:) -> [ToolCardContent]`. It returns the copy, lock and
   disabled reason. Free Up Space is included only for `.photosLibrary`.
3. **Views.** `ToolsPane` (a Form of `ToolCard`s, the footer, the empty state and a Show in Finder toolbar item) and
   `ToolCard`.
4. **Retire `BackupToolButtons`.** Delete it once S3 has removed its only use. If S3 hasn't landed yet, leave it and
   delete it in S2.

Acceptance:
- Each button opens the same sheet as the Backup menu item.
- A locked tool opens the paywall.
- After closing a finished Verify, the card shows "Last check: today, …".
- The iCloud source shows two cards.

Tests (`ToolsPaneContentTests`):
- iCloud returns 2 cards and Mac returns 3.
- Locked → `isLocked` and button enabled.
- Exporting → disabled reason "Available when the export finishes.".
- A resumable saved check → "Paused at 42%…".
- No result → "Not run yet.".
- Add one test per model that `lastResult` survives `reset()`: `BackupVerificationStateTests`, `DuplicateFinderTests`
  (or a new small test).

### S5. Rename to "Delete from iCloud"

Files:
- `Uncloud/Account/AccountTypes.swift`
- `Uncloud/Views/CleanupView.swift`
- `Uncloud/Views/Components.swift` (comment)
- `Uncloud/Views/LibraryGrid.swift` (comments)
- `Uncloud/Views/DesignTokens.swift` (comment)
- `UncloudTests/EntitlementGatingTests.swift` (test display names only)
- `UncloudTests/CleanupSnapshotTests.swift` (suite name "Delete from iCloud snapshots")

Changes: the §3 Paid feature and Delete from iCloud rows. Keep the enum case `cleanUpICloud` and the type names
`CleanupView` and `ICloudCleanup`.

Acceptance:
- `grep -rn "Clean Up iCloud" Uncloud` returns nothing.
- The paywall and locked view read "Delete from iCloud".
- The Edit menu item "Delete from iCloud…" is unchanged.

Tests:
- `EntitlementGatingTests`: add `#expect(PaidFeature.cleanUpICloud.title == "Delete from iCloud")`.
- Run `AccountSummaryCopyTests` and `ComponentsTests`. `ComponentsTests` uses `SheetScaffold("Clean Up iCloud")` as a
  plain sample string, so it's fine either way. Changing it to "Delete from iCloud" is optional.
- Check `server/` and `site/` for "Clean Up iCloud" (paywall copy on the site, product names in Stripe metadata). Do
  **not** edit them; list the hits for the owner (D6).

### S6. Small copy in other panes

Files: `ExportView.swift`, `BrowseBackupView.swift`, `NewPhotosTracker.swift`.

Changes:
- `ExportView`: the a11y label "…Show Export Settings.". The `pane = .backup` jumps stay.
- `BrowseBackupView`: "Go to Cloud Library", `pane = .export`.
- `NewPhotosTracker`: the notification click keeps `pane = .backup`, because Export Settings has the hero with the
  count. Its comment, if any, is updated.

Acceptance: build passes, and `BrowseBackupTests` / `BrowseBackupSnapshotTests` run.

Tests: none new. `BrowseBackupTests` should not assert the button title; grep `"Go to Backup"` in `UncloudTests` and
update any hits.

### S2. Sidebar, detail switch, brand header (R1 + R3)

Files:
- `Uncloud/Views/MainWindow.swift`
- `Uncloud/Views/AppLogo.swift` (adds `SidebarBrandHeader`)
- `brand/README.md` (adds the horizontal sidebar lock-up rule, one bullet)

Changes:
1. **Sidebar rows.** Replace the `List` contents with `ForEach(ExportModel.Pane.allCases, id: \.self) { pane in row(for:
   pane).tag(pane) }`.
   - `.backup`: `Label(pane.title, systemImage: pane.symbol)` with the existing `.badge`, `.badgeProminence` and
     `.accessibilityValue`.
   - `.browse`, `.tools` and `.cleanup`: `LockableSidebarRow(title: pane.title, symbol: pane.symbol, isLocked:
     isLocked(pane))`. `.tools` is locked when `!(allows(.verifyBackup) || allows(.findDuplicates) ||
     allows(.freeUpSpace))`.
   - `.export`: a plain `Label`.
   - The `Section("iCloud")` is gone.
2. **Detail.**
   - `.export`: `ExportView().navigationTitle(model.source.title)`. Keep this, per D1.
   - `.backup`: `ExportSettingsPane().navigationTitle(pane.title)`.
   - `.tools`: `ToolsPane().navigationTitle("Tools")`.
   - `.cleanup`: both branches get `.navigationTitle("Delete from iCloud")`.
3. **Copy.** Update the announcement and doc comments per §3.
4. **Brand header (§7).** Add `SidebarBrandHeader` to `AppLogo.swift`, and add `.safeAreaInset(edge: .top, spacing:
   0) { SidebarBrandHeader() }` on the sidebar `List`.
5. If `BackupToolButtons` is still around, delete it.

Acceptance:
- Launch opens on Cloud Library.
- The rows, symbols and badges match §1.1.
- A free account shows locks on Browse Backup, Tools and Delete from iCloud.
- VoiceOver reads the Export Settings row "Export Settings, 1,243 new photos".
- The brand header checks in §7 pass.

Tests:
- `EntitlementGatingTests` `showsCleanup` is unchanged.
- Add a pure `static func toolsLocked(allows: (PaidFeature) -> Bool) -> Bool` on `MainWindow`, with two tests: all
  locked gives true, and one allowed gives false.

### A1. Account control content and popover (R2), parallel

See §6. Files: new `AccountFooter.swift`, `AccountButton.swift`, new `AccountFooterContentTests.swift`.

### A2. Wire the account control into the sidebar (R2), after S2

See §6.5. Files: `MainWindow.swift`.

### T1. Snapshot and window tests (designer agent reviews the PNGs)

Files:
- `UncloudTests/UIRefreshSnapshotTests.swift`
- `UncloudTests/NewPhotosSnapshotTests.swift`
- `UncloudTests/AccountSnapshotTests.swift`
- `UncloudTests/DesignSnapshotTests.swift`

| Test | Change |
|---|---|
| `UIRefreshSnapshotTests` ~L93 `for pane in [.export, .backup, .cleanup]` | `for pane in ExportModel.Pane.allCases`. Names become `window-export/backup/browse/tools/cleanup-…`. Render `.backup` twice, once per `exportSettingsSection` (`window-backup-folders-…`). Restore `.export` and `.general` after. |
| `UIRefreshSnapshotTests` ~L55/69 `BackupPane()` | Keep (typealias). Add a `.folders` render. |
| `NewPhotosSnapshotTests` ~L67 sidebar strip `Text("Backup")` / `externaldrive` | `Text("Export Settings")` / `gearshape`. Update the comment "the Backup row" → "the Export Settings row". |
| `NewPhotosSnapshotTests` ~L130–146 | Unchanged logic. The title assertion belongs to the other builder. |
| `AccountSnapshotTests` ~L99 `locked-tools` renders `BackupPane()` | Render `ToolsPane()` instead. Same name. |
| `AccountSnapshotTests` ~L107–109 `LockableSidebarRow` titles | Use `ExportModel.Pane.browse.title`/`.symbol` (fix the stale `"map"` symbol), add a Tools row, and use "Delete from iCloud"/`xmark.icloud`. |
| `AccountSnapshotTests` ~L116 comment | "Delete from iCloud for a free account…" |
| `AccountSnapshotTests` ~L155–160 `AccountPopover(...)` | Replace with `AccountFooterPopover` for each state (§6.6). Add `menu-footer-row-{free,plus,past-due,icloud-signed-out,mac}`. Drop `menu-button-*` (or keep it as avatar-only). |
| `AccountSnapshotTests` ~L213 `menu-sidebar-*` | Unchanged code. The PNGs now show the brand header and bottom control, with no titlebar avatar. Designer checks 760×500. |
| `DesignSnapshotTests` L41 `rendersBackupPaneInLightAndDark` | Rename to `rendersExportSettingsPaneInLightAndDark`. Render both sections. L102 `Text("Export")` header is a sample and stays. |
| new `ToolsSnapshotTests` (optional, in `UIRefreshSnapshotTests`) | Tools pane: free (locked), Plus with results, iCloud (2 cards), no folder. |

Acceptance:
- All snapshot suites pass with their env flags.
- The designer signs off on light and dark, 1000×700 and 760×500, with the sidebar collapsed and expanded.

---

## 5. Owner decisions

| # | Decision | Recommendation |
|---|---|---|
| D1 | The "Cloud Library" row also shows Photos on This Mac. Should the window title say "Cloud Library" or the source name? | Keep the **row** "Cloud Library" (your word) and the **window title** as the source ("iCloud Photos" / "Photos on This Mac"), so Mac users see where photos come from. |
| D2 | You mentioned "file naming", but Uncloud has no naming setting. Add one (date-based names)? | **No, not now.** Show a read-only "File Names" rule. A setting would change resume and duplicate detection (Opus-sized). |
| D3 | Automatic backups live in Settings › Backups. Move them into Export Settings? | **No.** Show their status in Export Settings › General with "Change…" that opens Settings. HIG *Settings* keeps rarely-changed app-wide prefs in the Settings window. |
| D4 | Should tool "last result" persist across launches? | **This session only, for now.** Persisting needs a per-destination store. Verify already shows its saved checkpoint. |
| D5 | Free account: lock the whole Tools row, or show the cards? | **Lock glyph on the row, but the pane shows the three cards with locks**, so people learn what each does before paying. |
| D6 | "Clean Up iCloud" may also appear on the website, the paywall server copy or Stripe product names. Rename there too? | **Yes, in a separate web chunk.** S5 lists the hits without editing. |
| D7 | The sidebar lock-up is horizontal (icon left, wordmark right). brand/README only defines the stacked one. | **Approve a horizontal "sidebar lock-up"** (§7) and add it to brand/README. |
| D8 | ⌘5 for Delete from iCloud: a destructive pane one keystroke away? | **Fine.** It only opens the pane. Deleting still needs the typed confirmation. |

---

## 6. R2: one account control at the bottom of the sidebar

### 6.1 Today

There are two controls:
- **Uncloud account.** `MainWindow.swift` ~L44–50 has `ToolbarItem { AccountButton() }`, a 22 pt `AccountAvatar` in
  the sidebar titlebar. It opens `AccountPopover`, which has:
  - a header (avatar, email, `PlanBadge`)
  - `statusLine`, `lastCheckedText`
  - the primary action (Get Uncloud Plus… / Manage Subscription… / Update Payment Method… / Check Again)
  - Account Settings…
  - Sign Out of Uncloud…
- **iCloud / source.** `MainWindow.swift` ~L164–216 has `accountFooter`, a `Menu` in `safeAreaInset(edge: .bottom)`.
  It shows:
  - the source icon, the Apple ID or source name, and "Not signed in" / "iCloud Photos" / "Ready" / "Needs access"
  - inside: an inline `Picker("Photos From")` (disabled while exporting), then Sign In to iCloud… / Sign Out of
    iCloud…

The sign-out confirmation (`model.isConfirmingICloudSignOut`) and `ICloudSignInSheet` are presented by
`MainWindow`. `account.isConfirmingSignOut` is presented elsewhere (RootView); keep it.

### 6.2 Design

**A popover, not a menu.** It has to show a status line, a plan badge and a prominent "Get Uncloud Plus…" button,
which a menu can't hold. A popover attached to a sidebar footer row is the same pattern as Mail's and Xcode's
account popovers. HIG *Popovers* says to use one to show more information or a few related controls about the
element.

The row, about 52 pt tall, pinned with `safeAreaInset(edge: .bottom)` and a hairline divider above it:

```
──────────────────────────────────
 (B•)  barishiz@gmail.com       ⌃
       Plus · iCloud Photos
──────────────────────────────────
```

- The avatar is `AccountAvatar(summary:size: 28)` and keeps its own `needsAttention` dot. It gets an **extra
  attention dot** when iCloud needs action: source `.iCloud` and `iCloudAppleID == nil`, or source `.photosLibrary`
  and `!isSourceReady`. To do this, add `var showsAttention: Bool?` to `AccountAvatar`, overriding
  `summary.needsAttention` when it's set.
- Line 1 is the Uncloud email, middle-truncated. When accounts are off (`account.mode == .off`) it's the Apple ID or
  source title, as today.
- Line 2 is `"{plan} · {source line}"`, in caption, secondary:
  - plan: "Free" / "Plus" / "Plus, payment due" / "Plus, not checked"
  - source line: "iCloud Photos" / "iCloud: not signed in" / "Photos on This Mac" / "Photos: needs access"
- The trailing `chevron.up` is secondary and decorative.

The popover is 300 pt wide, arrow edge `.top`, so it opens upwards from the row:

```
┌───────────────────────────────────────┐
│ UNCLOUD ACCOUNT                       │  section header (caption, secondary, title case "Uncloud Account")
│ (B)  barishiz@gmail.com               │
│      [Uncloud Plus]                   │
│ ↻ Renews on October 18, 2027          │  statusLine (warning symbol when needed)
│ Last checked 3 days ago               │  lastCheckedText (when present)
│ [      Manage Subscription…      ]    │  primary action (prominent for Get Plus / Update Payment)
│ Account Settings…                     │  link style
│ Sign Out of Uncloud…                  │  link style, disabled while exporting
├───────────────────────────────────────┤
│ ICLOUD PHOTOS                         │  section header "Photos From"
│ Photos from  ( • iCloud Photos )      │  radio Picker, disabled while exporting
│              ( ○ Photos on This Mac ) │
│ ☁ name@icloud.com                     │  only for .iCloud
│   Connected                           │  or "Not signed in" (warning symbol)
│ Sign Out of iCloud…                   │  or [Sign In to iCloud…] (bordered prominent when signed out)
└───────────────────────────────────────┘
```

For Photos on This Mac, the iCloud lines are replaced by "🖼 Photos on This Mac · Ready", or "· Needs access" with a
"Open Privacy Settings…" link that calls the existing `PhotosAccessView` action. If no such action exists, show only
the text.

**Section header names.** The first is "Uncloud Account". The second is "Photos From", so the source switch reads
naturally. The coordinator asked for it to be called "iCloud Photos", and it reads "iCloud Photos" whenever iCloud is
the source, so the header says "Photos From" and the first radio option is "iCloud Photos". If you want "iCloud
Photos" exactly as the header, it's a one-line change.

### 6.3 Copy

| Element | Old | New |
|---|---|---|
| Toolbar avatar help "Your Uncloud account and plan" | removed | — |
| Footer help "Choose where photos come from, or change the Apple Account used for iCloud Photos" | — | Row help "Show your Uncloud account and photo source" |
| Footer a11y label "Photos from X, Y" | — | Label "Accounts"; value as in §6.4 |
| Footer subtitles "Not signed in" / "iCloud Photos" / "Ready" / "Needs access" | — | Line 2 "{plan} · {source line}" (§6.2) |
| Popover section 1 header | — | "Uncloud Account" |
| Popover section 2 header | — (menu had none) | "Photos From" |
| iCloud state | — | "Connected" / "Not signed in" |
| Mac state | "Ready" / "Needs access" | unchanged |
| Buttons | "Sign In to iCloud…", "Sign Out of iCloud…", "Account Settings…", "Sign Out of Uncloud…", primary titles | unchanged |
| Loading | — | Section 1 shows "Loading your account…" with a small spinner. Section 2 still works. |

### 6.4 States (row and popover)

| State | Row line 1 | Row line 2 | Dot | Popover section 1 |
|---|---|---|---|---|
| Signed out of Uncloud (shouldn't happen; RootView gates the window) | Apple ID or source | source line | no | hidden; section 2 only |
| Accounts off (`mode == .off`) | Apple ID or source | source line | iCloud rule only | hidden |
| Loading | "Uncloud" | "Loading…" | no | "Loading your account…" |
| Free | email | "Free · iCloud Photos" | iCloud rule | badge Free, Get Uncloud Plus… (prominent) |
| Plus renewing / ending | email | "Plus · iCloud Photos" | iCloud rule | badge Plus, statusLine, Manage Subscription… |
| Past due | email | "Plus, payment due · iCloud Photos" | **yes** | warning statusLine, Update Payment Method… (prominent) |
| Offline grace | email | "Plus, not checked · …" | **yes** | statusLine, lastChecked, Check Again |
| iCloud signed out | email | "{plan} · iCloud: not signed in" | **yes** | section 2: "Not signed in" + Sign In to iCloud… (prominent) |
| Photos on This Mac, ready | email | "{plan} · Photos on This Mac" | no | section 2: "Ready", no iCloud lines |
| Photos on This Mac, needs access | email | "{plan} · Photos: needs access" | **yes** | section 2: "Needs access" |
| Exporting | unchanged | unchanged | — | source picker and Sign Out of Uncloud disabled, with help "Change this after the export finishes." |

Accessibility:
- The row is one `Button`, built with `.accessibilityElement(children: .ignore)`.
- Its label is "Accounts".
- Its value is the summary's `accessibilityValue`, followed by the source phrase, for example "barishiz@gmail.com,
  Uncloud Plus, iCloud Photos, signed in as name@icloud.com" or "…, iCloud Photos, not signed in". It adds "needs
  attention" when the dot shows.
- Its hint is "Shows your Uncloud account and photo source."
- **Keyboard.** It's a standard `Button`, so it's reachable with Tab when Full Keyboard Access is on, and
  Space/Return open the popover. In the popover, focus starts on the primary button, as today. The Esc key closes it.
  The menu-bar items (the app menu account items and File › Photos From / Sign In/Out of iCloud) stay, so every
  action also has a keyboard path.

### 6.5 Chunks

**A1. Content, row and popover.** Runs in parallel with S3–S6.

Files:
- new `Uncloud/Views/Account/AccountFooter.swift`
- `Uncloud/Views/Account/AccountButton.swift`
- `Uncloud/Views/Account/AccountAvatar.swift` (the `showsAttention` override only)
- new `UncloudTests/AccountFooterContentTests.swift`

Changes:
1. Add a pure `struct AccountFooterContent: Equatable { line1, line2, needsAttention, accessibilityValue,
   showsUncloudSection, sourceStateText, sourceStateIsWarning }` with `static func make(summary: AccountSummary,
   accountMode:, source: LibrarySource, appleID: String?, isSourceReady: Bool) -> AccountFooterContent`.
2. In `AccountButton.swift`:
   - Move the body of `AccountPopover` into `UncloudAccountSection(summary:isExporting:close:)`. Keep `AccountPopover`
     as a thin wrapper around it, so the existing tests compile until T1.
   - Delete `AccountButton`, which is no longer used after A2.
   - If A2 hasn't landed when A1 merges, leave `AccountButton` in place and delete it in A2.
3. In `AccountFooter.swift`:
   - `AccountFooterRow` is the button, with `@State isShowingPopover` and `.popover(arrowEdge: .top)`.
   - `AccountFooterPopover` is `VStack { if content.showsUncloudSection { UncloudAccountSection(...) ; Divider() };
     PhotosSourceSection() }`.
   - `PhotosSourceSection` moves the picker and the sign-in/out buttons from `MainWindow.accountFooter`. It sets the
     same model flags: `isShowingICloudSignIn` and `isConfirmingICloudSignOut`. Close the popover first, then set
     the flag, so the sheet or dialog presents from the window.

Acceptance:
- It builds.
- `AccountFooterRow` renders in a preview for every §6.4 state.
- No behaviour changes until A2.

Tests (`AccountFooterContentTests`), one per §6.4 row:
- line 2 strings
- the dot rule (past due, offline, iCloud signed out, Mac needs access → true; Free + connected → false)
- the accessibility value
- `showsUncloudSection == false` for `.off` and signed out

Run `AccountSummaryTests`, `AccountSummaryCopyTests` and `AccountMenuTests`, which should stay unchanged:
`AccountMenuItems` isn't touched.

**A2. Wire it in.** After S2, which edits the same file.

Files: `Uncloud/Views/MainWindow.swift`.

Changes:
1. Delete the `.toolbar { ToolbarItem { AccountButton() } }` block on the sidebar.
2. Replace `accountFooter` and its helpers (`accountTitle`, `accountSubtitle`, `sourceSelection`) with
   `.safeAreaInset(edge: .bottom, spacing: 0) { VStack(spacing: 0) { Divider(); AccountFooterRow() } }`.
3. Keep the sheet and dialog modifiers (`ICloudSignInSheet`, the sign-out confirmation) where they are.
4. Delete `AccountButton` if A1 left it.

Acceptance:
- There's no avatar in the titlebar.
- The bottom row opens the combined popover.
- Sign In / Sign Out of iCloud from the popover open the same sheet and dialog as the File menu.
- The app menu account items and Settings › Account are unchanged.
- VoiceOver reads "Accounts, …" once.
- Tab reaches the row.

Tests: covered by T1's `menu-sidebar-*` and `menu-footer-*` snapshots. Also run `AccountModelTests`.

**Parallelism.** A1 shares no files with S1–S6 and can start once S0 lands, or even before, since it doesn't touch
the builder's files. A2 must follow S2, because both edit `MainWindow.swift`.

### 6.6 Snapshot changes (in T1)

- Replace `menu-popover-*` with `AccountFooterPopover`, covering every popover state plus `icloud-signed-out` and
  `mac-needs-access`.
- Add `menu-footer-row-*` at 240 pt wide.
- The long email (`a.very.long.address…`) must middle-truncate on both lines and in the popover.

---

## 7. R3: static brand header at the top of the sidebar

### 7.1 Design

```
┌──────────────────────────────┐
│ ● ● ●                  [⊟]   │  titlebar / toolbar row (system): traffic lights, sidebar toggle
│                              │
│ [▣]  Uncloud                 │  SidebarBrandHeader: icon 28 pt + wordmark 16 pt tall (≈80 pt wide)
│                              │  12 pt below, then the first row
│ ☁  Cloud Library             │
```

- **Icon.** `AppLogo(size: 28)` is the static Dock icon. **Not** `AnimatedAppLogo` and **not** `AppLockup`, which is
  animated.
- **Wordmark.** `Wordmark(width: 80)`. The SVG's aspect is 3825 : 769 ≈ 4.97, so 80 pt wide is about 16 pt tall,
  roughly the cap height of a 17 pt title next to a 28 pt icon. It uses the ink colour (`.primary`), never a
  gradient, per brand/README. The icon carries the colour.
- **Spacing.**
  - The gap between icon and wordmark is 8 pt, about 0.28 × the icon. A side-by-side lock-up needs more room than
    the stacked 12%.
  - The vertical centres line up.
  - Leading padding matches the sidebar row label inset: 10 pt on macOS 26, 12 pt on 14, using
    `.padding(.leading, Tokens.Space.m)`. Check it against the row icons in the snapshot.
  - Padding is 8 pt on top and 12 pt on the bottom.
  - Total width is 28 + 8 + 80 + 2 × 12 = 140 pt, which fits the 180 pt minimum sidebar width.
- **Placement.** `.safeAreaInset(edge: .top, spacing: 0)` on the sidebar `List`.
  - The safe area already starts **below** the titlebar / unified toolbar row, so the header can never sit under the
    traffic lights or the sidebar-toggle button. This holds on macOS 14 (52 pt unified toolbar) and on macOS 26,
    where the sidebar is a floating glass panel and its toolbar row is part of it.
  - It is not a `Section` header, so it never scrolls.
  - It is **not** a toolbar item. A toolbar item would compete with the traffic lights and the toggle, and on
    macOS 26 it would get a glass capsule.
- **Background.** None. The sidebar material or glass shows through, so it looks right in light and dark mode on both
  OS versions. Five rows never scroll under it at the 500 pt minimum height: 500 − 52 − 52 header − 60 footer ≈
  336 pt for 5 × 28 pt rows.
- **Collapsed sidebar.** The header lives inside the sidebar column, so it hides with the sidebar and comes back
  with it. Nothing goes in the detail titlebar, where the window title "Cloud Library" etc. stays.
- **Accessibility.** `SidebarBrandHeader` uses `.accessibilityElement(children: .ignore)`,
  `.accessibilityLabel("Uncloud")` and `.accessibilityAddTraits(.isHeader)`, read once. The inner `AppLogo` and
  `Wordmark` labels are swallowed by `.ignore`, so VoiceOver doesn't say "Uncloud, Uncloud". It's not a button and
  does nothing on click. The contrast of `.primary` ink is fine in both modes.
- **Reduce Transparency / Increase Contrast.** Nothing special is needed. The ink colour follows the system.

### 7.2 Code (in S2)

```swift
/// The sidebar's brand header: the static app icon and the wordmark side by side. It sits in the sidebar's top
/// safe-area inset, below the titlebar, so it never meets the traffic lights and never scrolls.
struct SidebarBrandHeader: View {
    var body: some View {
        HStack(spacing: Tokens.Space.s) {
            AppLogo(size: 28)
            Wordmark(width: 80)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Tokens.Space.m)
        .padding(.top, Tokens.Space.s)
        .padding(.bottom, Tokens.Space.m)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Uncloud")
        .accessibilityAddTraits(.isHeader)
    }
}
```

Check: `Tokens.Space.s`/`.m` should be 8/12. If not, use literals.

Add a line to brand/README: "Sidebar lock-up: icon left (28 pt), wordmark right (≈1 : 5, 16 pt tall), gap ≈ 0.28 ×
icon, vertically centred. Static icon only. Ink colour." This depends on D7.

### 7.3 Acceptance and tests

T1 `menu-sidebar-*` and `window-*` snapshots at 1000×700 and 760×500, light and dark. The designer checks:
1. There's a clear gap between the traffic lights and the header.
2. The header doesn't move when the list is scrolled. Use a 400 pt tall test render if the window allows it.
3. The header's leading edge lines up with the row icons.
4. With the sidebar collapsed, there's no header remnant.

For macOS 26, take a manual screenshot on that OS if the CI runner is 14/15. Add a `SidebarBrandHeader` render to
`LogoSnapshotTests`, light and dark, at 240 pt wide.

## Owner decisions (2026-10-22)
Owner: "no need to get approval once the design plan is ready, build it automatically and then the dmg." The coordinator takes every recommendation: D1 yes (window title names the source), D2 not now, D3 status row with "Change…", D4 this session only, D5 yes, D6 yes but separate web work (not in these chunks), D7 yes, D8 yes.
