# Uncloud: design plan (phase 1, review and plan only)

Scope: the flow, menus and colour of the macOS app, plus two new features: the full-library browser with selection, and "Export All Photos". No repository files were edited in this phase.

Sources read: App/UncloudApp.swift, App/ExportCommands.swift, Views/*.swift (ContentView, Welcome, Onboarding, Connect, PhotosAccess, Home, Overview, Setup, Export, ExportControls, ProgressCard, ActivitySection, DestinationHeader, LibrarySourceSection, MenuBarContent, SettingsView, BackupToolSheets, ICloudSignInSheet, VerifyBackupSheet, FreeUpSpaceSheet), Model/ExportModel.swift, Model/BackupTools.swift, Model/FolderLayout.swift, Model/LibrarySource.swift, Model/AutoBackupSettings.swift, Model/LibrarySelection.swift, project.yml.

Note: no asset catalog exists (no Assets.xcassets under Uncloud/, and project.yml has no asset settings). The app has no AppIcon and no AccentColor yet.

---

## 1. Inventory of the current app

### 1.1 Screens (ContentView switches on ExportModel.Step)

| # | Screen | File | Purpose | Actions |
|---|---|---|---|---|
| 1 | Welcome | Views/WelcomeView.swift | First-run intro | Get Started (default action, starts carousel), Skip Introduction (finishes onboarding) |
| 2 | Onboarding carousel, 4 pages | Views/OnboardingView.swift, Model/OnboardingPage.swift | Explains source, folders, resume, privacy | Skip (hidden with opacity 0 on last page, still in the accessibility tree), Back, Next/Continue (default action), arrow keys, PageIndicator (display only) |
| 3 | Connect | Views/ConnectView.swift | Choose iCloud or Photos on this Mac | Sign In… (opens iCloud sheet), Use Photos Library (system permission prompt), Open Photos (footer) |
| 3a | Photos access blocked | Views/PhotosAccessView.swift | Permission denied or restricted | Open Settings |
| 4 | Home (dashboard) | Views/HomeView.swift | Account, backup folder, status, and a 2x3 grid of actions | Source segmented picker, Sign Out…, Sign In…, Allow Access…, Open Privacy Settings…, Choose Folder…, Browse Library, Export Photos / Resume Export / Show Export, Verify Backup…, Free Up Space… (Photos only), Settings… (SettingsLink), Show Introduction |
| 5 | Overview | Views/OverviewView.swift | Item count and a 249-item non-interactive mosaic | Continue (default action). Also: Sign In… and Try Again on errors, Open Apple Account Settings, Open iCloud.com, Open Photos (empty library) |
| 6 | Setup | Views/SetupView.swift | Destination, folder layout, XMP toggle | Source picker and Sign Out (duplicate of Home and Settings), Choose…, layout radio group, Save metadata files toggle, Start Export / Resume |
| 7 | Export | Views/ExportView.swift | Progress, controls, Activity log | Show in Finder (magnifier icon), Choose…, Cancel, Pause, Start/Resume, Verify Backup…, Free Up Space…, Activity disclosure |

Other sheets and windows:
- ICloudSignInSheet: Apple ID, password, Remember password toggle, Cancel (⌘.), Sign In (default), 2FA code, device picker, Verify (default).
- VerifyBackupSheet: Check Backup, Cancel, Delete Files and Export Again (destructive, confirmation), Re-export, Done, Try Again.
- FreeUpSpaceSheet: age picker, Keep favorites, Keep hidden, Find Items…, Remove N Items (destructive), Cancel, Done.
- Settings window (⌘,), SettingsView: Source section (duplicate), Automatic Backup (two toggles, status text, menu bar note), General (Open at login, Show in menu bar).
- Menu bar extra, MenuBarContent: status line (disabled), Back Up Now, Open Uncloud, Settings…, Quit (⌘Q). Visible only when showInMenuBar and automatic backup are on.

### 1.2 Menus and commands (App/ExportCommands.swift, UncloudApp.swift)

| Menu | Item | Shortcut | Enabled when |
|---|---|---|---|
| App | About, Quit, Services (system) | ⌘Q (system) | always |
| App | Settings… | ⌘, (SwiftUI Settings scene) | always |
| File (newItem replaced) | Choose Destination… | ⌘O | not exporting |
| Go | Back | ⌘[ | canGoBack |
| Go | Forward | ⌘] | canGoForward |
| Go | Home | ⇧⌘H | canGoHome |
| Go | Sign Out of iCloud… | none | signed in and not exporting |
| Export | Start Export / Resume | ⌘R | canStart |
| Export | Pause | none | canPause |
| Export | Cancel Export | ⌘. | canCancel |
| Export | Verify Backup… | none | canOpenVerify |
| Export | Free Up Space… | none | canOpenFreeUpSpace |
| Help (replaced) | Welcome to Uncloud | none | not exporting |
| Window | system items | system | always |
| Edit | system items (no custom items) | system | always |

Toolbar (ContentView): Back, Forward (navigation control group), Home. All three also appear in the Go menu.

Keyboard shortcuts in views: Continue, Next, Get Started, Sign In, Verify, Done are `.defaultAction`. Cancel in sheets is `.cancelAction`.

### 1.3 Duplicated actions (where the same action appears)

| Action | Appears in |
|---|---|
| Choose folder | Home (Choose Folder…), Setup (Choose…), Export DestinationHeader (Choose…), Settings (text pointing back to main window, no button), ⌘O menu |
| Source picker (iCloud / Photos) | Home, Setup (LibrarySourceSection), Settings (LibrarySourceSection), Connect (two cards) |
| Sign in / out of iCloud | Home, Setup, Settings, Overview (Sign In…), Go menu (Sign Out), menu-driven confirmation on Home |
| Sign-out confirmation | Home (“Sign Out of iCloud?”) and LibrarySourceSection (“Sign out of iCloud?”), two strings that differ in capitalisation |
| Start / Resume export | Setup, Export (ExportControls), Home (Export Photos / Resume), Export menu (⌘R), menu bar (Back Up Now is separate) |
| Pause / Cancel | Export screen, Export menu |
| Verify Backup | Home, Export screen, Export menu |
| Free Up Space | Home (Photos only), Export screen (always, disabled for iCloud), Export menu |
| Show Introduction / Welcome | Home, Help menu |
| Back / Forward / Home | Toolbar, Go menu |
| Settings | Home (Settings…), App menu (⌘,), menu bar (Settings…) |
| Last backup / destination status | Home, Export header, Settings, menu bar status line |
| Folder layout and XMP | Setup only (fine), but Setup also repeats Source |

### 1.4 Labels that are confusing or inconsistent

- Start title: “Start Export”, “Export Photos”, “Resume”, “Resume Export”, “Show Export”, “Continue”, “Next”. Five verbs for the same job.
- Source names: picker says “Photos Library on This Mac”, Connect says “Use the Photos Library on This Mac”, Home says “Using the Photos library on this Mac”.
- “Choose…”, “Choose Folder…”, “Choose Destination…” for the same action.
- Internal jargon in navigation: Overview, Setup, Browse Library.
- Two sign-out dialog titles with different capitalisation.
- “Connect Your Photos” vs “Sign In…” vs “Sign in to iCloud” vs “Sign In to iCloud” (sheet).
- Magnifying glass icon (DestinationHeader) for “Show in Finder”. It reads as search.
- Settings text “Choose a destination folder in the main window first.” is a dead end.
- Mixed “Backup” and “Export” vocabulary across the app (Export Photos, Back Up Now, Automatic Backup, Verify Backup).

### 1.5 Other notes

- OnboardingView hides the Skip button with opacity 0 on the last page. It stays in the accessibility tree.
- ActivitySection has a fixed 160pt height, which will clip at larger Dynamic Type sizes.
- Settings “Show in menu bar” is disabled unless automatic backup is on. Two states for one feature.
- Free Up Space is shown and disabled on the export screen for iCloud, with a help tooltip. Hidden is clearer.
- ExportModel.step drives the whole flow, with Back/Forward history (furthestScreen). This is the source of most of the flow complexity.

---

## 2. Findings, ranked by user impact

1. **Nine screens to reach the first export.** A first-time user goes Welcome → 4 carousel pages → Connect → sign-in sheet → Home → Overview → Setup → Start → Export. About 9+ clicks before any photo is copied. (ContentView.swift, ExportModel.swift step machine.) Fix: one main window, sign-in only when needed, no carousel. Opus decision in section 3.1.
2. **Home is a dashboard that repeats the rest of the app.** It duplicates the source picker, sign-in, backup folder, settings, verify and free-up buttons. Every returning user sees it before doing anything. (HomeView.swift.)
3. **Source picker, sign-in and sign-out appear in 4 places** (Home, Setup, Settings, Go menu), with two different confirmation strings. (HomeView.swift, LibrarySourceSection.swift, ExportCommands.swift.)
4. **Choose folder appears in 4 places** (Home, Setup, DestinationHeader, ⌘O), plus a dead-end text in Settings.
5. **Overview is a step that only shows a count and a 249-item preview, then Continue.** It has no function a user needs once the browser exists. The new browser replaces it. (OverviewView.swift, ThumbnailMosaic.swift.)
6. **Setup repeats the source section and is a separate step from Export.** The Start button sits in a different screen from progress, so the user changes screens to see what they started. (SetupView.swift, ExportView.swift.)
7. **Back, Forward and Home (toolbar and Go menu) expose the internal step history.** They are a browser metaphor for a wizard the user should not need to navigate. Canonical Mac apps use sidebar selection instead. (ContentView.swift, ExportCommands.swift.)
8. **Verify Backup and Free Up Space appear in 3 places** each (Home, Export screen, Export menu). Free Up Space is shown for iCloud and disabled.
9. **Five different names for the export action** (Start Export, Export Photos, Resume, Resume Export, Show Export) and a separate Continue/Next per screen. The main action does not have a stable name. (ExportModel.startTitle, HomeView.exportButton.)
10. **Introduction is reachable twice (Home and Help) and costs 5 screens.** Most users will never use it again, and it competes with the first-run path. Onboarding also hides its Skip button with opacity, which is a HIG and VoiceOver problem.

Further findings (ranked lower):
- DestinationHeader uses a magnifying glass icon for Show in Finder (HIG: SF Symbols should match the action).
- ActivitySection uses a fixed 160pt height (Dynamic Type clipping).
- Settings: “Show in menu bar” is disabled unless automatic backup is on.
- ICloudSignInSheet title “Sign In to iCloud” vs button “Sign In”, fine, but the Connect card says “Sign In…” with an ellipsis that opens a sheet. Keep the ellipsis only for menu items that open more UI.
- The menu bar extra and the app menu both have Quit (⌘Q). Acceptable, but the menu bar item's Quit can drop its shortcut.
- Help menu has no real help. A custom item replaces it with an onboarding repeat.
- No Edit menu items. Select All (⌘A) is needed for the browser (see section 3.4).

---

## 3. Simplified design

### 3.1 Decision (Opus, navigation information architecture): Option A, single window with a sidebar (NavigationSplitView)

Opus rejected a bottom-bar browser (option B), because Verify, Free Up Space, destination, Activity and progress would be crammed into one bar. It also rejected a shorter wizard (option C), because the wizard is what causes the duplication. Opus gave this decision after its own review, based on the structure described to it (it did not re-read the files, so section 3.1's specifics are checked against the code in phase 2).

Sub-decisions adopted:
1. Remove the Back, Forward and Home toolbar items and the entire Go menu. Sidebar selection replaces them. Add View > Library (⌘1) and View > Backup (⌘2).
2. Delete the welcome screen and the 4-page carousel. First run is an inline empty state in the Library pane: one sentence and two buttons, “iCloud Photos…” and “Photos on This Mac”. Keep the privacy statement as a caption in the empty state (“Photos go straight from this Mac to your folder and are never uploaded.”). The introduction content moves to Help > Getting Started, a sheet.
3. Progress lives inline in the Backup pane, never in a sheet, because a sheet would block browsing. Add a progress badge on the Backup sidebar row and a compact progress gauge in the Library toolbar while an export runs. Clicking the gauge selects Backup.
4. Keep the menu bar extra, trimmed to: status line (disabled), Back Up Now, Open Uncloud, Settings…, Quit.

Sitemap:
- **Sidebar**
  - **Library**: the full-library browser (LazyVGrid, 93,012 items). Toolbar: selected count (“12,340 of 93,012 selected”), a Select menu (All ⌘A, None ⇧⌘A), primary action button, export progress gauge while running. Empty state when no source is ready.
  - **Backup**: destination row (folder name, path, Choose Folder…), last backup date, progress card with Pause/Resume and Cancel while running, Verify Backup…, Free Up Space… (Photos on This Mac only), Activity disclosure.
  - Sidebar footer: account row. The source name and an account pop-up (Switch Source, Sign In…, Sign Out…).
- **Settings (⌘,)**: Export (folder layout, Save metadata files .xmp toggle, moved from Setup), Automatic Backup, General (Open at login, Show in menu bar). The Source section is removed from Settings.
- **Sheets**: iCloud sign-in, Verify results, Free Up Space confirmation, Help > Getting Started.
- **Deleted**: Welcome, Onboarding, Connect (folded into empty state), Home dashboard, Overview, Setup (folded into Settings and the Export sheet below), the separate Export screen (folded into Backup), the Go menu.

Export start flow (decided here, not by Opus): the primary button starts the export directly when a folder is set. If no folder is set, the button reads “Choose Folder…” and opens the open panel, then continues to start. Layout and XMP are read from Settings > Export, so there is no setup screen. A first-run user who has never chosen a layout gets the default (By Month) and can change it in Settings.

First-run path (4 clicks): iCloud: “iCloud Photos…” (1), enter credentials and Sign In (2), Export All Photos (3), pick a folder (4). Photos on This Mac: click (1), system permission (2), Export All Photos (3), pick a folder (4). Today: about 9+ clicks.

Returning-user path: launch, then ⌘R or Export All Photos (1 click). With automatic backup on: 0 clicks. Resume after interruption: 1 click (Resume, or ⌘R). Export a subset: deselect items, then Export Selected (N+1 clicks).

### 3.2 Canonical homes (one place per function, plus menu mirrors)

| Function | Canonical home | Menu mirror |
|---|---|---|
| Choose folder | Backup pane “Choose Folder…” (also offered by the primary button when no folder is set) | File > Choose Backup Folder… ⌘O |
| Sign in / out | Sidebar account pop-up | File > Sign Out (hidden when signed out) |
| Verify Backup | Backup pane button | Export > Verify Backup… |
| Free Up Space | Backup pane button, Photos on This Mac only | Export > Free Up Space… (hidden for iCloud) |
| Settings | App menu > Settings… ⌘, | Menu bar extra |
| Introduction | Help > Getting Started | none |
| Layout and XMP | Settings > Export | none |
| Activity log | Backup pane disclosure | none |

### 3.3 Export menu, toolbar and status

Export menu (final):
- Export Selected ⌘R. Reads “Export All Photos” when nothing is deselected (LibrarySelection.isEverything), so the single primary action keeps its name in the common case. Note: this changes the ⌘R meaning for a partial selection. Acceptable; flagged for review.
- Export All Photos ⌥⌘R (always exports everything, ignoring selection).
- Pause ⌘P (shows “Resume” when paused, ⌘P again resumes; ⌘R also resumes).
- Cancel Export ⌘. (⌘. is the standard cancel).
- Divider. Verify Backup…, Free Up Space… (Photos only).

File menu: Choose Backup Folder… ⌘O, Sign Out (hidden when not signed in). Edit menu: Select All ⌘A and Deselect All ⇧⌘A, active when the Library has focus (text fields keep their system Select All; check the focus rule in phase 2).

Library toolbar (trailing, in this order): selected count label (secondary text, monospaced digits), Select menu, Export button (borderedProminent, the one primary action on the Library pane). When a partial selection exists, a bordered “Export 1,234 Items” sits beside Export All Photos.

Backup pane status and controls: ProgressCard (percent, bar, count, time left, status line) with Pause/Resume (bordered) and Cancel (bordered, destructive role not needed because it resumes later). Start appears only when idle.

Cancel and pause wording: Cancel Export, Pause, Resume. Replace “Start Export” and “Export Photos” everywhere.

### 3.4 The new browser (LibraryBrowser, LibraryItem, LibrarySelection)

- **Layout**: LazyVGrid with adaptive columns (minimum 96pt, spacing 2pt), thumbnails loaded through LibraryBrowser.thumbnail(for:pixelSize:) at the cell's pixel size. Load on demand; use item(at:) with the index so 93,012 items never allocate a full array.
- **Cell**: thumbnail, video badge (SF Symbol video.fill, white, on a small `.regularMaterial` capsule) when isVideo, selection control at the top-trailing corner.
- **Selection indicator**: unselected = white 1.5pt ring with a primary-colour stroke. Selected = filled accent circle with a white checkmark (Color.accentColor, multicolor not needed). Unselected items dim with `.opacity(0.45)` on the thumbnail only, so the state is not carried by colour alone.
- **Interaction**: click toggles (LibrarySelection.toggle). Shift-click selects a range (phase 2 if time allows; otherwise defer). Space toggles the focused cell. Arrow keys move focus (LazyVGrid default focus).
- **Select / deselect all**: Select All calls selectAll (LibrarySelection.everything). Deselect All calls deselectAll (LibrarySelection.only([])). Both are in the Edit menu and the Library toolbar's Select menu.
- **Count**: selectedCount(total: count) rendered as “12,340 of 93,012 selected”, or “All 93,012 items selected” when isEverything.
- **Accessibility**: each cell is one element with the filename, date and “Selected” or “Not selected” as its value. Use `.accessibilityAddTraits(.isToggle)`. Count is announced when it changes.
- **State**: LibraryBrowser.state drives the three screen states: loading (ProgressView with “Reading your library…”), empty (ContentUnavailableView), error (plain-language description and Try Again). Determinate progress only when the count is known.
- **Data ownership**: ExportModel owns LibrarySelection. The Export All Photos path passes LibrarySelection.everything regardless of stored selection. Export Selected passes the stored selection.

### 3.5 Export All Photos

- One button, always visible on the Library pane, named “Export All Photos”, borderedProminent, keyboard ⌥⌘R in the Export menu.
- Behavior: ignores the stored selection (uses everything), confirms once with a sheet only if no folder is set, otherwise starts directly.
- A visible one-line summary under the toolbar or in the Backup pane: “Exports all 93,012 items to Photos on the Mac or to iCloud, in the layout chosen in Settings.”

### 3.6 How export progress, pause and cancel appear

- Backup pane: ProgressCard (already exists; restyled with tint), plus Pause/Resume and Cancel.
- Library toolbar: a compact ProgressView(value:) gauge (ring, 16pt, accent tint) and percentage. Clicking selects the Backup pane.
- Sidebar: Backup row shows a badge with the percentage while running (`.badge` on the row, with a tint).
- Menu bar extra: status line “Backing up… 42%” (existing).
- Notifications on completion (existing, unchanged).

### 3.7 Settings and automatic backup

- Settings (⌘,) has three sections: Export (layout, metadata toggle, destination shown with Choose Folder…, Show in Finder with folder icon), Automatic Backup (two toggles, destination status, “Show in menu bar” always enabled), General (Open at login).
- Remove the disabled “Show in menu bar” state; the toggle is always enabled and simply has no effect while automatic backup is off, with a caption.
- Remove the dead-end text “Choose a destination folder in the main window first.”; the Choose Folder button replaces it.
- Sign Out and the Source section are removed from Settings; the sidebar account pop-up handles them.

---

## 4. What gets removed (with the reason)

| Removed | Reason |
|---|---|
| Welcome screen | Duplicates the connect empty state and adds a step. Its message moves to Help > Getting Started and the empty state caption. |
| 4-page onboarding carousel | Five screens before any action. Its content moves to Help > Getting Started. Also removes the hidden-with-opacity Skip button. |
| “Show Introduction” on Home and “Welcome to Uncloud” in Help | Duplicated. One entry in Help. |
| Home dashboard | Repeats sidebar, Settings and Backup pane. Its Account and Backup boxes move to the sidebar footer and the Backup pane. |
| Overview screen and its Continue button | Replaced by the browser. Its count moves into the browser toolbar. |
| 249-item ThumbnailMosaic (non-interactive) | Replaced by the full browser. Delete ThumbnailMosaic.swift once the browser is in (check with the other agent first, see checklist). |
| Setup screen as a step | Layout and XMP move to Settings > Export. Start moves to the Library and Backup panes. |
| Source section in Setup and in Settings | One source selector in the sidebar account footer. |
| Sign Out in Go menu, Home, Setup, Settings | Single home in the sidebar account pop-up, plus File > Sign Out. One confirmation string. |
| Go menu (Back, Forward, Home, Sign Out) | Sidebar selection replaces them. |
| Toolbar Back, Forward, Home | Same reason. |
| Separate Export screen | Folded into the Backup pane. Its DestinationHeader is replaced by the destination row. |
| Export screen’s Choose…, Show-in-Finder magnifier | Destination row in Backup. Show in Finder uses the folder symbol. |
| Duplicate Verify Backup and Free Up Space buttons on Home and Export | One home each (Backup pane) plus one menu item. |
| Free Up Space shown and disabled for iCloud | Hidden instead. |
| “Start Export” / “Export Photos” / “Show Export” / “Continue” / “Next” variants | Replaced by Export All Photos, Export Selected, Resume, Cancel Export, Pause. |
| Disabled “Show in menu bar” state | Always enabled. |

---

## 5. Labels: final wording

| Place | Text |
|---|---|
| Sidebar sections | Library, Backup |
| Sidebar footer | Signed in as {Apple ID} / Photos on This Mac; pop-up: Switch Source, Sign In…, Sign Out… |
| Empty state title | Connect Your Photos |
| Empty state buttons | iCloud Photos… (prominent) and Photos on This Mac (bordered) |
| Primary export | Export All Photos |
| Partial selection | Export 1,234 Items |
| Selection count | 12,340 of 93,012 selected / All 93,012 items selected |
| Select menu | Select All, Deselect All |
| Pause / resume | Pause, Resume |
| Cancel | Cancel Export |
| Folder | Choose Folder… (never “Choose…” or “Choose Destination…”) |
| Destination label | Save To |
| Sign-out confirmation (one copy) | Sign Out of iCloud? / Uncloud forgets this Apple ID and its saved password. Files already in your folder aren’t changed. |
| Menu bar | Back Up Now (automatic backup context only), Open Uncloud, Settings… |
| Help | Getting Started |

Terminology decision: the app says “Export” for manual runs and “Back Up” for automatic runs. This matches the two features. If the user wants one word, the change is a string edit in ExportModel and MenuBarContent. Flagged, not decided.

---

## 6. Colour plan (within the HIG)

### 6.1 Accent colour (AccentColor asset)

Verified with a WCAG relative-luminance script (scratchpad, not in the repo):

| Appearance | Hex | White text on accent | Accent as UI tint on window background |
|---|---|---|---|
| Light | #4F35C9 (indigo) | 7.82:1 | ~ 7.8:1 |
| Dark | #6F5CF0 (lighter indigo) | 4.70:1 | 3.54:1 on #1E1E1E (passes 3:1 for UI components) |

Use the light and dark values in Assets.xcassets/AccentColor.colorset/Contents.json (`"luminosity": "dark"` variant). Add ASSET_CATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: AccentColor to project.yml base settings, then run xcodegen generate. Add a high-contrast variant for accessibility (see 6.4).

Rationale: indigo is distinct from the system blue used by Settings and iCloud, and it reads as “library” and “photos”. It is not a gradient or decoration.

### 6.2 Coloured icon tiles (System Settings style)

Use a 28pt rounded rectangle (corner radius 6), filled with a system colour, and a white SF Symbol at `.font(.system(size: 15, weight: .semibold))`. The tile is the only colour decoration on the page. Mapping:

| Action or section | Symbol | System colour |
|---|---|---|
| Library (browser) | photo.stack | .purple |
| Export All Photos | square.and.arrow.down | .indigo (accent) |
| Backup (folder) | externaldrive | .teal |
| Verify Backup | checkmark.shield | .green |
| Free Up Space | externaldrive.badge.minus | .orange |
| iCloud account | icloud | .blue |
| Photos on This Mac | photo.on.rectangle | .pink |
| Settings | gearshape | .gray |
| Getting Started | sparkles | .yellow |
| Sign Out | rectangle.portrait.and.arrow.right | .red (destructive) |

Tiles are decorative: accessibilityHidden(true) and the label carries the meaning. Tiles in the sidebar use .symbolRenderingMode(.hierarchical) off, flat white on tile.

### 6.3 Status and progress

- Status icons use `.symbolRenderingMode(.multicolor)`: checkmark.circle.fill (green), exclamationmark.triangle.fill (yellow or orange), xmark.octagon.fill (red), icloud with `.palette` (blue primary, secondary).
- Progress: ProgressView(value:) with `.tint(Color.accentColor)`. Completed state: `.tint(.green)`. Failed: `.tint(.orange)`. Paused: `.tint(.secondary)`.
- Export completion summary: a green checkmark tile in the Backup pane, not a green background.
- Selected cells: accent circle with white checkmark (see 3.4). Badges on sidebar rows use `.badge` with the tint.

### 6.4 Accessibility and contrast

- Increase Contrast: read `@Environment(\.colorSchemeContrast) == .increased`. When set, add a 2pt border in `.primary` to the selection circle, use `.opacity(0.7)` on dimmed thumbnails instead of 0.45, and let the accent asset's high-contrast variant apply (add a high-contrast light variant #3B24B0 and dark #8A7BFF in the colorset if Xcode offers it, otherwise skip).
- Never use colour alone for state: selected items have a checkmark, unselected have a ring, dimmed items also lose opacity.
- Color names are semantic: only system colours or the accent, never RGB outside the asset catalog.
- No gradients, no custom shadows, no decorative backgrounds. Sidebar and window use system materials.
- Test in light, dark, Increase Contrast, and Reduce Motion before handing off.

### 6.5 Where colour goes (and does not)

- Accent: primary buttons, selection checkmarks, progress tint, sidebar selection highlight (system default).
- Tiles: sidebar rows and the empty state icons (one per section).
- Status colours: status text and icons only. Not whole cards.
- Not coloured: body text, captions, toolbar labels, settings forms.

---

## 7. Implementation checklist (phase 2)

Phase 2 is blocked until the other agent finishes ExportModel.swift, Export/*, OverviewView.swift and ThumbnailMosaic.swift. Before each edit, re-read the file, and if it changed since phase 1, re-check the step names used below.

Ordering: assets and tokens first (no dependencies), then model presentation state, then new views, then the window and menus, then removals last. Run both verify commands after each group.

### Group A: assets (no dependencies)

1. Create `Uncloud/Assets.xcassets/Contents.json` with `{"info":{"author":"xcode","version":1}}`.
2. Create `Uncloud/Assets.xcassets/AccentColor.colorset/Contents.json` with two colours: light #4F35C9 and dark (appearance "luminosity", value "dark") #6F5CF0. Use sRGB components (hex to 0-1 floats: 4F=79/255, 35=53/255, C9=201/255; dark: 6F=111/255, 5C=92/255, F0=240/255).
3. Edit `project.yml` target settings base: add `ASSET_CATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: AccentColor`. Run `xcodegen generate`.
4. Verify both commands.

### Group B: shared presentation helpers (new file, view-only)

5. Create `Uncloud/Views/IconTile.swift`: a `struct IconTile: View` with `symbol: String`, `tint: Color`. 28pt rounded rect (`RoundedRectangle(cornerRadius: 6, style: .continuous)`), tint fill, white SF Symbol 15pt semibold, `.accessibilityHidden(true)`.
6. In the same file, add `extension Color` nothing new; use system colours directly.
7. Verify.

### Group C: model presentation state (ExportModel, presentation-only, after the other agent is done)

8. Add computed properties to ExportModel:
   - `var primaryExportTitle: String` returns "Export All Photos" when selection is everything, otherwise "Export \(count) Items" when a partial selection is set. Needs LibrarySelection.selectedCount(total:).
   - `var exportSummary: String` with the one-line summary from 3.5.
   - `var showsFreeUpSpace: Bool` returns `source == .photosLibrary && hasPhotosAccess`.
9. Add `func exportAll()` that sets the selection to `.everything` for the run, then calls startOrResume. Decision (Opus, deferred to here): the stored selection is restored after the run. Keep it simple: exportAll does not change the stored selection; it passes `.everything` to the engine. Check the engine signature in the other agent's version before writing this.
10. Remove the step-history members (canGoBack, canGoForward, goBack, goForward, furthestScreen, isMovingForward, onboardingPage, firstScreen, screen(after:), screen(before:)) after the views are gone (group G). Do not remove them yet.
11. Verify.

### Group D: browser and selection views (depends on LibraryBrowser, LibraryItem from the other agent)

12. Create `Uncloud/Views/LibraryBrowserView.swift`: LazyVGrid with adaptive columns (min 96, spacing 2), `ScrollView`. Use `LibraryBrowser.count`, `item(at:)`, `thumbnail(for:pixelSize:)`. Three states from `LibraryBrowser.state`.
13. Create `Uncloud/Views/SelectionMark.swift`: the selection circle (unselected ring, selected accent fill with white check, Increase Contrast border). `.accessibilityHidden(true)` because the cell carries the label.
14. Each cell: `Button` with the thumbnail, the mark at top-trailing, and `.accessibilityLabel(filename)` plus `.accessibilityValue(selected ? "Selected" : "Not selected")` and `.accessibilityAddTraits(.isToggle)`. Click calls `model.toggleSelection(item.id)` (add this one-line method to ExportModel, calling LibrarySelection.toggle).
15. Add `Select All` and `Deselect All` methods to ExportModel calling `selectAll()` and `deselectAll()` on LibrarySelection, and a `selectedCountText`.
16. Verify.

### Group E: sidebar window (new root view)

17. Create `Uncloud/Views/LibraryWindow.swift`: `NavigationSplitView` with a sidebar `List(selection:)` of an enum `Pane { library, backup }`. Sidebar rows use IconTile for Library and Backup, and a `.badge` for the export percentage while running.
18. Detail: `switch` on the pane, calling `LibraryBrowserView` or `BackupPane`.
19. Sidebar footer: account pop-up `Menu` with Switch Source, Sign In… (opens the iCloud sheet), Sign Out… (opens the confirmation dialog). Icon tile for iCloud or Photos.
20. Empty state (no source ready): `ContentUnavailableView` with title "Connect Your Photos", description with the privacy sentence, and two buttons: "iCloud Photos…" (prominent) and "Photos on This Mac" (bordered). Calls existing `model.source = …` and the existing sign-in or `connectPhotoLibrary()`.
21. Toolbar in the Library pane: selected count text, Select menu (All ⌘A, None ⇧⌘A) with the Edit menu mirrors, primary export button (borderedProminent, `.keyboardShortcut` left to the menu to avoid duplicates), progress gauge while running.
22. Verify.

### Group F: Backup pane (merges Home, Export, Setup destination and layout)

23. Create `Uncloud/Views/BackupPane.swift`: a `Form` with sections: Save To (destination row with `Choose Folder…` and Show in Finder with the `folder` symbol, not magnifyingglass), Status (last backup, incomplete run notice, destination issue), Progress (existing ProgressCard restyled, and Pause/Resume and Cancel buttons), Tools (Verify Backup…, Free Up Space… only when `showsFreeUpSpace`), Activity (existing ActivitySection, drop the fixed 160pt height and use `.frame(minHeight: 120)`).
24. Replace ExportControls and DestinationHeader usage with BackupPane. Keep the files until group G, then delete them.
25. Verify.

### Group G: settings and menus

26. Edit `Views/SettingsView.swift`: remove the LibrarySourceSection, add an Export section with the FolderLayout picker and the metadata toggle (moved from SetupView), add a destination row with Choose Folder…, remove the dead-end text, make "Show in menu bar" always enabled.
27. Edit `App/ExportCommands.swift`: remove the Go menu entirely. In File: Choose Backup Folder… ⌘O, Sign Out… (enabled when signed in and not exporting). In Export: Export Selected ⌘R (title from primaryExportTitle), Export All Photos ⌥⌘R, Pause/Resume ⌘P, Cancel Export ⌘., Verify Backup…, Free Up Space… (hidden for iCloud). Replace Help: Getting Started (sheet, see group H). Add an Edit replacement: Select All ⌘A, Deselect All ⇧⌘A (replacing the system pasteboard Select All group; check that text fields still get ⌘A, see the open question below).
28. Add View menu items: Library ⌘1, Backup ⌘2 (set `model.pane`, see group E).
29. Edit `Views/MenuBarContent.swift`: status line, Back Up Now, Open Uncloud, Settings…, Quit. Remove nothing else.
30. Verify.

### Group H: getting started sheet

31. Create `Uncloud/Views/GettingStartedSheet.swift`: the four onboarding texts from `OnboardingPage.all` in a scrollable list, one "Done" button (`.defaultAction`, `.keyboardShortcut(.cancelAction)` too via a second button or ESC by default). Reuse `OnboardingPage.all` as-is.
32. Verify.

### Group I: removal (last, after the new views build)

33. Edit `App/UncloudApp.swift`: replace `ContentView()` with `LibraryWindow()`, keep `.backupToolSheets()` and the environments.
34. Edit `Views/ContentView.swift`: delete the toolbar Back, Forward and Home. Either delete the file or reduce it to the fileImporter and iCloud sheet modifiers that LibraryWindow needs. Recommended: move the modifiers into LibraryWindow, then delete ContentView.swift.
35. Delete the files: WelcomeView.swift, OnboardingView.swift (keep OnboardingPage.swift as the source for the sheet), ConnectView.swift (its PhotosAccessView content moves into the empty state), HomeView.swift, OverviewView.swift, ThumbnailMosaic.swift (only after the other agent confirms it is unused), SetupView.swift, ExportView.swift, ExportControls.swift, DestinationHeader.swift, LibrarySourceSection.swift. Run `xcodegen generate` after deletes.
36. Edit `Model/ExportModel.swift`: delete the `Step` enum and the `Screen` struct and the navigation methods (goBack, goForward, goHome, showOverview, showExport, showWelcome, startOnboarding, nextOnboardingPage, finishOnboarding, continueToSetup, updateStepForReadiness, screen(after:), screen(before:), canGoBack, canGoForward, canGoHome, isLastOnboardingPage, requestICloudSignOut). Replace `step` with `pane: Pane`. Keep `UserDefaults` keys for compatibility; drop `onboardingKey` logic or keep it only to skip the first-run empty state. Do this in a separate commit-sized change, since it touches every view.
37. Verify both commands after every removal, and fix only references to deleted names.

### Group J: copy and polish

38. Replace the labels in section 5 across the remaining views (Sign-out dialog text, "Choose…" to "Choose Folder…", "Source" to "Sign In" wording).
39. Replace `Image(systemName: "magnifyingglass")` (old DestinationHeader, now deleted) with the folder symbol (already in group F).
40. Verify.

### Open questions for a human (the app running, not the code)

- ⌘A in text fields: the Edit replacement must not steal Select All from search or text fields. Test in the running app.
- Opus did not read the files. Re-check the decision with the real code in group I (for example, whether ICloudSignInSheet can present from the sidebar sheet).
- Whether the menu bar extra stays visible without the Home dashboard (decided: yes).
- Whether Settings should be a single window or a sidebar pane (decided: single window, ⌘,).
- Terminology: Export vs Back Up (section 5).
- ⌘R meaning changes from Start Export to Export Selected (section 3.3).

### Decisions recorded inline

- Opus: Option A (sidebar, single window). Opus also decided: no Go menu, no Back/Forward/Home, no welcome or carousel, progress inline in the Backup pane, menu bar extra kept.
- Designer (this phase): Export All Photos ignores the stored selection and uses `.everything`. Export Selected uses the stored selection. The primary button name follows the selection.
- Designer: AccentColor values #4F35C9 (light) and #6F5CF0 (dark), chosen for contrast.

## User decisions (2026-10-12), which override anything above

1. **First run:** keep ONE welcome screen, shown on first launch only (title, one-line value proposition, "Get Started"). Remove the 4-page onboarding carousel and move its content into Help → Getting Started (a sheet or window). Don't offer a second way to reopen the welcome screen.
2. **Navigation:** the sidebar (Library | Backup) is the main menu. Remove the Back/Forward/Home toolbar buttons, the Go menu, and the Home page.
3. **Wording:** use "Export" everywhere ("Export All Photos", "Export 120 Items"). Never "Back Up" for the main action. Automatic backup keeps its name in Settings.
