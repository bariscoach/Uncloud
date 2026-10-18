# Browse Backup: browse by date, and sort by date

Status: plan only. No Swift code was changed. Author: design lead (Opus), 2026-10-18.
Branch: `feature/duplicates-and-icloud-cleanup` (d96c33a).

Owner's request: "in browse photo feature, I'd like to add year month browsing in addition to places (start from the
most recent month, year and then show places. also add sorting options such as list from oldest to newest and newest
to oldest date)".

Builds on `.claude/design/browse-backup-plan.md` (the feature) and `.claude/design/polish-plan.md` (glossary in
section 2, direction in section 1: one prominent thing per screen, colour means status, sentence-case status,
title-case commands, US English, `Plural.photos`, curly quotes, `.help` + `.accessibilityHint` instead of captions).

## 0. How the request is read

- **"year month browsing in addition to places"**: a third view, **Dates**, next to Map and Places in the segmented
  control. It's placed **first**, and it's what Browse Backup opens on.
- **"start from the most recent month, year"**: the Dates list is years, newest first, each one expandable into its
  months. When the pane opens, the **most recent month is selected** and its year is expanded, so photos show at once.
- **"and then show places"**: two readings, and the plan covers both. (a) Places stays as its own view, after Dates.
  (b) Inside a month, the photos are grouped by **day**, and each day's header names the places of that day
  ("Saturday, October 4 · Rome, Florence"), as Photos does. Chunk 2 builds (b). If the owner meant only (a),
  chunk 2 can drop the place subtitle and keep the day headers.
- **"sorting options … oldest to newest and newest to oldest"**: one setting, **Newest First / Oldest First**. It
  applies in every view: to the years and months in Dates, and to the photos in every grid (Dates, Places, and the
  Map inspector). Uncloud remembers it across launches.
- **Not changed:** the Places list stays sorted by photo count (it's a list of places, not of dates). The Map stays as
  it is.

Segment order: **Dates | Map | Places**. Map and Places keep their order, so nobody's habit breaks. The owner may
prefer Dates | Places | Map, since he names places right after dates. Swapping is one line in `Mode.allCases`.

---

## 1. Which date, and what "No Date" means

### What the index already has
`BrowseEntry.date` is already read and stored for every file (`BrowseMetadata.read`). It comes from:
1. **Photos:** EXIF `DateTimeOriginal`, read in the camera's recorded `OffsetTimeOriginal`, or in the Mac's time zone
   at index time when the camera didn't record one (`BrowseMetadata.exifDate`).
2. **Movies:** QuickTime `com.apple.quicktime.creationdate` (an ISO 8601 string with an offset; AVFoundation gives
   the instant).
3. **Fallback:** the Uncloud `.xmp` sidecar's `xmp:CreateDate` / `photoshop:DateCreated`. Uncloud writes it from
   `PHAsset.creationDate`, which is the date the Photos app shows, so it's the most trustworthy fallback.

All three are capture dates. They're reliable for camera photos and movies, and for anything with a sidecar.

### Fallbacks considered
- **File modification time: rejected.** It's not the same thing for both sources. For iCloud Photos, the bridge sets
  mtime to the created date (`photo_bridge.py:595`, `download.update_mtime`). For Photos on This Mac, the engine
  writes files with `PHAssetResourceManager` and never sets mtime, so it's the **export** time. Using it would put a
  whole library into the month it was exported. Leave it out.
- **The month folder: accepted, month precision only.** The By Month, By Album and By Place then Month layouts put
  files in `2024/07/…` or `Italy/Rome/2024-07/…`. `ExportEngine.folderPath` builds those from `PHAsset.creationDate`
  in `Calendar.current`. That's the same source as the sidecar, so a file with no embedded date and no sidecar
  (a PNG screenshot, a GIF, a scanned image exported without sidecars) still has a known month. The rule:
  - Look at the **folder** part of the path (not the file name). The last folder component that matches
    `^\d{4}-\d{2}$`, or the last two components that match `^\d{4}$` then `^\d{2}$`, gives the year and month.
    Accept a year from 1900 to 2100 and a month from 1 to 12, and nothing else.
  - An `Undated` folder, or no match (Flat and By Place layouts, untracked folder names), gives nothing.
  - These photos go in their month. Within the month they sort as if taken at the **start** of the month (first in
    Oldest First, last in Newest First), with the path as the tie-break. Their detail pane still says
    "Date taken: Unknown", because that's the truth.
- **Folder date beats nothing, but never beats a real date.** If the file has a date, the folder is ignored, even
  if they disagree (a photo moved by hand, or a time zone edge).

### No Date
A photo with no date and no month folder goes in **No Date**: the last row of the Dates list, in both sort orders,
with the `calendar.badge.exclamationmark` symbol in secondary colour, as No Location does in Places. Its photos are
sorted by path (there's nothing else to sort by), in both orders.

In the **Places and Map grids**, photos without a date (and without a folder month) also come last, by path, in both
orders. Same rule everywhere: dated photos first in the chosen order, undated at the end.

### Time zones
Group in the **Mac's current calendar and time zone** (`Calendar.autoupdatingCurrent`), at view time.

Why:
- The By Month folders on the drive were named in `Calendar.current` at export time. Grouping the same way makes
  "October 2026" in Browse Backup match the `2026/10` folder on the drive. Users will open Finder side by side.
- `BrowseEntry.date` is an absolute instant. The capture's own offset isn't stored, so "wall-clock time where it was
  taken" isn't available without new data.

The known edge case: a photo taken at 00:30 on November 1 in Tokyo (+09:00) shows under **October** on a Mac set to
New York (it was 11:30 on October 31 there). Photos.app would say November 1. That's a rare edge (the last or first
hours of a month, taken far from home), and it matches the folders. The plan accepts it.

If it's needed later: add `utcOffset: Int?` (seconds) to `BrowseEntry`, filled from `OffsetTimeOriginal` and the
QuickTime date string. Since it's optional, the synthesized `Codable` decodes old indexes without it (as nil), so no
version bump is needed. Old entries keep grouping in the Mac's zone until their file changes. **Not in this plan.**

A change of the Mac's time zone (travel, DST) regroups on the next rebuild, with `autoupdatingCurrent`. That's
expected.

### Index changes
**None.** No new field, no version bump, no re-read. The date is already stored, and the folder month comes from the
path. That matters: a version bump makes `BrowseIndexStore.load` return `[:]`, and 90,000 files over USB get read
again from scratch.

Optional, low risk, no bump (chunk 1 may do it if there's time): in `BrowseMetadata.movieMetadata`, fall back to
`AVMetadataItem` `.commonIdentifierCreationDate` when the QuickTime creation date is missing (some non-Apple
cameras). It only helps files read from now on, and that's fine.

---

## 2. UX spec

### 2.1 Toolbar
```
[ Dates | Map | Places ]          (principal, segmented)                [↑↓ Sort ▾]  [🔍 Search …]
```
- **Mode picker**: `Picker("View", …)`, segmented, titles **Dates**, **Map**, **Places**. Help:
  "Show the photos by date, on a map, or as a list of places". Keep `.accessibilityLabel("View")`.
- **Sort menu**: a `Menu` with `Label("Sort", systemImage: "arrow.up.arrow.down")`, icon-only in the toolbar. It holds
  an inline `Picker` with **Newest First** and **Oldest First** (so the current one has a checkmark, as Photos From
  does in the File menu). `.help("Sort photos by date")`, `.accessibilityLabel("Sort")`,
  `.accessibilityValue(sortOrder.title)`. Shown in every view. It's `ToolbarItem(placement: .automatic)`, so it sits
  just before the search field.
- **Search**: the field stays. Its prompt follows the view: **Search months** in Dates, **Search places** in Map and
  Places. In Dates, it filters the month rows by their full title ("October 2026"), with `localizedStandardContains`.
  "oct" finds every October, "2024" finds every month of 2024. A year shows when any of its months match, and it's
  expanded while a search is active. No Date never matches a search.

### 2.2 Menu bar
In the **View** menu, after the pane items (inside the existing `CommandGroup(before: .sidebar)`, after its Divider):
```
View   Library ⌘1 | Backup ⌘2 | Browse Backup ⌘3 | Clean Up iCloud ⌘4 | —
       Sort ▸  ✓ Newest First
                 Oldest First
       — | Show/Hide Sidebar ⌃⌘S
```
- `Menu("Sort") { Picker("Sort", selection: …) { … }.pickerStyle(.inline) }`, the pattern `Photos From` already uses.
- **Disabled, not hidden**, when `model.pane != .browse` (HIG; polish plan section 4).
- No keyboard shortcut. ⌘↑/⌘↓ already mean things in lists, and the choice isn't a frequent action.
- It binds to `tools.browse.sortOrder`, so the menu, the toolbar and the setting are one value.

### 2.3 Dates view
```
┌ sidebar list (220–320 pt) ──────┐┌ grid ─────────────────────────────────────────┐
│ ▾ 2026                   3,412  ││ Saturday, October 18 · Rome          (chunk 2)  │
│     October                312  ││ ▢ ▢ ▢ ▢ ▢ ▢ ▢                                  │
│     September              904  ││ Friday, October 17                              │
│     …                           ││ ▢ ▢ ▢                                           │
│ ▸ 2025                  10,288  ││                                                 │
│ ▸ 2024                   9,870  ││                                                 │
│ 􀉉 No Date                  41  ││──── detail pane (one photo selected) ──────────│
└─────────────────────────────────┘└─────────────────────────────────────────────────┘
```
- The same split as Places: a `.sidebar`-style `List` on the left, the existing photo grid and detail pane on the
  right.
- **Year row**: the year ("2026", never "2,026": build it with `String(year)`, not `formatted()`), then the count in
  secondary `monospacedDigit`, like `PlaceRow`. Expandable with a disclosure triangle. **Selecting a year** shows the
  whole year's photos.
- **Month row**, indented under its year: the month's name alone ("October"), localized with the month format style
  (`Date.FormatStyle().month(.wide)` in the grouping calendar, from the first day of the month), then the count. The
  year isn't repeated, since the parent row shows it. Its accessibility label is "October 2026, 312 photos".
- **No Date row**: last, outside any year, `Label("No Date", systemImage: "calendar.badge.exclamationmark")` in
  secondary, then the count. Only shown when it isn't empty.
- **Order**: Newest First lists years newest to oldest and months December to January within each year. Oldest First
  is the exact reverse. No Date is last in both.
- **Expansion**: the selected month's year is expanded when the view opens. The user can expand and collapse the rest;
  that state is kept for the session (not saved).
- **Initial selection**: when nothing is selected yet, the **first month in the list** is selected: the most recent
  month in Newest First, the oldest in Oldest First. If there are no dated photos at all, No Date is selected.
  - While the user hasn't picked a row, this automatic choice **follows the index** as it grows. The indexer reads
    paths in sorted order (oldest folders first), so the first partial snapshot's "most recent month" is old. Each
    rebuild re-applies the automatic choice until the user clicks a row. After that, the user's row stays.
  - If the selected row disappears (its photos were deleted and the index refreshed), go back to the automatic choice.
  - Changing the sort order keeps the selected row, and scrolls the list to it (`ScrollViewReader.scrollTo`).
- **Selecting a row** clears the photo selection (`selectedPaths = []`), so the detail pane never shows a photo from
  another month.
- **Grid content**: the row's photos in the sort order. Chunk 1 shows them as one flat grid. Chunk 2 adds headers:
  - a **month** row: one section per **day**. The header is the day as "Saturday, October 18"
    (`.weekday(.wide).month(.wide).day()`), then " · " and that day's place names when they're known (up to two,
    then "and 3 more"; nothing for a day with no located photos). Header font `.headline`, place names `.callout`
    secondary.
  - a **year** row: one section per **month** ("October"), with its count in secondary.
  - **No Date**: no headers, one flat grid.
  Day and month sections follow the sort order, and so do the photos inside them. Headers are pinned
  (`pinnedViews: [.sectionHeaders]`) on the `.bar` material, so the current day stays visible while scrolling.
- **Place names in day headers** use `BrowseBackup.requestNames(for:)` only for the cells of the **selected month**
  (a few cells at most), when the month is selected. It respects `PlaceResolver`'s rate limit, as the map does.
  Offline, the header has no place names: no coordinates in a day header, it's too noisy.

### 2.4 Places and Map
- Unchanged, except that the **photos in the grid** (Places) and **in the inspector** (Map) follow the sort order, with
  undated photos last.
- The Places list stays sorted by count, with No Location last.

### 2.5 Keyboard
- The Dates list is a sidebar `List`, which macOS backs with an outline view: ↑/↓ move the selection, → expands a year,
  ← collapses it (and moves from a month to its year), and type-select works on the row titles. No custom key code.
- Tab moves focus from the list to the grid. In the grid, Space opens Quick Look, ⌘A selects all, as today. Quick
  Look pages through the grid in the sort order, since it gets the grid's paths in order.
- Arrow keys inside the photo grid are out of scope (it doesn't have them today in any view).

### 2.6 Strings
Status is sentence case, commands and titles are title case. "photo/photos" through `Plural.photos`.

| Where | String |
|---|---|
| Mode titles | Dates · Map · Places |
| Mode picker help | Show the photos by date, on a map, or as a list of places |
| Sort menu and toolbar | Sort · Newest First · Oldest First |
| Sort help | Sort photos by date |
| Search prompt (Dates) | Search months |
| Search prompt (Map, Places) | Search places (unchanged) |
| No Date row | No Date |
| Month row accessibility | October 2026, 312 photos (via `Plural.photos`: "1 photo") |
| Year row accessibility | 2026, 3,412 photos |
| Grid placeholder (Dates, nothing selected) | **Select a Month** / Select a month to see its photos. |
| No dated photos (Dates list overlay, not indexing, only No Date exists) | none: No Date is simply the only row, and it's selected |
| No search results (Dates) | `ContentUnavailableView.search(text: query)` in the list |
| No Folder description | Choose a backup folder to browse your photos by date and place. |
| Nothing to Browse description | Export some photos, then see when and where they were taken. |
| Nothing to Browse symbol | `photo.on.rectangle.angled` (was `map`, which no longer describes the first view) |
| Indexing banner and spinner | Reading photos… 12,340 of 48,312 (was "Reading locations…"; it reads dates too) |
| Day header | Saturday, October 18 · Rome, Florence · (chunk 2) |
| Year grid section header | October · 312 photos (chunk 2) |

"Opening your backup…" and "Paused while an export runs" are unchanged.

### 2.7 Accessibility
- Every row is one element (`.accessibilityElement(children: .combine)`) with the labels in 2.6. No extra hints: the
  disclosure triangle already announces "collapsed" or "expanded".
- The sort menu announces its value ("Sort, Newest First").
- Day and month section headers get `.accessibilityAddTraits(.isHeader)`, so VoiceOver's heading rotor jumps by day.
- The No Date symbol is decorative next to its text (`Label` handles that). Status never relies on colour.
- No new animation. If chunk 2 animates anything (it shouldn't need to), use `Tokens.Motion.animation(reduceMotion)`.
- The grid's existing `.accessibilityLabel("Photos, N")` stays.

---

## 3. Data and model changes, by file

### 3.1 New: `Uncloud/Model/BrowseDates.swift` (pure, no I/O, `Sendable`, testable without a drive)
```swift
enum BrowseSortOrder: String, CaseIterable, Identifiable, Sendable {
    case newestFirst, oldestFirst            // raw values are the stored setting
    var id: Self { self }
    var title: String                        // "Newest First" / "Oldest First"
    static let defaultsKey = "browseSortOrder"
}

struct BrowseMonth: Identifiable, Equatable, Sendable {
    let year: Int, month: Int                // calendar components in the grouping calendar
    let start: Date                          // first instant of the month, for titles and the folder-month sort key
    var id: String                           // "month:2026-10"
    var paths: [String]                      // oldest first (stored ascending; the order is applied when read)
    var count: Int { paths.count }
}

struct BrowseYear: Identifiable, Equatable, Sendable {
    let year: Int
    var id: String                           // "year:2026"
    var months: [BrowseMonth]                // January first
    var count: Int
}

/// The Dates view's data, built once per index change. Everything is stored oldest first; `BrowseSortOrder`
/// reverses at read time, which is O(n) and cheap.
struct BrowseTimeline: Equatable, Sendable {
    var years: [BrowseYear] = []             // oldest first
    var noDate: [String] = []                // by path
    /// Each path's place in the whole backup, oldest first. Dated and folder-month photos get 0..<n; No Date photos get
    /// none. Used to sort any set of paths (a place, a map selection) without re-reading dates.
    var rank: [String: Int] = [:]
    static let noDateID = "no-date"

    func years(_ order: BrowseSortOrder) -> [BrowseYear]          // years and their months in that order
    func paths(forRowID id: String, order: BrowseSortOrder) -> [String]   // year, month or no-date
    func firstRowID(_ order: BrowseSortOrder) -> String?          // the automatic selection: first month, else no-date
    func yearID(containing rowID: String) -> String?              // for expanding the selected month's year
    func filtered(_ query: String, calendar: Calendar, locale: Locale) -> BrowseTimeline   // Search months
}

enum BrowseDates {
    /// Builds the timeline. Sort once by (key, path), then walk the sorted list, computing a month boundary only when
    /// the walk crosses one: about one calendar call per month, not per photo. 90k entries ≈ one sort.
    static func timeline(from entries: [BrowseEntry], calendar: Calendar) -> BrowseTimeline
    /// The sort key: the date, or the start of the folder month, or nil (No Date).
    static func sortDate(for entry: BrowseEntry, calendar: Calendar) -> Date?
    /// (2024, 7) from "2024/07/IMG.jpg" or "Italy/Rome/2024-07/IMG.jpg". Folder part only; 1900...2100, 1...12.
    static func folderMonth(_ path: String) -> (year: Int, month: Int)?
    /// Orders paths by rank in the given order; paths without a rank go last, by path, in both orders.
    static func sorted(_ paths: [String], rank: [String: Int], order: BrowseSortOrder) -> [String]
    static func monthTitle(_ month: BrowseMonth, calendar: Calendar, locale: Locale) -> String       // "October"
    static func fullMonthTitle(_ month: BrowseMonth, calendar: Calendar, locale: Locale) -> String   // "October 2026"
    static func yearTitle(_ year: Int) -> String                                                      // "2026"
}
```
Rules the tests pin down:
- Ties (bursts, the same second) break by path ascending; Newest First is the **exact reverse** of Oldest First for
  dated photos. Undated photos are last by path in both.
- A month row exists only when it has photos. A year exists only when one of its months does.
- `rank` covers dated and folder-month photos only.

Chunk 2 adds, in the same file:
```swift
struct BrowseDaySection: Identifiable, Equatable, Sendable { let id: String /* "day:2026-10-18" */; let start: Date; var paths: [String] }
extension BrowseDates {
    /// A month's paths split by calendar day, in the given order. Folder-month photos (no time) form a last section
    /// titled with the month, e.g. "October 2026", in both orders.
    static func days(of month: BrowseMonth, entries: [String: BrowseEntry], calendar: Calendar, order: BrowseSortOrder) -> [BrowseDaySection]
    /// A year's months as sections, in the given order.
    static func monthSections(of year: BrowseYear, order: BrowseSortOrder) -> [BrowseMonth]
    /// "Rome, Florence", "Rome, Florence and 3 more", or nil: the distinct known place titles of a day, in photo order.
    static func placeSummary(_ titles: [String]) -> String?
}
```

### 3.2 `Uncloud/Model/BrowseBackup.swift`
- `Mode`: add `case dates` **first**; `title` "Dates". `var mode: Mode = .dates`. Mode isn't saved: the pane always
  opens on Dates, as asked.
- New state:
  - `var sortOrder: BrowseSortOrder` with `didSet { defaults.set(sortOrder.rawValue, forKey: BrowseSortOrder.defaultsKey) }`,
    read in `init`. Default `.newestFirst`.
  - `private(set) var timeline = BrowseTimeline()`.
  - `var selectedDateID: String?` (a year, month or `no-date` ID). `didSet`: when it's set by the user (not by the
    automatic choice), `dateSelectionIsAutomatic = false`; and in both cases `selectedPaths = []`.
  - `@ObservationIgnored private var dateSelectionIsAutomatic = true`.
  - `var expandedYears: Set<String> = []`.
  - `@ObservationIgnored private let calendar: Calendar` (init param, default `.autoupdatingCurrent`; tests pass a
    fixed time zone).
  - `@ObservationIgnored private let defaults: UserDefaults` (init param, default `.standard`; tests pass a suite).
- `init(store:namer:isExportRunning:)` gains `calendar: Calendar = .autoupdatingCurrent` and
  `defaults: UserDefaults = .standard`, both defaulted, so `BackupTools` and every test call keep compiling.
- `rebuild()`: the cells and No Location work stays as it is (main actor, unchanged). The **timeline** is built off the
  main actor:
  ```swift
  timelineGeneration += 1; let generation = timelineGeneration
  let list = entryList, calendar = calendar
  timelineTask?.cancel()
  timelineTask = Task { [weak self] in
      let built = await Task.detached(priority: .userInitiated) { BrowseDates.timeline(from: list, calendar: calendar) }.value
      guard let self, generation == self.timelineGeneration else { return }
      self.applyTimeline(built)
  }
  ```
  `applyTimeline` sets `timeline`, clears `gridCache`, then applies the automatic selection: if
  `dateSelectionIsAutomatic` or the selected ID is no longer in the timeline, set it (without clearing the flag) to
  `timeline.firstRowID(sortOrder)` and insert its year into `expandedYears`.
  - `load(entries:…)` (previews and tests) builds the timeline **synchronously** instead, so snapshots and tests don't
    have to wait. Put the shared part in one `applyTimeline`.
  - Add `private(set) var isBuildingTimeline = false` so the view shows the spinner instead of "Select a Month" in the
    gap before the first timeline arrives.
- `gridPaths` becomes sorted, and memoized because it's read in `body`:
  - `.dates`: `timeline.paths(forRowID: selectedDateID, order: sortOrder)`.
  - `.places`: `BrowseDates.sorted(group.paths, rank: timeline.rank, order: sortOrder)`.
  - `.map`: the selected cells' paths, then `BrowseDates.sorted(…)`.
  - Memo: `@ObservationIgnored private var gridCache: (key: GridKey, paths: [String])?`, where `GridKey` is
    `(mode, selectedDateID, selectedGroupID, mapSelection, sortOrder, timelineGeneration, groupsGeneration)`. Reading
    the observed properties inside the getter keeps observation working; only the cache itself is ignored.
- `visibleTimeline`: `query.isEmpty ? timeline : timeline.filtered(query, calendar:locale:)`; while a query is active
  the view treats every visible year as expanded.
- `update(destination:…)` on a destination change also resets `selectedDateID = nil`,
  `dateSelectionIsAutomatic = true`, `expandedYears = []`, `timeline = BrowseTimeline()`.
- Chunk 2 adds `daySections: [BrowseDaySection]` / `monthSections` for the selected row (memoized the same way) and
  `func requestNamesForSelectedMonth()`, which collects the cell keys of the month's located photos and calls
  `requestNames(for:)`.
- `BrowseSortOrder` changes don't rebuild anything: everything reads the timeline in the requested order.

### 3.3 `Uncloud/Views/BrowseBackupView.swift`
- `loaded`: add `case .dates: datesLayout(browse, destination:)`.
- `datesLayout`: `HStack { List(selection: Bindable(browse).selectedDateID) { … } ; Divider(); photos(…) }` with the
  same frame as Places.
  - Each year: `DisclosureGroup(isExpanded: binding(for: year.id)) { ForEach(months) { MonthRow().tag(month.id) } }
    label: { YearRow().tag(year.id) }`. A tagged DisclosureGroup label is selectable in a macOS sidebar list.
    **Verify in the app.** If the label isn't selectable on macOS 14, fall back to `Section(isExpanded:)` per year
    with an "All of 2026" first row tagged `year:2026`, and note it in the PR.
  - `ScrollViewReader` scrolls to `selectedDateID` on appear and when `sortOrder` changes.
  - Overlay: while `isBuildingTimeline` or indexing with an empty timeline, the existing spinner
    (`noLocatedPhotos` → rename to `readingOverlay` / reuse `readingText`). Search with no match:
    `ContentUnavailableView.search(text:)`.
- `photos(…)`: the placeholder title and text depend on the mode: Dates "Select a Month" / "Select a month to see its
  photos."; Map and Places unchanged.
- Toolbar: add the sort `Menu` (2.1). The `.searchable` prompt follows the mode.
- Strings from 2.6 (No Folder, Nothing to Browse and its symbol, mode help, "Reading photos…" in `readingText` and
  `IndexingBanner.text`).
- New private views `YearRow`, `MonthRow`, `NoDateRow`, styled like `PlaceRow`.
- `BrowseBackupView(browse:syncsDestination:)` keeps its exact init (snapshots call it). `IndexingBanner(progress:isPaused:)`
  too.

### 3.4 `Uncloud/Views/BrowsePhotoViews.swift` (chunk 2)
- `BrowsePhotoGrid` gains `var sections: [BrowsePhotoSection]? = nil` (defaulted, so the existing call compiles).
  `BrowsePhotoSection { id, title, subtitle: String?, paths }`. With sections, the `LazyVGrid` uses
  `Section { tiles } header: { BrowseSectionHeader(...) }` and `pinnedViews: [.sectionHeaders]`. `paths` stays the
  flat, ordered list, so ⌘A, Space and Quick Look keep working across sections unchanged.
- `BrowseSectionHeader`: title `.headline`, subtitle `.callout` secondary, padding `Tokens.Space.s`/`.m`, background
  `.bar`, `.accessibilityAddTraits(.isHeader)`.

### 3.5 `Uncloud/App/ExportCommands.swift`
- The View menu's Sort submenu (2.2), bound to `tools.browse.sortOrder`, disabled unless `model.pane == .browse`.

### 3.6 Not changed
`BrowseIndex.swift` (no field, no version bump), `PlaceResolver`, `BrowseMapView`, `BackupTools` (the defaulted
init params mean no change), Export logic, the manifest.

### 3.7 Performance (90k photos)
- Timeline build: one `sorted` of ~90k `(Date, String)` pairs plus one pass, off the main actor at
  `.userInitiated`. Calendar calls are per month boundary (a few hundred), not per photo. Expect well under 100 ms on
  Apple silicon. It reruns on each partial snapshot (every 1,000 files) during indexing, superseded by generation, so
  a slow build never applies stale data.
- `folderMonth` is a string split on the folder part, only for entries without a date.
- `rank` is a `[String: Int]` of ~90k: built in the same pass. Sorting a 20k-photo place by rank is ~300k dictionary
  lookups, memoized per selection.
- `years(order)` / `paths(order)` reverse arrays of at most a year's photos. No view does work proportional to the
  whole library in `body`.
- Chunk 2's day split runs on one month's photos (hundreds to a few thousand), memoized: main actor is fine.
- Add one test that builds a timeline from 90,000 synthetic entries and checks it finishes (a loose bound, 2 s, to
  catch an accidental O(n²) rather than to benchmark).

---

## 4. Test plan

### 4.1 New `UncloudTests/BrowseDatesTests.swift` (Swift Testing, `@Suite("BrowseDates")`)
All use a calendar with a **fixed** time zone (`TimeZone(identifier: "Europe/Rome")` or `"America/New_York"`) and
`Locale(identifier: "en_US")`, never the test machine's.

Grouping
1. Groups entries into years and months, oldest first in storage; counts are right; empty months don't appear.
2. A year with photos in only March has exactly one month.
3. `years(.newestFirst)` is newest year first and December→January within it; `.oldestFirst` is the exact reverse.
4. No Date: entries without a date and without a folder month go to `noDate`, sorted by path; `firstRowID` returns
   `no-date` when there are no dated photos; No Date isn't in `rank`.
5. Folder month: `folderMonth` reads `2024/07/a.jpg`, `Italy/Rome/2024-07/a.jpg`, `Album/2024/07/a.jpg`; rejects
   `Undated/a.jpg`, `a.jpg`, `2024/13/a.jpg`, `1850/01/a.jpg`, `Photos 2024-07.jpg` (file name, not folder),
   `2024-07/sub/a.jpg` only when no later component matches (last match wins).
6. A dated entry in a folder for another month is grouped by its date, not the folder.
7. A folder-month entry sorts at the start of its month: first in Oldest First, last in Newest First, path tie-break.

Sorting
8. `sorted(_:rank:order:)`: dated in order, undated last by path, in both orders.
9. Equal dates break by path ascending; Newest First reverses the dated part exactly.
10. `paths(forRowID:)` for a year row returns all its months in order; for a month row, the month; for `no-date`, the
    undated paths in path order in **both** orders.

Time zones
11. 2026-10-31 23:30 +01:00 (22:30 UTC) is October in Europe/Rome and October in New York; 2026-11-01 00:30 +09:00
    (2026-10-31 15:30 UTC) is **October** with a New York calendar and **November** with an Asia/Tokyo calendar.
    (Pins the documented "Mac's time zone" rule.)
12. DST: 2026-03-29 02:30 local in Europe/Rome (the skipped hour) and 2026-10-25 02:30 (the repeated hour) land in
    March and October.
13. New Year: 2026-12-31 23:59:59 and 2027-01-01 00:00:00 local land in different years.
14. A pre-1970 date (1965-06-01) and a far-future one (2099-12-31) group correctly.

Titles
15. `yearTitle(2026) == "2026"` (no grouping separator, also with `Locale(identifier: "de_DE")` in scope).
16. `monthTitle` is "October" in en_US and "octobre" in fr_FR; `fullMonthTitle` is "October 2026".
17. `filtered("oct")` keeps every October and their years; `filtered("2024")` keeps every month of 2024; No Date is
    dropped from a filtered timeline.

Scale
18. 90,000 synthetic entries (dates spread over 15 years, 2% undated, 3% folder-month only) build in under 2 s and
    produce consistent counts (the sum of years plus No Date equals the entry count).

Chunk 2 (same file)
19. `days(of:)` splits a month by local day in the given order; a day crossing midnight in UTC but not locally stays
    one day; folder-month photos form the last section in both orders.
20. `placeSummary`: `["Rome"]` → "Rome"; duplicates collapse; `["Rome","Florence","Pisa","Siena","Lucca"]` →
    "Rome, Florence and 3 more"; `[]` → nil.

### 4.2 Additions to `UncloudTests/BrowseBackupTests.swift` (`@MainActor`, through `load(entries:…)`)
21. A new model opens in `.dates`, and after `load` the most recent month is selected and its year is expanded.
22. With `sortOrder = .oldestFirst` set before `load`, the oldest month is selected.
23. Automatic selection follows the index: load an old month, then load again with a newer month: the newer one is
    selected. After the user sets `selectedDateID`, a later load keeps it.
24. A selected month that disappears falls back to the automatic choice.
25. Changing `selectedDateID` clears `selectedPaths`.
26. `gridPaths` in Places and in Map follow `sortOrder`, with undated paths last.
27. `sortOrder` is saved to and read from the injected `UserDefaults` suite (a second model with the same suite starts
    with Oldest First); an unknown stored raw value falls back to Newest First.
28. Changing the destination resets the date selection and expansion.
29. The asynchronous path: `indexingFillsThePlacesFromTheDrive` style, with a dated JPEG
    (`dateTimeOriginal: "2024:07:04 18:30:00"`), checks `timeline.years.first?.year == 2024` after indexing finishes
    (poll `isBuildingTimeline` like the existing test polls `isIndexing`).

Existing tests keep passing unchanged: none asserts `gridPaths` order, the default mode, or "Reading locations…".

### 4.3 `UncloudTests/BrowseBackupSnapshotTests.swift`
- Give the fixture spread dates: Rome photos in October 2026 over two days, Sydney in September 2026, Kyoto in
  March 2025, plus the two screenshots without dates (No Date), plus one entry under `2024/07/` with no date
  (folder month). Keep `romeGroupID` and the existing images.
- New images, light and dark, 1,000 × 700:
  - `dates-<scheme>`: Dates, Newest First, the automatic selection (October 2026), 2026 expanded.
  - `dates-oldest-<scheme>`: Oldest First, a month selected, the list reversed.
  - `dates-year-<scheme>`: the 2026 year row selected (chunk 2: month sections).
  - `dates-nodate-<scheme>`: No Date selected, one photo selected, the detail pane showing "Date taken: Unknown".
  - `dates-search-<scheme>`: query "zzz" (the search empty state).
  - chunk 2: `dates-days-<scheme>`: October 2026 with day headers "Sunday, October 18 · Italy › Rome" style.
- The existing `map-*` and `places-*` images now set `browse.mode` explicitly (they do already).
- Run with `UNCLOUD_BROWSE_SNAPSHOTS=1`, export with `xcrun xcresulttool` into
  `scratchpad/browse-snapshots/` as before, and look at every image in both schemes.

---

## 5. Build chunks

Two chunks, **in order** (chunk 2 edits files chunk 1 edits). Each Haiku engineer works in its own worktree and
follows the shared rules from polish-plan section 6: Swift 6 strict concurrency, macOS 14 target, no new
`@unchecked Sendable` in app code, `xcodegen generate` after adding files, keep the inits tests use, run only your own
test files while developing, then the Browse suites once at the end. No change to `Uncloud/Export/**` except the
optional movie date fallback in 1.

### Chunk 1: Dates view and sort order (model, list, flat grid, menu)
**Owns:** `Uncloud/Model/BrowseDates.swift` (new), `Uncloud/Model/BrowseBackup.swift`,
`Uncloud/Views/BrowseBackupView.swift`, `Uncloud/App/ExportCommands.swift`, `UncloudTests/BrowseDatesTests.swift`
(new), `UncloudTests/BrowseBackupTests.swift`, `UncloudTests/BrowseBackupSnapshotTests.swift`. Optional:
`Uncloud/Export/BrowseMetadata.swift` (movie `commonIdentifierCreationDate` fallback only).

**Does:** sections 1, 2.1–2.7 except day/month section headers, 3.1 (without the chunk 2 additions), 3.2 (without
chunk 2), 3.3, 3.5. Tests 1–18 and 21–29; the snapshot fixture and images except `dates-days`.

**Acceptance:**
- Browse Backup opens on **Dates** with the most recent month selected and its year expanded, on a real drive while it
  indexes (the selection moves forward as the index grows, and stops moving once the user clicks a row).
- Years and months list in the chosen order; No Date last in both; counts add up to the indexed total.
- Sort in the toolbar and in View › Sort shows the same checkmark, changes Dates, Places and Map grids at once, is
  disabled in the View menu outside Browse Backup, and survives a relaunch.
- Arrow keys, → / ←, and type-select work in the Dates list; Tab reaches the grid; Space opens Quick Look in the sort
  order.
- No index version bump; an existing index loads without a re-read (check the banner doesn't show
  "Reading photos… 0 of N" from scratch on a drive that was indexed before).
- The main actor isn't blocked: with a 90k-entry index loaded (or the scale test's synthetic set through `load`),
  switching sort order and selecting a year respond without a visible stall.
- All strings as in 2.6, sentence and title case as in polish-plan section 1.
- `BrowseDatesTests`, `BrowseBackupTests` pass; snapshots rendered and reviewed in light and dark.

### Chunk 2: Day and month sections, places in day headers
**Owns:** `Uncloud/Views/BrowsePhotoViews.swift`, `Uncloud/Model/BrowseDates.swift` (adds 3.1's chunk 2 part),
`Uncloud/Model/BrowseBackup.swift` (adds `daySections`, `monthSections`, `requestNamesForSelectedMonth`),
`Uncloud/Views/BrowseBackupView.swift` (passes sections to the grid in Dates), `UncloudTests/BrowseDatesTests.swift`
(tests 19–20), `UncloudTests/BrowseBackupSnapshotTests.swift` (`dates-days`).

**Does:** 2.3's section headers, 3.4, the place summary.

**Acceptance:**
- A month shows one pinned header per day in the sort order; a year shows one per month; No Date, Places and Map
  stay flat.
- Day headers show known place names for that day (at most two, then "and N more"), and nothing when offline or
  unlocated. Only the selected month's cells are looked up.
- ⌘A, Space, double-click and the context menu work across sections exactly as in a flat grid; Quick Look pages in
  the grid's order across days.
- VoiceOver's heading rotor moves by day header.
- `BrowsePhotoGrid(paths:destination:selection:locationText:)` still compiles unchanged at every existing call site.
- Tests 19–20 pass; `dates-days` snapshot reviewed in light and dark; the full suite passes, run alone, after both
  chunks merge (orchestrator).

---

## 6. Open questions for the owner
1. Segment order: Dates | Map | Places (plan) or Dates | Places | Map?
2. With Oldest First, should Browse Backup still open on the **most recent** month (scrolled to the bottom), or on the
   oldest (the top of the list)? The plan opens on the first row of the list, so Oldest First opens on the oldest.
3. Is "show places" after dates satisfied by the day headers with place names (chunk 2), or did you mean something
   else, such as Year › Month › Place in the list?

## 7. Not verified
- Whether a tagged `DisclosureGroup` label is selectable in a macOS 14 sidebar `List` (fallback in 3.3).
- Whether pinned section headers in a `LazyVGrid` render on `.bar` cleanly under the macOS 26 glass toolbar.
- Exact timeline build time on a real 90k drive (the scale test only guards against O(n²)).
