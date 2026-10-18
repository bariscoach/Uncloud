# Uncloud UI refresh plan: simple, lean, colourful, modern

Status: research and audit only. No app code was changed. A Haiku implementer follows this file item by item.
Author: design lead (Opus), 2026-10-17. Branch at time of writing: `feature/duplicates-and-icloud-cleanup` (65695b9).

Goal from the user: "simple, lean, minimal, colourful and modern", following Apple's HIG and Liquid Glass. Three states
must be impossible to miss: **Resume Export**, **"N new photos since your last export"** and **Export New Photos**.

Environment checked:
- `xcrun --show-sdk-version --sdk macosx` → **27.0** (Xcode 27.1, 27A9275). The app already builds against an SDK that
  has every Liquid Glass API, so on macOS 26+ the standard controls already get the new look with no code changes.
- Deployment target: macOS 14 (project.yml). Every macOS 26 API below must sit behind `if #available(macOS 26, *)`.
- Every API name in this plan was checked against the local SDK's `SwiftUI.swiftinterface` / `SwiftUICore.swiftinterface`
  (MacOSX27.0.sdk), not only against web pages. See section 1.4.

---

## 1. Research brief

### 1.1 Layout and window structure (HIG)

| Rule | What it means for Uncloud | Source |
|---|---|---|
| Put the most important items near the top and leading side. | The Backup pane's key status and its one action go first, not mid-card. | [HIG Layout](https://developer.apple.com/design/human-interface-guidelines/layout) |
| Group related items with space, container shapes or separators. Use progressive disclosure. | Fewer, clearer sections; captions and Activity stay collapsed or lower. | [HIG Layout](https://developer.apple.com/design/human-interface-guidelines/layout) |
| Avoid controls or critical information at the bottom of a window or sidebar. | Keep the account footer for low-stakes switching only; never put status there. | [HIG Layout](https://developer.apple.com/design/human-interface-guidelines/layout), [HIG Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars) |
| Sidebar icons use the accent colour by default; fixed colours are fine "if you use them sparingly" to clarify meaning. At most two levels. | Coloured icon tiles are allowed, but each colour should mean something and not collide with the accent. | [HIG Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars) |
| Offer Show/Hide Sidebar in the View menu. | Add `SidebarCommands()`. | [HIG Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars), [HIG The menu bar](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar) |
| Toolbar: "Provide a useful title for each window." "Don't title windows with your app name." Keep titles under 15 characters. | Each pane sets `.navigationTitle` ("Library", "Backup", "Clean Up iCloud"). | [HIG Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars) |
| Toolbar: aim for at most three groups. "Keep actions with text labels separate" from symbol actions. One `.prominent` primary action, on the trailing side. | Library and Clean Up toolbars: move the count text out of the button group, separate the primary button. | [HIG Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars), [WWDC25 356](https://developer.apple.com/videos/play/wwdc2025/356/) |
| "Make every toolbar item available as a command in the menu bar." Menus: App, File, Edit, Format, View, app menus, Window, Help. Disable, don't hide, unavailable items. | Add View › Clean Up iCloud (⌘3). Keep Export menu. | [HIG Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars), [HIG The menu bar](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar) |
| Menu bar extra: show a menu, not a popover. Let people decide whether to show it. Don't rely on it being present. | Current `MenuBarExtra(.menu)` is correct. Only its status text changes. | [HIG The menu bar](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar) |
| Settings: "general, infrequently changed settings". Task-specific options stay where they are used. Minimise the number of settings. | Folder layout and .xmp stay in Backup (task-specific). Settings stays small. | [HIG Settings](https://developer.apple.com/design/human-interface-guidelines/settings) |

### 1.2 Colour, typography, buttons, progress, alerts, accessibility (HIG)

| Rule | Source |
|---|---|
| macOS applies your accent colour only when the user's System Settings accent is **Multicolor**; otherwise the user's choice replaces it. "A sidebar icon that uses a fixed color" is not overridden. | [HIG Color](https://developer.apple.com/design/human-interface-guidelines/color) |
| Don't hard-code system colour values; use `Color`. Don't redefine the meaning of system colours. Custom colours need light, dark and increased-contrast variants. | [HIG Color](https://developer.apple.com/design/human-interface-guidelines/color) |
| Liquid Glass colour: "Apply color sparingly"; reserve it for status indicators or primary actions; tint the background of a primary action, not its text; "Refrain from adding color to the background of multiple controls." | [HIG Color](https://developer.apple.com/design/human-interface-guidelines/color) |
| Don't rely on colour alone; pair it with a symbol or text. | [HIG Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility) |
| Contrast minimums (WCAG AA): 4.5:1 for text up to 17 pt, 3:1 for 18 pt+ or bold. Check light and dark. Prefer system colours, which adapt to Increase Contrast. macOS default text 13 pt, minimum 10 pt. | [HIG Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility) |
| Reduce Motion: reduce automatic and repeating animation, scaling and zooming; replace movement with fades. | [HIG Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility) |
| Use the built-in text styles; avoid light weights; use weight, size and colour for hierarchy. macOS doesn't support Dynamic Type. macOS sizes: Large Title 26, Title 1 22, Title 2 17, Title 3 15, Headline 13 bold, Body 13, Callout 12, Subheadline 11, Footnote/Caption 10. | [HIG Typography](https://developer.apple.com/design/human-interface-guidelines/typography) |
| One or two prominent buttons per view, for the most likely action. "Use style — not size — to distinguish the preferred choice." | [HIG Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons) |
| "Don't assign the primary role to a button that performs a destructive action, even if that action is the most likely choice." Destructive buttons use system red. Ellipsis when a button opens more UI. | [HIG Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons) |
| Alerts: confirm uncommon destructive actions; always include Cancel; don't make Cancel the default; "Use a caution symbol sparingly", only where data could be lost unexpectedly. | [HIG Alerts](https://developer.apple.com/design/human-interface-guidelines/alerts) |
| Progress: determinate when the total is known; keep it moving; show it in a consistent place; offer Cancel, and Pause when stopping loses work; don't switch between spinner and bar. Describe what's happening precisely. | [HIG Progress indicators](https://developer.apple.com/design/human-interface-guidelines/progress-indicators) |

### 1.3 Liquid Glass (macOS 26 and later)

| Principle | Source |
|---|---|
| Liquid Glass is "a distinct functional layer for controls and navigation elements" that "floats above the content layer". **"Don't use Liquid Glass in the content layer."** "Use Liquid Glass effects sparingly." | [HIG Materials](https://developer.apple.com/design/human-interface-guidelines/materials) |
| Regular glass for components with text (sidebars, alerts, popovers). Clear glass only over visually rich media. | [HIG Materials](https://developer.apple.com/design/human-interface-guidelines/materials) |
| Hierarchy comes from layout and grouping, not decoration; remove custom backgrounds and borders behind bars. Group toolbar items by function; don't group symbols with text. | [WWDC25 356 "Get to know the new design system"](https://developer.apple.com/videos/play/wwdc2025/356/) |
| Concentricity: three shape kinds (fixed, capsule, concentric). On the Mac, large controls become capsules; mini/small/medium stay rounded rectangles; nested shapes should be concentric. | [WWDC25 356](https://developer.apple.com/videos/play/wwdc2025/356/) |
| Scroll edge effects clarify where UI meets content; soft is the default, **hard "mostly used on macOS"** for pinned headers or controls without backgrounds; one per view. | [WWDC25 356](https://developer.apple.com/videos/play/wwdc2025/356/), [HIG Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars) |
| Recompiling with the new SDK gives: a floating glass sidebar in `NavigationSplitView`; toolbar items grouped on glass with an automatic scroll edge effect; glass sheets; capsule bordered buttons and slightly taller macOS controls; glass during interaction for toggles, segmented pickers and sliders; menus, alerts and popovers that grow from their source. Advice: audit, remove custom backgrounds behind bars and sheets, then add glass only where it makes the app distinctive. Use `.tint` "only to convey meaning". | [WWDC25 323 "Build a SwiftUI app with the new design"](https://developer.apple.com/videos/play/wwdc2025/323/) |
| Apple's announcement: Liquid Glass sidebars and toolbars "reflect and refract" content; macOS Tahoe 26 shipped Sept 2025. | [Apple press release, 9 June 2025 (syndicated)](https://www.nasdaq.com/press-release/apple-introduces-delightful-and-elegant-new-software-design-2025-06-09) |

### 1.4 Verified SwiftUI API names (from the local MacOSX27.0 SDK interface)

All are `@available(macOS 26.0, *)` unless noted. Apple's doc pages [Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views), [GlassEffectContainer](https://developer.apple.com/documentation/swiftui/glasseffectcontainer) and [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass) didn't render for the fetch tool, so the signatures below come from the SDK.

| API | Exact declaration |
|---|---|
| Glass modifier | `func glassEffect(_ glass: Glass = .regular, in shape: some Shape = DefaultGlassEffectShape()) -> some View` (default shape is a capsule) |
| Glass values | `Glass.regular`, `Glass.clear`, `Glass.identity`; `func tint(_ color: Color?) -> Glass`; `func interactive(_ isEnabled: Bool = true) -> Glass` |
| Container | `GlassEffectContainer(spacing: CGFloat? = nil) { … }` |
| Morphing | `glassEffectID(_ id: (some Hashable & Sendable)?, in: Namespace.ID)`, `glassEffectUnion(id:namespace:)` |
| Button styles | `.buttonStyle(.glass)`, `.buttonStyle(.glassProminent)` |
| Toolbar | `ToolbarSpacer(_ sizing: SpacerSizing = .flexible, placement: ToolbarItemPlacement = .automatic)`, sizing `.fixed` / `.flexible`; `ToolbarContent.sharedBackgroundVisibility(_ visibility: Visibility)` |
| Scroll edge | `scrollEdgeEffectStyle(_ style: ScrollEdgeEffectStyle?, for edges: Edge.Set)`, styles `.soft`, `.hard` |
| Background extension | `backgroundExtensionEffect()`, `backgroundExtensionEffect(isEnabled:)` |
| Concentric shapes | `ConcentricRectangle()`, `ConcentricRectangle(corners: Edge.Corner.Style, isUniform: Bool = false)`, shorthand `.rect(corners: .concentric, isUniform:)`; `Edge.Corner.Style.fixed(_:)`, `.concentric`, `.concentric(minimum:)`; `containerShape(_ shape: some RoundedRectangularShape)` |
| Button sizing | `buttonSizing(_:)` with `.automatic` / `.flexible` / `.fitted` |
| macOS 14-safe, still useful | `ControlSize.extraLarge` (macOS 14), `badgeProminence(_:)` (macOS 14), `navigationSubtitle(_:)` (macOS 11), `SidebarCommands()` (macOS 11), environment `accessibilityReduceTransparency`, `accessibilityReduceMotion`, `colorSchemeContrast` |

**Correction to circulating examples:** the WWDC25 323 session shows `.rect(corner: .containerConcentric)`. That spelling is **not** in the shipped SDK. Use `ConcentricRectangle` or `.rect(corners: .concentric(minimum: .fixed(r)), isUniform: true)`.

**Gating pattern** (use everywhere; a computed property or `@ViewBuilder` keeps the call site clean):

```swift
@ViewBuilder
private var exportStartedBackground: some View {
    if #available(macOS 26, *) {
        Color.clear.glassEffect(.regular, in: .rect(cornerRadius: Tokens.Radius.l))
    } else {
        RoundedRectangle(cornerRadius: Tokens.Radius.l, style: .continuous).fill(.regularMaterial)
    }
}
```

For toolbar content, `#available` works inside `@ToolbarContentBuilder`:

```swift
if #available(macOS 26, *) {
    ToolbarSpacer(.fixed, placement: .primaryAction)
}
```

### 1.5 What we take from the "Startup" web design system (.claude/design/startup-design-system.md)

Take:
- **One primary action per screen** ("Do use `primary` for the single most important action per screen"). Matches HIG.
- **Token discipline**: "Don't introduce new color literals. Add a token if a hue is missing." Every radius, spacing step, tile size and tint lives in one file.
- **Radius scale, one step per nesting level**: "Buttons and inputs share a radius; cards step up one tier." We map it to the Mac: controls use the system shape; tiles and small chips 6; cards 10; hero 14.
- **4 pt spacing base** (4, 8, 12, 16, 20, 24, 32), which matches AppKit/SwiftUI defaults.
- **AA contrast** (4.5:1 body, 3:1 large/bold and UI) and **Reduce Motion** ("All transitions collapse … under prefers-reduced-motion").
- The **purple accent `#7c3aed`** as a comparison variant (white on it: 5.70:1, passes AA).

Leave out (doesn't fit a native Mac app): Plus Jakarta Sans / Inter / JetBrains Mono (use SF via text styles); marketing-scale headlines and `clamp()` sizing; the web breakpoint grid; purple-tinted shadow elevation (HIG: hierarchy from layout and materials, not custom shadows); `foreground-muted #a1a1aa` (2.56:1, fails AA; use `.secondary`); the custom border colour (1.39:1).

Measured contrast for the accent candidates (WCAG relative luminance, computed locally):

| Colour | White text on it | As text on dark window (#1E1E1E) |
|---|---|---|
| Shipping `AccentColor` asset, light `#4F35C9` | 7.82 | n/a |
| Shipping `AccentColor` asset, dark `#6F5CF0` | 4.70 | 3.54 |
| Startup purple `#7C3AED` | 5.70 | 2.93 (too low as text in dark) |
| Proposed purple dark `#8B5CF6` | 4.23 | 3.94 |
| Proposed purple dark, increased contrast `#A78BFA` | n/a (use dark text) | 6.13 |
| System blue light `#007AFF` | 4.02 | n/a |
| System green `#34C759` / teal `#30B0C7` / orange `#FF9500` | 2.22 / 2.57 / 2.20 | n/a |

The last row matters for `IconTile`: white glyphs on green, teal, mint and orange tiles fall below 3:1. The tiles are decorative (`accessibilityHidden`, label beside them), as in System Settings, so this is acceptable, but item P2-3 adds an Increase Contrast treatment.

---

## 2. Audit, screen by screen

What I could see: `backup-pane-{light,dark}.png`, `check-drive-*`, `export-history-*`, `session-detail-*` (scratchpad root), plus the Clean Up grid, delete confirmation and Find Duplicates renders in `scratchpad/cleanup-attachments/` and `scratchpad/att/` (named in their `manifest.json`).
What I could **not** see: the folders `new-photos-snapshots`, `recently-deleted-snapshots`, `cleanup-snapshots` and `duplicates-snapshots` are **empty** (the sandboxed test host fell back to attachments). There are no renders of the Landing page, the Library grid with toolbar, the sidebar, the window toolbar, the Recently Deleted mode, Verify Backup, Free Up Space, Sign In, Settings, the menu bar extra, or any running-export or Resume Export state. Also, in every render the accent draws as **system blue**, while the shipping `AccentColor` asset is indigo `#4F35C9`/`#6F5CF0`. This Mac's global `AppleAccentColor` is unset (Multicolor), so the real app should draw indigo. Most likely the offscreen test windows don't pick up the asset accent. I couldn't confirm this without launching the app, so treat "current blue" as "what the renders show". The variant switch in P1-1 makes renders and the app agree.

### 2.1 Window, sidebar, toolbar, menus (LibraryWindow.swift, LibraryView.swift, ExportCommands.swift)

Good:
- `NavigationSplitView` with three panes. It gets the floating glass sidebar on macOS 26 for free.
- Live progress badge on the Backup row (`badgeProminence(.increased)`) and the new-photos count badge.
- Export menu mirrors the primary action with the same title (⌘R), plus Export All (⌥⌘R), Pause, Cancel (⌘.), tools.
- Sign-out confirmation in one place. The Export Started banner is non-modal, announced to VoiceOver and gated on Reduce Motion.

Violations:
1. No `.navigationTitle` per pane, so the window is titled "Uncloud" everywhere. HIG Toolbars: "Don't title windows with your app name."
2. The Library toolbar puts the count `Text`, the "Select" text menu, the progress ring and the prominent button in **one** `ToolbarItemGroup`. On macOS 26 they share one glass capsule, so the static count looks like a button and text sits next to symbols. HIG/WWDC 356: separate text actions; at most three groups. The Clean Up toolbar has the same issue.
3. The View menu has Library ⌘1 and Backup ⌘2 but **no Clean Up iCloud**, and no Show/Hide Sidebar (`SidebarCommands` missing).
4. Sidebar tiles: Library uses `.purple`, which collides with the purple accent variant. Clean Up uses a **red trash** tile, which makes a whole pane look like a warning (the alarming tone the user wants to avoid). The 28 pt tiles make sidebar rows taller than the system's (System Settings uses about 20 pt).
5. The account footer sits at the bottom of the sidebar. That's acceptable because switching source is low-stakes, but status must never move there (HIG).

### 2.2 Backup pane (BackupPane.swift, ProgressCard.swift, NewPhotosViews.swift) — the main problem

Good: grouped `Form`, System Settings-style section tiles, determinate progress with % and time left, Pause and Cancel, a Resume Export / Start New Export pair, clear drive and space wording, history with chevrons, `monospacedDigit` throughout.

Violations (see `backup-pane-light.png`):
1. **The key status is buried.** "1,243 new photos since your last export…" is `NewPhotosStatusLabel`: a `.callout` secondary-grey label, the fourth line of the third card. HIG Layout: the most important item goes top-leading. HIG Color: use colour for status.
2. **The primary button sits mid-card**, under the drive row, the "0%" headline, an empty bar, "0 of 93,015 items" and a status line. In idle, the "0%" and empty bar are noise (the render shows them). HIG Progress: show progress when there is progress.
3. **Three places compete for "what's my status"**: the drive row ("0 already on this drive · 93,015 to go"), the progress card status line, and "Last Export … 3 minutes ago".
4. **Set-once configuration comes before the action.** "Folders and Files" (layout radio group, .xmp toggle and three captions) is the second section, pushing Export below the fold at the default window height.
5. **Resume Export** is a `.borderedProminent` button in the card, which is right, but its explanation is a grey `info.circle` caption. An interrupted export should read as a warning-level state (orange), not as info.
6. **Path and folder name wrap badly**: the folder name wraps over three lines next to the buttons (render). `lineLimit(1)` is set on the name, but the row has no width priority.
7. The "Export" section header tile uses `.accentColor` while every other tile uses a fixed hue, so with a non-Multicolor accent it changes colour and the rest don't.

### 2.3 Clean Up iCloud (CleanupView.swift)

Good: the typed-number confirmation, Return never deletes, Cancel is `.cancelAction`, the "not backed up" warning uses orange and a triangle (justified: real data-loss risk), Recover is prominent and not red, the summary offers "View Recently Deleted", and the status card offers Pause and Cancel with an honest "can't be recalled" note.

Violations:
1. **The toolbar Delete button is `.borderedProminent` + `.tint(.red)`**, which makes it the pane's primary action. HIG Buttons: "Don't assign the primary role to a button that performs a destructive action." It's also alarming, combined with the red trash sidebar tile.
2. The Library | Recently Deleted segmented picker and the 30-days note sit in a `safeAreaInset` band under the toolbar. That's a custom bar over content. Apple's pattern for switching views is a segmented control in the toolbar (`.principal`). WWDC 356: remove custom bar backgrounds.
3. The count text shares the button group (same as Library).
4. `.animation(.smooth, value: showsStatus)` isn't gated on Reduce Motion. It's opacity only, so this is low risk, but it's inconsistent with LibraryWindow.

### 2.4 Sheets (Verify Backup, Find Duplicates, Free Up Space, Check Drive, Sign In, Session Detail, Getting Started)

Good: title2 semibold titles, the `.defaultAction` / `.cancelAction` pattern, destructive roles on Move to Trash / Remove / Delete and Export Again, and grouped forms for results (renders look clean in both modes).

Violations (consistency only):
- Padding varies (16, 20, 24) and widths vary (420, 460, 500, 520, 560) with no scale. Duplicates' footer shows "Done" and "Move 4 Copies to Trash…" in the same grey bordered style (render `att/4E05…png`). That's correct (destructive is not primary), but the Trash button has no symbol or colour cue. A `trash` symbol would help.
- With the macOS 26 SDK, sheets get glass automatically. No sheet sets `presentationBackground`, which is good. Don't add one.

### 2.5 Landing, Settings, menu bar extra

- Landing: one prominent "Sign In with Apple ID…" with `.defaultAction`, and a link-style alternative. Good. No change beyond tokens. (Not rendered; see 2.0.)
- Settings: `Form(.grouped)`, three sections, 460 wide. Correct for the HIG. Leave it.
- Menu bar extra: menu style is correct. The status line doesn't show new photos or an interrupted export, the two states the user cares most about. It is display text only.

---

## 3. Prioritised change list

Conventions for the implementer:
- 4-space indent, sparse `///` comments that explain why, Swift 6 strict concurrency, typecheck with `-target arm64-apple-macos14.0` (see `.claude/agents/designer.md` step 5). Run `xcodegen generate` after adding files.
- Every `if #available(macOS 26, *)` needs an `else` branch that keeps today's look.
- Don't touch `Uncloud/Export/**`, any `ExportModel` / `ICloudCleanup` / `BackupTools` method bodies, or any condition that decides *whether* a button is enabled or shown. Only move views, restyle them, and add pure presentation helpers.

### P1 — do these first

#### P1-1. Design tokens and the accent variant switch

**New file** `Uncloud/Views/DesignTokens.swift`:

```swift
import AppKit
import SwiftUI

/// The app's design tokens. Views use these instead of literal sizes, radii or hues, so one edit restyles every pane.
enum Tokens {
    /// Corner radii. One step up per nesting level: chips inside cards inside the hero.
    enum Radius {
        static let s: CGFloat = 6      // chips, small tags, IconTile up to 24 pt
        static let m: CGFloat = 10     // cards, banners, list-row backgrounds
        static let l: CGFloat = 14     // the Backup hero, floating banners
        /// IconTile corner as a fraction of its side, as in System Settings.
        static let tileRatio: CGFloat = 0.225
    }

    /// Spacing on a 4 pt grid.
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        static let xxxl: CGFloat = 32
    }

    /// IconTile side lengths. Use only these four.
    enum Tile {
        static let sidebar: CGFloat = 20
        static let section: CGFloat = 24
        static let feature: CGFloat = 32   // benefit rows, How It Works steps
        static let hero: CGFloat = 44
    }

    /// Sheet sizes and padding.
    enum Sheet {
        static let padding: CGFloat = 20
        static let narrow: CGFloat = 420   // Sign In, delete and recover confirmations
        static let regular: CGFloat = 520  // Verify, Free Up Space, Check Drive, Session Detail
        static let wide: CGFloat = 560     // Find Duplicates
    }

    /// Fixed hues for places and features. Each hue means one thing everywhere.
    enum Tint {
        static let library = Color.pink        // photos (also "Photos on This Mac" in the footer)
        static let iCloud = Color.blue         // anything iCloud: footer, Clean Up iCloud row
        static let drive = Color.teal          // Backup row, Save To
        static let folders = Color.mint        // Folders and Files
        static let tools = Color.green         // Backup Tools
        static let history = Color.indigo      // Export History
        static let neutral = Color.gray        // Activity
    }

    /// Status colours. Always paired with a symbol, never colour alone.
    enum Status {
        static let success = Color.green
        static let warning = Color.orange
        static let danger = Color.red
        static let neutral = Color.secondary
    }
}

/// The accent used for comparison renders: today's blue or the "Startup" purple (#7c3aed). Nil means the shipping
/// AccentColor asset, which macOS replaces with the user's own accent unless it is set to Multicolor.
enum AccentVariant: String, CaseIterable, Sendable {
    case blue
    case purple

    var color: Color {
        switch self {
        case .blue: Color(nsColor: .systemBlue)
        case .purple: Color("AccentPurple")
        }
    }

    /// Read from `-UncloudAccentVariant purple` on the command line or the same user default. Debug and design use only.
    static var override: AccentVariant? {
        UserDefaults.standard.string(forKey: "UncloudAccentVariant").flatMap(AccentVariant.init(rawValue:))
    }
}

extension View {
    /// Applies an accent variant as the tint, or leaves the system accent alone when nil.
    @ViewBuilder
    func accentVariant(_ variant: AccentVariant?) -> some View {
        if let variant {
            tint(variant.color)
        } else {
            self
        }
    }
}
```

**New colour asset** `Uncloud/Assets.xcassets/AccentPurple.colorset/Contents.json`, with four appearances (any, dark, any + high contrast, dark + high contrast):
- any `#7C3AED` (sRGB 0.486, 0.227, 0.929)
- dark `#8B5CF6` (0.545, 0.361, 0.965)
- any + `"appearance": "contrast", "value": "high"` → `#6D28D9` (0.427, 0.157, 0.851)
- dark + high contrast → `#A78BFA` (0.655, 0.545, 0.980)

Use the same JSON shape as `AccentColor.colorset`, adding `{"appearance":"contrast","value":"high"}` entries to the `appearances` arrays.

**Wire it**: in `UncloudApp.swift`, on `LibraryWindow()` (after `.environment(backupTools)`) and on `SettingsView()`, add `.accentVariant(AccentVariant.override)`. Snapshot tests apply `.accentVariant(.blue)` / `.accentVariant(.purple)` explicitly.

Don't change `AccentColor.colorset` in this pass. Once the user picks a variant, copy that variant's values into `AccentColor` and delete the override (a follow-up, not part of this plan).

Acceptance:
- Builds on macOS 14. No call site uses a colour literal except the asset JSON.
- Running with `-UncloudAccentVariant purple` tints prominent buttons, progress bars, selection rings and toggles purple. Without the argument, nothing changes from today.
- Purple renders in light, dark and Increase Contrast keep white button text at 4.2:1 or better (values above).

#### P1-2. Backup pane: a status hero with the one primary action

**New file** `Uncloud/Views/BackupHero.swift` with two parts.

(a) A pure, testable content model (no SwiftUI state, no model writes):

```swift
/// What the top of the Backup pane says, worked out from the model's state. Pure, so it is unit-tested.
struct BackupHeroContent: Equatable {
    enum Kind: Equatable { case exporting, waiting, interrupted, needsFolder, finishedWithProblems,
                           stopped, cancelled, complete, newPhotos, upToDate, ready }
    enum Tone: Equatable { case accent, success, warning, danger, neutral }

    let kind: Kind
    let symbol: String
    let title: String
    let subtitle: String?
    let tone: Tone
}
```

`static func make(...)` takes plain values: `phase: ExportModel.Phase`, `hasDestination: Bool`, `hasAutoResume: Bool`, `offersResumeExport: Bool`, `failedCount: Int`, `newPhotos: NewPhotosStatus?`, `lastExport: Date?`, `readySummary: String?`, `now: Date`. Precedence, first match wins:

| # | When | kind | symbol | title | subtitle | tone |
|---|---|---|---|---|---|---|
| 1 | phase is `.preparing` | exporting | `arrow.down.circle` | "Preparing Export…" | nil | accent |
| 1 | phase is `.running` | exporting | `arrow.down.circle` | "Exporting…" | nil | accent |
| 1 | phase is `.paused` | exporting | `pause.circle` | "Export Paused" | nil | neutral |
| 1 | phase is `.cancelling` | exporting | `xmark.circle` | "Cancelling…" | nil | neutral |
| 2 | `hasAutoResume` | waiting | `clock` | "Waiting to Resume" | nil (the card's AutoResumeStatus explains) | warning |
| 3 | `offersResumeExport` | interrupted | `arrow.clockwise.circle` | "Your Last Export Didn’t Finish" | nil (the card's interrupted line has the counts) | warning |
| 4 | `!hasDestination` | needsFolder | `externaldrive.badge.plus` | "Choose Where to Save" | "Pick a folder on your external drive to start." | accent |
| 5 | `.completed` and `failedCount > 0` | finishedWithProblems | `exclamationmark.triangle` | "Finished with Problems" | nil | warning |
| 6 | `.failed` | stopped | `xmark.octagon` | "Export Stopped" | nil | danger |
| 7 | `.cancelled` | cancelled | `xmark.circle` | "Export Cancelled" | nil | neutral |
| 8 | `newPhotos` with `count > 0 \|\| isAtLeast` | newPhotos | `photo.badge.plus` | sentence-case `NewPhotosText.countPhrase(status)`, e.g. "1,243 new photos" | "Since your last export \(when)." | accent |
| 9 | `newPhotos` with count 0 | upToDate | `checkmark.circle` | "Up to Date" | "Last export \(day)." | success |
| 10 | `.completed` | complete | `checkmark.circle` | "Export Complete" | last export text if known | success |
| 11 | otherwise | ready | `arrow.down.circle` | "Ready to Export" | `readySummary` (pass `model.onDriveSummaryText`, sentence-cased) | accent |

`when` and `day` come from `NewPhotosText.dayPhrase(_:now:)` (already internal): `when = isRelative ? text : "on \(text)"`. Add these as `extension NewPhotosText` **in BackupHero.swift**, not in Model/NewPhotos.swift, so `statusLine` and its tests stay untouched.

`Tone.color`: accent → `Color.accentColor`, success/warning/danger/neutral → `Tokens.Status.*` (neutral uses `Color.gray` for the tile, since `.secondary` isn't a fill).

(b) The view:

```swift
/// The top of the Backup pane: what's going on, in one line, with the one thing to do about it.
struct BackupHero: View {
    @Environment(ExportModel.self) private var model
    let total: Int?

    var body: some View {
        let content = BackupHeroContent.make(/* values from model, see table */)
        VStack(alignment: .leading, spacing: Tokens.Space.l) {
            HStack(alignment: .center, spacing: Tokens.Space.m) {
                IconTile(symbol: content.symbol, tint: content.tone.color, size: Tokens.Tile.hero)
                VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                    Text(content.title)
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle = content.subtitle {
                        Text(subtitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            // Progress, status line and run controls: unchanged logic. In idle it hides its own
            // counts and status line unless the run was interrupted, because the hero says it.
            ProgressCard(showsIdleSummary: content.kind == .interrupted)

            // Exactly today's condition and action from BackupPane, moved here.
            if !model.isExporting, model.autoResume == nil, !model.offersResumeExport {
                primaryButton(isUpToDate: content.kind == .upToDate)
            }
        }
        .padding(.vertical, Tokens.Space.s)
    }
}
```

`primaryButton` uses today's code from BackupPane lines 133–139 verbatim (title `model.primaryExportTitle(total:)`, action `model.performPrimaryAction()`, `.disabled(!model.primaryExportEnabled(total:))`, `.help(model.primaryExportHelp ?? "")`), with `.controlSize(.large)`. Style: `.borderedProminent` normally, and `.bordered` when `isUpToDate`. When everything is exported, the button stays available but stops shouting. That is the only style rule. Write it as two branches in a `@ViewBuilder`, not as a ternary on `ButtonStyle` (the types differ).

**Hero background** (colourful, meaningful, not decorative): on the hero's Section, add `.listRowBackground(heroBackground(content.tone))`, where

```swift
@ViewBuilder
func heroBackground(_ tone: BackupHeroContent.Tone) -> some View {
    let fill = tone.color.opacity(0.10)
    if #available(macOS 26, *) {
        ConcentricRectangle(corners: .concentric(minimum: .fixed(Tokens.Radius.l)), isUniform: true).fill(fill)
    } else {
        RoundedRectangle(cornerRadius: Tokens.Radius.l, style: .continuous).fill(fill)
    }
}
```

If `listRowBackground` doesn't render in a grouped `Form` on macOS 14 (check the snapshot), drop the background and keep the coloured hero tile. Don't fake it with an overlay.

**ProgressCard change** (`ProgressCard.swift`): add `var showsIdleSummary = true`. When `model.phase == .idle && !showsIdleSummary`, skip the counts `HStack` (lines 28–36) and the `status` view. Everything else (percent, bar, Resume Now / Don't Resume, Resume Export / Start New Export, Pause / Cancel) is unchanged. The default `true` keeps every other caller identical.

**BackupPane.swift**: rebuild `form` in this order (move code, don't rewrite it):
1. `Section { BackupHero(total: total); if model.authorization == .limited { LimitedAccessNotice() } }` with no header, plus the `.listRowBackground` above.
2. **Save To**: `destinationRow`, destination issue, `spaceNeededRow`, storage warning, then the **`DriveSummaryRow`** (moved from the old Export section; it describes the drive). Header `SectionTitle(title: "Save To", symbol: "externaldrive", tint: Tokens.Tint.drive)`.
3. **Folders and Files**: unchanged content, tint `Tokens.Tint.folders`.
4. **Backup Tools** (when a destination is set): unchanged, tint `Tokens.Tint.tools`.
5. **Export History**: unchanged (`ExportHistoryView`; its tile becomes `Tokens.Tint.history`).
6. **Activity**: unchanged (tile `Tokens.Tint.neutral`).

Delete the old "Export" section (header, `ProgressCard()`, the primary button and the "Last Export" `LabeledContent`). Its parts now live in the hero and in Save To. The last-export date appears in the hero subtitle (rows 9 and 10). Keep `.sheet(item: manualCheckBinding)`, `.task(id:)`, and the layout `confirmationDialog` exactly where they are.

`destinationRow`: give the name/path `VStack` `.layoutPriority(1)` and both texts `.lineLimit(1)` (the name already has it), so the folder name never wraps to three lines.

`NewPhotosStatusLabel` becomes unused by the Backup pane. Leave the type in place (the menu bar may use it, see P3-1). Delete it only if nothing references it after the change.

Unit tests: **new** `UncloudTests/BackupHeroContentTests.swift`, one test per table row, plus a precedence test (offersResume + newPhotos → interrupted; paused + newPhotos → exporting/paused).

Acceptance:
- At the default 1000×700 window, with new photos, the hero (tile, "1,243 new photos", "Since your last export on 17 Sep.", **Export New Photos** as a large prominent button) is the first thing in the pane, with no scrolling.
- An interrupted run shows the orange hero "Your Last Export Didn’t Finish", the card's line with counts, and **Resume Export** (prominent) next to Start New Export (bordered). There's no second primary button.
- Idle shows no "0%", no empty bar and no "0 of N items".
- Up to date shows a green hero and a non-prominent button.
- VoiceOver reads the hero as one heading ("1,243 new photos, Since your last export on 17 Sep.") followed by the button.
- `NewPhotosText.statusLine` and its tests are unchanged. The existing ExportModel tests pass.

#### P1-3. Clean Up iCloud: clear, calm hierarchy

`CleanupView.swift`, `CleanupGridView.toolbar` and `LibraryWindow` sidebar:
1. **Toolbar Delete is no longer the primary action.** Replace lines 220–227:
   ```swift
   Button {
       cleanup.requestConfirmation()
   } label: {
       Label(deleteTitle, systemImage: "trash")
   }
   .labelStyle(.titleAndIcon)
   .buttonStyle(.bordered)
   .disabled(!cleanup.canRequestConfirmation)
   .help(deleteHelp)
   ```
   No `.tint(.red)`, no `.borderedProminent`. The trash glyph and the "…" carry the meaning. In Library mode, nothing in the toolbar is prominent. The deliberate, typed confirmation sheet is where red appears.
2. **Keep the confirmation sheet's red prominent Delete** (`CleanupConfirmationSheet`). It is the moment of commitment, it's gated by the typed number, and Return never triggers it. Change only `.padding(20)` → `Tokens.Sheet.padding` and `.frame(width: 420)` → `Tokens.Sheet.narrow`. Keep the orange "not backed up" warning. Per the HIG this is the one place where the caution symbol is justified.
3. **Mode picker into the toolbar**: move `modePicker` into `ToolbarItem(placement: .principal)`. Remove its `.padding(…)` modifiers there and keep `.pickerStyle(.segmented)`, `.labelsHidden()` and `.disabled(cleanup.isRunning)`. The `safeAreaInset(edge: .top)` keeps only the status card. The "Items are permanently removed by iCloud after 30 days." note moves to `.navigationSubtitle(...)` in Recently Deleted mode (see P1-4).
4. **Sidebar row**: `IconTile(symbol: "icloud", tint: Tokens.Tint.iCloud, size: Tokens.Tile.sidebar)` instead of the red trash. The pane is about iCloud; the trash belongs to the action, not the place.
5. Gate `.animation(.smooth, value: showsStatus)` on Reduce Motion: read `@Environment(\.accessibilityReduceMotion)` and pass `reduceMotion ? nil : .smooth`.

Acceptance: in Library mode, no red appears until the confirmation sheet opens. The Delete button shows a trash glyph and "Delete 12 from iCloud…". Recently Deleted mode still has the prominent "Recover 12 Items". The picker sits centred in the toolbar and still locks while a run is going. All `ICloudCleanup` calls are unchanged.

#### P1-4. Window titles and toolbar grouping (Library and Clean Up)

- `LibraryWindow.swift` detail: add `.navigationTitle("Library")`, `.navigationTitle("Backup")` and `.navigationTitle("Clean Up iCloud")` to the three detail views (inside the `switch`).
- `LibraryView.swift` / `LibraryToolbar`: remove the `Text(countText)` item from the group. Instead, on `LibraryView`, add `.navigationSubtitle(countText)` (macOS 11+; it shows under the title in the toolbar). Move `countText` to `LibraryView` or a small helper. The logic is unchanged.
- Split `LibraryToolbar` into `ToolbarItem(placement: .primaryAction)` items in this order: Select menu; progress ring / "Waiting to resume" (when shown); then, on macOS 26 only, `ToolbarSpacer(.fixed, placement: .primaryAction)`; then the prominent primary button as its own `ToolbarItem(placement: .primaryAction)`. Keep `.buttonStyle(.borderedProminent)`. In a macOS 26 toolbar it already renders as tinted glass; don't switch it to `.glassProminent` (no visible gain, and one code path for both OS versions).
- `CleanupGridView.toolbar`: the same treatment. The count goes to `.navigationSubtitle` (in Recently Deleted mode, subtitle = count, then " · Items are permanently removed by iCloud after 30 days."). Order: Select, Filter, [`ToolbarSpacer(.fixed)` on 26], Delete/Recover.
- Backup pane: `.navigationSubtitle(model.destination?.displayName ?? "")`.

Acceptance: the window title reads "Library", "Backup" or "Clean Up iCloud", and the Window menu still lists "Uncloud" (the `Window` scene title). On macOS 26 the primary button sits in its own glass group at the trailing edge. On 14 the order is the same, without the spacer. VoiceOver reads the count via the window subtitle.

### P2 — consistency and polish

#### P2-1. Menus (ExportCommands.swift, UncloudApp.swift)
- In `CommandGroup(before: .sidebar)`, add `Button("Clean Up iCloud") { model.pane = .cleanup }.keyboardShortcut("3")` after Backup.
- In `UncloudApp.body`, change `.commands { ExportCommands(...) }` to `.commands { SidebarCommands(); ExportCommands(...) }`, which adds View › Show/Hide Sidebar (⌃⌘S).
- Acceptance: View menu shows Library ⌘1, Backup ⌘2, Clean Up iCloud ⌘3, then the sidebar toggle. No other menu changes.

#### P2-2. Icon tile consistency (IconTile.swift and every caller)
- `IconTile`: corner radius `size * Tokens.Radius.tileRatio`. Read `@Environment(\.colorSchemeContrast)`; when it's `.increased`, add `.overlay { RoundedRectangle(cornerRadius: …, style: .continuous).strokeBorder(.primary.opacity(0.35), lineWidth: 1) }`. Keep `.accessibilityHidden(true)`.
- Sizes: sidebar rows and the account footer use `Tokens.Tile.sidebar`; `SectionTitle` uses `Tokens.Tile.section`; `BenefitsCarousel` (36) and `HowItWorksSteps` (28) use `Tokens.Tile.feature`; the hero uses `Tokens.Tile.hero`; `ExportStartedBanner` uses `Tokens.Tile.section`.
- Tints: Library row `Tokens.Tint.library` (pink, was purple); Backup row `Tokens.Tint.drive`; Clean Up row `Tokens.Tint.iCloud` (P1-3); footer iCloud → `Tokens.Tint.iCloud`, Photos → `Tokens.Tint.library`; section titles as listed in P1-2. Nothing uses `.accentColor` as a tile tint except the hero's accent tone and the Export Started banner.
- Acceptance: `grep -n "IconTile(" Uncloud/Views` shows only `Tokens.Tile.*` sizes and `Tokens.Tint.*` / hero tints. No hue appears with two meanings.

#### P2-3. Accessibility pass
- `ProgressCard`: `.contentTransition(reduceMotion ? .identity : .numericText())`, with `@Environment(\.accessibilityReduceMotion)`.
- The hero is one combined element with the header trait (P1-2). Add to the Backup sidebar row `.accessibilityValue(...)`: "\(n) new photos" when the new-photos badge shows, and "\(p) percent exported" while exporting. The badge alone may not be spoken; this couldn't be verified offline.
- Reduce Transparency: no code needed. Both `.regularMaterial` and `glassEffect` follow the system setting. Verify by toggling it in the snapshot harness (`NSWorkspace` can't be forced; check manually in the app later, see section 5).
- Contrast: hero titles use `.primary`; coloured text appears only in status labels that already use system colours. Don't add accent-coloured body text in dark mode with purple (2.93:1 for `#7C3AED`). The asset's dark value `#8B5CF6` gives 3.94:1, fine for bold/large and UI glyphs only.

#### P2-4. Liquid Glass adoption points (all behind `#available(macOS 26, *)`)
1. **Free, already active**: floating sidebar, toolbar glass grouping and scroll edge effect, glass sheets, capsule large buttons, taller controls. Action: remove nothing; just don't add backgrounds behind bars or sheets.
2. **ExportStartedBanner** (LibraryWindow.swift): a transient control over content, so glass fits. On 26, replace `.background(.regularMaterial)` + bottom `Divider()` with `.padding(Tokens.Space.s)` around the banner and `.glassEffect(.regular, in: .rect(cornerRadius: Tokens.Radius.l))` on the banner's HStack, so it floats inset from the edges. On 14, keep today's look. Use the gating snippet from 1.4.
3. **Toolbar spacers**: P1-4.
4. **Not adopted, on purpose**: `.glassEffect` on the Backup hero, on cards or on `IconTile`s (content layer, per HIG: "Don't use Liquid Glass in the content layer"); `.glassProminent` for in-content buttons; `GlassEffectContainer` / `glassEffectID` (there are no adjacent custom glass elements to merge or morph); `backgroundExtensionEffect()` (there's no full-bleed artwork next to the sidebar, and the grid scrolls); `.clear` glass.
5. **Scroll edge**: leave the automatic style. Only if the macOS 26 render shows the Clean Up status card or Library thumbnails fighting the toolbar, add `.scrollEdgeEffectStyle(.hard, for: .top)` on that one grid (one per view, per WWDC 356).

#### P2-5. Sheet tokens
Replace literal paddings and widths with `Tokens.Sheet.*`: VerifyBackupSheet 500 → `regular` (520), FindDuplicatesSheet `wide`, FreeUpSpaceSheet `regular` (keep its height), ICloudSignInSheet `narrow`, CheckDriveResultsSheet and ExportSessionDetailView padding 16 → `Tokens.Sheet.padding`, GettingStartedView padding 24 → keep (onboarding reading width), Cleanup sheets `narrow`. In FindDuplicatesSheet, give the "Move N Copies to Trash…" button `Label(…, systemImage: "trash")`; keep its role and non-prominent style.
Acceptance: no `.padding(16|20|24)` or `.frame(width: 4xx|5xx)` literal remains in sheet roots (except GettingStarted).

### P3 — nice to have, only if time allows

1. **Menu bar status line** (`MenuBarContent.statusText`): before the last-backup case, add `if model.offersResumeExport { return "Export didn’t finish. Open Uncloud to resume." }` and `if let s = model.newPhotosStatus, s.count > 0 || s.isAtLeast { return NewPhotosText.statusLine(s, now: .now) }`. Display text only; no new menu items.
2. **Clean Up status card on 26**: replace `.background(.regularMaterial)` + `Divider()` with the plain content background (`.background(.background)`) so it doesn't look like a second toolbar under the glass one. On 14, keep it.
3. **Backup toolbar**: move "Show in Finder" (folder symbol) from `destinationRow` to `ToolbarItem(placement: .primaryAction)` on the Backup pane, with `.help` and `.accessibilityLabel`. This frees the destination row for name, path and Change Folder….

---

## 4. Out of scope (keep it lean)

- **No behaviour changes.** Every `disabled(...)`, `if` that shows a button, title function (`primaryExportTitle`, `NewPhotosTitle.primary`), action (`performPrimaryAction`, `startOrResume`, `startNewExport`, `exportAll`, `cancel`, `pause`, `cleanup.*`) and confirmation flow stays exactly as it is. Buttons move and change style only.
- **Nothing in `Uncloud/Export/**`**, `ICloudCleanup`, `BackupTools`, `DuplicateCleanup`, manifest, checksum or deletion logic.
- **No new navigation.** Sidebar panes, sheets, Settings sections and the account footer stay. No inspector, no tab bar, no onboarding.
- **No custom fonts**, gradients, shadows or animated decoration. No glass on content.
- **No change to the shipping `AccentColor` asset** until the user picks a variant from the renders.
- **No copy rewrites** beyond the hero strings in P1-2 and the subtitle/menu-bar strings above. Error, confirmation and history text stays.
- Settings, Landing, Sign In and PhotosAccess layouts don't change (tokens only).

---

## 5. Snapshot checklist

Harness: reuse the offscreen key-window renderer in `UncloudTests/DesignSnapshotTests.swift` / `NewPhotosSnapshotTests.swift`. Add a `variant: AccentVariant` loop, and apply `.accentVariant(variant)` to the rendered root. Write PNGs to `scratchpad/ui-refresh/before/` and `scratchpad/ui-refresh/after/`, and **also** `Attachment.record` them (the sandbox refused the scratch folder last time, leaving the snapshot folders empty). Name files `<screen>-<state>-<light|dark>-<blue|purple>.png`. Tests already set `ICloudAccount.appleID` (UserDefaults, not Keychain) and restore it. Don't touch the Keychain, `~/Library/Containers` or `/Volumes`.

Render "before" (current code) and "after", each in light and dark × blue and purple (4 images per row):

| Screen | States |
|---|---|
| Backup pane, 560×1480 and 1000×700 (window-height check) | new photos (1,243); up to date; interrupted (Resume Export)*; never exported (ready); no folder |
| Backup hero alone (`BackupHeroContent` → header view) | every row of the P1-2 table, including exporting 42%, paused, waiting to resume, finished with problems, stopped |
| Library pane with toolbar (window host, not ImageRenderer) | grid with 12 selected (count in subtitle); while exporting (progress ring); Export New Photos as primary |
| Clean Up iCloud with toolbar | Library mode, 10 selected (bordered Delete with trash); Recently Deleted mode with Recover; delete confirmation sheet; deleting progress; finished summary |
| Sidebar | default; with new-photos badge; with export % badge; Increase Contrast on (tile stroke) |
| Export Started banner | shown over the Library (glass on 26 / material on 14) |
| Sheets | Verify Backup, Find Duplicates (found), Free Up Space, Check Drive results, Sign In, Session Detail |
| Landing | default (not rendered to disk before; render it now as a baseline) |
| Settings | default |

\* The interrupted and exporting states need `phase`/`hasIncompleteRun`, which are `private(set)` on `ExportModel`. Don't add setters. Render those states through `BackupHeroContent` and the hero header only, and leave the full-pane render to the manual check below.

Manual check in the running app, by the user or the orchestrator (not by the implementer; this plan does not launch the app): on macOS 26 or later, the sidebar and toolbar glass, the toolbar spacer, Reduce Transparency, Increase Contrast, Reduce Motion, VoiceOver reading the hero and Backup row, and whether the shipping `AccentColor` (indigo) or system blue is what users actually see with Multicolor.

---

## 6. Things I couldn't verify

- Apple's HIG and documentation pages render client-side. I read the HIG through its JSON data endpoints and the WWDC session pages. The three Liquid Glass documentation pages returned only titles, so API names come from the local SDK interface instead (more authoritative for this Xcode).
- How Liquid Glass actually looks in this app on macOS 26/27. There are no renders of the window chrome, toolbar or sidebar, and I didn't launch the app.
- Whether `.listRowBackground` draws inside a grouped `Form` on macOS 14 (P1-2 has a fallback).
- Whether toolbar `.badge` / sidebar badges are spoken by VoiceOver (P2-3 adds an explicit value either way).
- Why the renders show system blue instead of the indigo `AccentColor` asset (most likely the offscreen test host). The variant switch makes this moot for comparisons.
