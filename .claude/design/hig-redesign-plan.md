# Uncloud HIG redesign plan: features, flow, menus, copy

Status: review and plan only. No app code was changed. Author: lead product designer (Opus), 2026-10-19.
Branch `feature/duplicates-and-icloud-cleanup` at 4794407 (v0.1.10).

Owner's request: "review app's features, positioning of these features, logical flow and also use Apple's Design
system to rebuild menus, content, texts, intro page basically everything".

This plan builds on `polish-plan.md` (glossary §2, design direction §1), `account-paywall-plan.md`,
`account-menu-plan.md` and `landing-page-plan.md` (brand voice: short, plain, calm; hero "Take Your Photos Home").
Where they disagree, **this file wins** for information architecture, onboarding, menus and the copy listed in §4.
Everything those plans shipped and this plan doesn't mention stays as it is.

HIG sources, read for this plan (developer.apple.com/design/human-interface-guidelines/…):
`the-menu-bar`, `sidebars`, `toolbars`, `settings`, `onboarding`, `managing-accounts`, `writing`, `offering-help`,
`alerts`, `sheets`, `accessibility`. Each recommendation below cites its page as **[HIG: page]**.

Files another agent is editing right now, so **not touched until the quick update lands**:
`ICloudExportEngine.swift`, `ExportModel.swift`, `ExportCommands.swift`, `BackupHero.swift`, `photo_bridge.py`.
Chunks that touch them are marked **⏳ after quick-update lands**.

---

## 0. Top findings

1. **Accounts come before any value.** A signed-out user sees only the Welcome page. No sidebar, no menus, and
   Export (the free feature) is out of reach. HIG says "Ask people to create an account only if your core
   functionality requires it" and "Delay sign-in for as long as possible" **[HIG: managing-accounts]**. Settings even
   says "Export is free without an account", which the app doesn't allow. → Decision D1. Smaller fix now: make the
   Welcome page shorter and give it one button.
2. **Two front doors that say different things.** First Welcome ("Take Your Photos Home" plus 8 feature rows),
   then the Export landing ("Your Photos, on Your Own Drive"). That's two heroes in a row before the user does
   anything **[HIG: onboarding: "fast, fun, and optional"]**.
3. **The sidebar starts at the wrong place, and its first item is a verb.** "Export" is a photo picker grid. The
   home screen (status plus the one button) is "Backup", second in the list, and the app always opens on Export
   (`ExportModel.pane = .export`). The routine job ("export my new photos") is one click deeper than it should be.
   Sidebar items should be places (nouns) **[HIG: sidebars]**.
4. **Choosing a locked sidebar row opens the paywall by itself.** A modal sheet opens just because the user looked.
   The locked pane already has its own "Get Uncloud Plus…" button **[HIG: onboarding: "Prefer letting people
   experience your app … before prompting them for … purchases"; sheets]**.
5. **"New Photos" is listed as a paid feature, but the count is free.** Only reminders are paid. The paywall already
   calls it "Reminders", while Welcome and the locked rows say "New Photos". Rename it to **New Photo Reminders**
   everywhere.
6. **Two "free up space" features in different places.** Free Up Space (this Mac) sits in Backup › Tools and is
   disabled for iCloud users. Clean Up iCloud is a sidebar pane. Cross-link the two, and hide the Free Up Space
   button where it can never work.
7. **Settings mixes app-wide settings with one task's choices.** The backup folder is in Settings › General and in
   the Backup pane. HIG says task-specific options belong in the task, not in Settings **[HIG: settings]**.
   "General" is also both a tab and a section inside that tab.
8. **Copy says "we" in several places.** HIG: "Avoid using we altogether" **[HIG: writing]**. A few strings still
   say "copy" or "icloudpd" (glossary violations).
9. **Coloured text fails contrast.** Orange and red text is used for warnings (`.foregroundStyle(.orange/.red)` on
   text). Keep the colour on the symbol, and use primary or secondary colour for the words **[HIG: accessibility]**.
10. **Menus are mostly right.** The custom menu sits between View and Window, items use title case, and ellipses are
    correct. Five fixes are needed: View-menu pane order and names, a clearer "Check Now", a stable title for the
    Backup menu's primary item, Help menu links, and the menu bar extra's "Export Now" **[HIG: the-menu-bar]**.

---

## 1. Feature and positioning review

### 1.1 What each feature is for

| Feature | What it's for | Who needs it | Lives now | Free/Plus | Problems |
|---|---|---|---|---|---|
| **Export** | Copy full-quality originals from iCloud Photos or Photos on This Mac to a drive | Everyone, once and then routinely | Sidebar "Export" (grid), primary button in Backup hero, Backup menu ⌘R | Free | Verb as a place name. The grid is the advanced path (pick photos); most people want "everything" or "new". Opens first. |
| **Backup status / hero** | "Is my backup up to date?" plus the one button | Everyone, every visit | Sidebar "Backup" (2nd) | Free (count) | Should be home and first. |
| **Backup folder, Folders, XMP** | Where photos go and how they're organized | Everyone, once | Backup pane, File menu, Settings › General | Free | Duplicated in Settings. |
| **Check Now** (recount) | Quick recount of what's on the drive | Rarely, after moving drives | Backup › drive row, Backup menu "Check Now" | Free | "Check Now" means nothing in a menu without context. Easily confused with Verify Backup. |
| **Export History, Activity** | What happened | Troubleshooting | Backup pane bottom | Free | Fine. |
| **New-photos count** | "1,243 new photos" | Everyone | Hero, sidebar badge, menu bar extra | Free | Fine. |
| **New Photo Reminders** | Notification when new photos wait and the drive isn't connected | Plus users without automatic backups | Settings › General › New Photos | Plus | Called "New Photos" on Welcome and the lock rows, "Reminders" on the paywall. |
| **Automatic Backups** | Export on drive connect or daily | Plus | Settings › General › Automatic Backup | Plus | Fine. Section title should be the plural, as in the glossary. |
| **Browse Backup** | Look through the backup by date, map, places | Plus | Sidebar (3rd), ⌘3 | Plus | Symbol `map` though the default view is Dates. Auto-paywall on select. |
| **Verify Backup** | Prove every file is intact (checksums) | Plus, occasionally | Backup › Tools, Backup menu | Plus | Fine. |
| **Find Duplicates** | Remove extra copies on the drive | Plus, occasionally | Backup › Tools, Backup menu | Plus | Fine. |
| **Free Up Space** | Remove backed-up photos from Photos on this Mac | Plus, Photos on This Mac source only | Backup › Tools (disabled for iCloud), Backup menu | Plus | Disabled button with no visible reason for iCloud users. Symbol `externaldrive.badge.minus` suggests the drive, not the Mac. |
| **Clean Up iCloud** (+ Recently Deleted, Recover) | Delete backed-up photos from iCloud, and undo | Plus, iCloud source | Sidebar section "iCloud", ⌘4, Edit › Delete from iCloud… | Plus | Auto-paywall on select. For the Photos on This Mac source it only says "switch". |
| **Uncloud account** | Plan and billing | Everyone (today: required) | Welcome wall, avatar popover (sidebar titlebar), app menu, Settings › Account | — | Required before Export (D1). |
| **Apple Account / source** | Which library photos come from | Everyone | Sidebar footer menu, File › Photos From, Sign In/Out of iCloud | — | Footer is at the bottom of the sidebar ("Avoid putting critical information or actions at the bottom of a sidebar" **[HIG: sidebars]**). Acceptable, because File menu and the Library title also carry it after Q1. |

### 1.2 Recommended information architecture

**Sidebar** (max two levels, nouns, familiar symbols, accent-coloured icons **[HIG: sidebars]**):

| # | Row | Symbol | Shortcut | Detail title | Notes |
|---|---|---|---|---|---|
| 1 | **Backup** | `externaldrive` | ⌘1 | "Backup" | Home. Default pane on launch. Hero, folder, folders, tools, history. Badge: % or new count (unchanged). |
| 2 | **Library** | `photo.on.rectangle` | ⌘2 | The source's name: "iCloud Photos" or "Photos on This Mac" | Was "Export". The grid for picking photos. Its toolbar keeps the Export button. |
| 3 | **Browse Backup** | `photo.stack` | ⌘3 | "Browse Backup" | Lock while locked. No auto-paywall. |
| — | Section **iCloud** | | | | |
| 4 | **Clean Up iCloud** | `icloud` | ⌘4 | "Clean Up iCloud" | Lock while locked. No auto-paywall. |

Why "Library": it's what the pane shows (your photo library), it's a noun, and it doesn't clash with the action
"Export", which stays the name of the button and the menu command. "Photos" alone would read as Apple's app.

**Toolbar vs menu vs Settings** **[HIG: toolbars, the-menu-bar ("list them in the menu bar" even when elsewhere), settings]**:

| Thing | Toolbar | Menu bar | Settings | In pane |
|---|---|---|---|---|
| Export (primary) | Library (prominent) | Backup › Export … ⌘R | — | Backup hero |
| Pause/Cancel | — | Backup menu | — | Progress card |
| Choose/Show backup folder | Backup: Show in Finder | File | **removed** (status line only) | Backup › Backup Folder |
| Folders, XMP | — | — | — | Backup › Folders |
| Check Now / Verify / Duplicates / Free Up Space | — | Backup menu (tools group) | — | Backup › Tools |
| Source, Apple Account sign-in | — | File › Photos From, Sign In/Out of iCloud… | — | Sidebar footer |
| Browse view and sort | Browse (segmented, sort, search) | View › Sort | — | — |
| Delete from iCloud / Recover | Clean Up (trash button) | Edit › Delete from iCloud… ⌘⌫ | — | — |
| Automatic backups, reminders | — | — | **Backups** tab | Hero mentions them |
| Open at login, menu bar item | — | — | **General** tab | — |
| Uncloud account, plan | Sidebar avatar | App menu (Account Settings…, plan item, Sign Out…) | **Account** tab | — |

---

## 2. Logical flow review

Today's flow, with friction (F) and fixes (→):

1. **First launch → Welcome.**
   F1. Eight feature rows plus two buttons ("Create Account" / "Sign In") that lead to the same email-code flow (the
   server ignores the intent: `LiveAccountService.requestCode` always sends `create_user: true`).
   → Three rows (Export · Free, Stay Up to Date · Plus, Keep It Tidy · Plus) and **one** button, **Continue with
   Email**, which names the method ("Always identify the authentication method" **[HIG: managing-accounts]**). Chunk A1.
   F2. Sign-in is required before the free feature (D1).
   → Recommended: add **Continue Without an Account** (D1, chunk A4, Opus-sized).
2. **Sign-in (email → code).** Mostly good: one field, autofill content types, auto-verify on the 6th digit, Esc goes
   back. F3: "we" copy. → §4.
3. **Choose source.** After sign-in the window shows the Export landing with a second hero.
   F4. Repeated hero, and the user is on a pane called "Export" with nothing to export.
   → After Q1 the app opens on **Backup**. While no source is ready, Backup shows the landing (same `LandingView`,
   headline changed to "Connect Your Photos", a task title, not a second marketing hero). Chunks B3, Q1.
4. **Choose folder.** The Export toolbar's button says "Choose Backup Folder…" until a folder is picked, and the
   Backup hero says "Choose a backup folder". Good, but the user who picked a source is still on the grid.
   → With Backup as home, the hero's `needsFolder` state is the next step in view, with no pane switch.
5. **First export.** The progress moves to Backup, and the announcement says "Progress is in Backup". With Backup
   as home, the user is already there. Long first runs keep the existing card.
6. **Routine new photos.** Hero "1,243 new photos" + **Export 1,243 New Photos**. The sidebar badge and menu bar
   extra repeat the count. Slowness is being fixed by the quick update (other agent).
   F5. Menu bar extra says "Export Now" while everything else says "Export New Photos". → B5.
   F6. Settings' "Remind me about new photos" lives under "New Photos" in the General tab. → B2 moves it to a
   **Backups** tab, beside Automatic Backups.
7. **Cleanup.**
   F7. Free Up Space is a disabled button for iCloud users, with the reason only in a tooltip. → Hide it in the pane
   unless the source is Photos on This Mac. The menu item stays visible and disabled, as **[HIG: the-menu-bar]**
   expects. Chunk B4.
   F8. Clean Up iCloud for a Photos on This Mac user is a dead end ("Switch to iCloud Photos"). → Add a second
   button, **Free Up Space on This Mac…**, that opens the existing sheet (via `account.require(.freeUpSpace)`). Chunk B5.
   F9. Choosing a locked pane pops the paywall. → Show the locked view only. Chunk B1.

---

## 3. HIG audit by area

### 3.1 Menu bar **[HIG: the-menu-bar]**

Current: App (About, Settings…, Account Settings…, plan item, Sign Out of Uncloud…, …), File (Choose Backup Folder… ⌘O,
Show Backup Folder in Finder ⇧⌘O, Photos From ▸, Sign In/Out of iCloud…), Edit (+ Deselect All ⇧⌘A, Delete from
iCloud… ⌘⌫), View (Export ⌘1, Backup ⌘2, Browse Backup ⌘3, Clean Up iCloud ⌘4, Sort ▸, sidebar items), **Backup**
(custom), Window, Help (Getting Started, Show Diagnostic Logs in Finder).

What's right: the custom menu sits between View and Window and has a one-word title. Items use title case. The
ellipsis appears only when more input is needed. Destructive Delete sits in Edit with ⌘⌫ and only opens a
confirmation. No ⌘P for Pause. A Window menu comes from the system.

Fixes (all in `ExportCommands.swift`, **⏳ after quick-update lands**, chunks Q1/Q2):
- View: pane items follow the new sidebar order and names: **Backup ⌘1, Library ⌘2, Browse Backup ⌘3, Clean Up
  iCloud ⌘4**. They mirror the sidebar ("reflect your app's hierarchy").
- Backup menu, primary item: keep the dynamic title (it matches the hero button), but when no folder is chosen
  the File menu already has "Choose Backup Folder…". So the Backup-menu item reads **Export** + the existing
  title only when a folder exists. When `model.destination == nil`, show **Export All Photos** disabled instead of
  a second "Choose Backup Folder…". (Two identical items in two menus confuse people.)
- Backup menu: rename **Check Now** → **Check Backup Folder** (a menu item needs its object; no ellipsis, because
  it runs at once). Group: [Export, Export All Photos] — [Pause/Resume Export, Cancel Export] — [Check Backup Folder,
  Verify Backup…, Find Duplicates…, Free Up Space…].
- Help: after "Getting Started", add **Uncloud Website** (opens `AccountLinks` site or
  `https://uncloud-app.vercel.app`) and **Contact Support…** (mailto, ellipsis because it opens Mail's compose
  window). Keep "Show Diagnostic Logs in Finder" last, after a divider **[HIG: offering-help]**.
- Menu bar extra (`MenuBarContent.swift`, not blocked): **Export Now** → **Export New Photos**. Order: status
  lines, Export New Photos, Open Uncloud, —, Settings…, Quit Uncloud. That's already the order.

### 3.2 Sidebar **[HIG: sidebars]**
- Order, names and symbols per §1.2 (Q1). Icons stay in the accent colour. No fixed colours.
- Locked rows keep the trailing lock and the `accessibilityValue("Requires Uncloud Plus")`. Selecting one shows the
  locked view, **not** the paywall (B1).
- Footer (source + Apple Account): keep. It's status plus a menu, and the same commands are in the File menu. Its
  accessibility label is already good.
- Account avatar in the sidebar titlebar: keep.

### 3.3 Toolbars **[HIG: toolbars]**
- Library: Select All/Deselect All (text), progress ring or "Waiting to Resume", spacer, **Export …** prominent.
  Fine. Change "Waiting to Resume" from orange text to a plain label with an orange symbol (accessibility, B5).
- Backup: Show in Finder (icon + help). Fine.
- Browse: segmented Dates/Map/Places in principal, sort menu, search. Fine.
- Clean Up: Library/Recently Deleted segmented in principal, Select All, filter menu, Delete from iCloud…. Fine.
- No Settings button in any toolbar ("Avoid adding settings buttons to a window's toolbar" **[HIG: settings]**).
  Already true.

### 3.4 Sheets and alerts **[HIG: sheets, alerts]**
- Sheets use `SheetScaffold`/`FormSheetScaffold`: title, content, right-aligned footer, Cancel = `.cancelAction`,
  default = `.defaultAction`, destructive actions never default. Good. Keep.
- Confirmation dialogs (`Sign Out of iCloud?`, `Sign Out of Uncloud?`, layout change, delete confirmations) have a
  title-case question title, a short message, and a destructive role. Good.
- The paywall must open only from an explicit action: a button, a menu item, or a locked tool (B1).

### 3.5 Settings window **[HIG: settings]**
New tabs (toolbar style, the window title follows the tab, the last tab is restored — SwiftUI's `TabView` in a
`Settings` scene does all three):

| Tab | Symbol | Sections |
|---|---|---|
| **General** | `gearshape` | (no section header) Open at login · Show in menu bar (+ caption) |
| **Backups** | `externaldrive` | **Automatic Backups**: Export when the backup drive connects · Export once a day · lock row · status line. **New Photo Reminders**: Remind me about new photos · How often · caption · lock row |
| **Account** | `person.crop.circle` | unchanged (only when `account.mode != .off`) |

- The "Backup folder" row with its Change… button is removed (task option, and it duplicates the Backup pane and the
  File menu). In its place is one caption under the automatic toggles: "Exports to “\(name)”." or, with no folder,
  "Choose a backup folder in Uncloud first." plus a link button **Choose Backup Folder…** (keeps today's
  open-main-window behaviour).
- `off` mode shows **General** and **Backups** tabs (no Account).

### 3.6 Onboarding / Welcome **[HIG: onboarding, managing-accounts]**
- One screen, three rows, one button (§4 A1 copy). Terms line under the button ("By continuing…").
- Optional (D1): **Continue Without an Account** as a link under the button.
- The code screen is unchanged apart from copy.
- Getting Started stays in Help ("easy for people to find if they want to view it later" **[HIG: onboarding]**).
  Its rainbow tiles become accent-coloured (polish-plan rule: colour means status).

### 3.7 Paywall **[HIG: onboarding (purchases), writing]**
- Keep the layout. Fix copy (§4) and the feature name (New Photo Reminders).
- Opens only on explicit actions (B1).
- Price, period, renewal and how to turn it off are all next to the button already. Keep.

### 3.8 Empty states **[HIG: writing: "Provide clear next steps on any blank screens"]**
Each empty state has a title-case title, one sentence, and a button that does the next step (§4 B3/B4/B5).

### 3.9 Copy rules (adds to polish-plan §2)
- **Title case**: menu items, buttons, window/sheet/dialog titles, tab names, section headers, empty-state titles.
- **Sentence case**: descriptions, captions, status lines, toggles, checkboxes and radio-button labels, tooltips
  (`.help`), and accessibility hints.
- No "we", "our" or "us" **[HIG: writing]**. Say "Uncloud" or use the passive voice ("New code sent.").
- Tooltips are at most 75 characters and start with a verb **[HIG: offering-help]**.
- Glossary additions: **Library** (the sidebar pane that shows the source's photos); **New Photo Reminders** (the
  paid feature); **Continue with Email** (the one sign-in button). Retire "Create Account" as a Welcome button.
  Keep "Delete Account" in Settings.

### 3.10 SF Symbols
| Where | Now | New | Why |
|---|---|---|---|
| Browse Backup row, PaidFeature.browseBackup | `map` | `photo.stack` | Default view is Dates, so a map is misleading |
| Free Up Space (PaidFeature, tool button) | `externaldrive.badge.minus` | `internaldrive` | It frees the Mac's disk, not the backup drive |
| Welcome "Stay Up to Date" row | — | `clock.arrow.circlepath` | Same as Automatic Backups |
| Welcome "Keep It Tidy" row | — | `sparkles` | Tidy and clean up |
| Getting Started step tints | `.blue/.purple/.teal`, Benefit rainbow | accent (`uncloudAccent ?? .accentColor`) | Colour means status |

### 3.11 Colour and materials
- Status colour goes on symbols only. Text stays `.primary`/`.secondary`. Replace literal `.red`/`.orange` with
  `Tokens.Status.danger`/`.warning`, applied to the `Label` icon only (pattern below).
- Glass stays on floating banners (macOS 26) only. Unchanged.

Pattern for a warning line (use everywhere a warning `Label` is coloured today):
```swift
Label {
    Text(warning)
} icon: {
    Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(Tokens.Status.warning)   // or .danger
}
```

### 3.12 Accessibility **[HIG: accessibility]**
- Contrast: the coloured-text fixes above.
- Locked tool buttons (`BackupToolButtons`): add `.accessibilityValue(account.allows(f) ? "" : "Requires Uncloud
  Plus")`, as the sidebar rows have.
- Welcome rows: `FeatureRow` badge is read as "free" or "plus" (lower-cased). Keep.
- Keyboard: all panes are reachable by ⌘1–⌘4, and every sheet has Esc and Return. The paywall radio rows support
  arrow keys. Good.
- Reduce Motion is honoured through `Tokens.Motion`. Good.

---

## 4. Copy deck (old → new), by file

**T** = a test asserts this string (update it in the same chunk).

### Account/AccountTypes.swift (chunk A2)
| Old | New |
|---|---|
| `welcomePlanLine` "Export is free. Everything else is Uncloud Plus, \(yearlyPrice)." | "Export is free. Uncloud Plus is \(yearlyPrice)." |
| PaidFeature.newPhotos `title` "New Photos" | "New Photo Reminders" |
| `paywallTitle` (newPhotos → "Reminders") | returns `title` for every case (**T** EntitlementGatingTests:105-108) |
| newPhotos summary "Lets you know when new photos are waiting to be backed up." | "Reminds you when new photos are waiting to be exported." |
| browseBackup summary "Look through your backup by date or on a map, no iCloud needed." | "Look through your backup by date, place or map, without iCloud." |
| freeUpSpace summary "Removes backed-up photos from this Mac to make room." | "Removes backed-up photos from Photos on this Mac to make room." |
| browseBackup symbol `map` | `photo.stack` |
| freeUpSpace symbol `externaldrive.badge.minus` | `internaldrive` |
| AccountError.server "Something went wrong on our side. Try again in a moment." | "Uncloud couldn’t finish that. Try again in a moment." |
| AccountError.noSubscription "There’s no plan to change. Get Uncloud Plus to start one." | "You don’t have Uncloud Plus yet." |

### Views/Account/WelcomeView.swift (chunk A1)
| Old | New |
|---|---|
| Subtitle "Export full-quality originals from iCloud to your own drive, then keep your backup safe, tidy and easy to browse." | "Export full-quality originals from iCloud Photos to your own drive, without filling up your Mac." |
| 8 feature rows (Export + every PaidFeature) | 3 rows: **Export** · badge "Free" · `photo.on.rectangle.angled` · "Full-quality originals from iCloud Photos or Photos on this Mac, to any drive." / **Stay Up to Date** · badge "Plus" · `clock.arrow.circlepath` · "Automatic backups, and reminders when new photos are waiting." / **Keep It Tidy** · badge "Plus" · `sparkles` · "Browse, verify and find duplicates in your backup. Free up space on this Mac and in iCloud." |
| Buttons "Create Account" (prominent) + "Sign In" | One button **Continue with Email** (prominent, default, minWidth 200) → `account.show(.signUp)` |
| — | Caption under the button (footnote, secondary): "New or returning, Uncloud emails you a sign-in code. No password needed." |
| Footer "Your photos go straight from Apple to your drive, never through Uncloud." | unchanged |

### Views/Account/AccountEmailView.swift (chunk A1)
| Old | New |
|---|---|
| Title "Create Your Uncloud Account" / "Sign In to Uncloud" | "Continue with Email" (both intents) |
| Explanation (signUp) "Enter your email and we’ll send you a 6-digit code. There’s no password to remember." / (signIn) "Enter the email you used for your Uncloud account and we’ll send you a code." | "Enter your email to get a 6-digit code. If you’re new, the code creates your Uncloud account." (both) |
| Terms line "By creating an account, you agree to the …" (signUp only) | "By continuing, you agree to the [Terms of Use] and [Privacy Policy]." (both intents) |
| Switch links "Already have an account? Sign In" / "New to Uncloud? Create Account" | removed |
| "Sending code…" | unchanged |

### Views/Account/AccountCodeView.swift (chunk A1)
| Old | New |
|---|---|
| "Enter the 6-digit code we sent to " + email + "." | "Enter the 6-digit code sent to " + email + "." |
| "We sent a new code." | "New code sent." |

### Views/Account/PaywallSheet.swift (chunk A2)
| Old | New |
|---|---|
| "Already Subscribed? Refresh" | "Already Subscribed? Check Again" |
| `.help("Looks up your plan again.")` | `.help("Check your plan again")` |
| "We couldn’t find a plan for \(email)." | "No Uncloud Plus plan found for \(email)." |
| "No plan yet. If you finished checking out, give it a moment, then check again." | unchanged |

### Views/Account/AccountSettingsForm.swift (chunk A3)
| Old | New |
|---|---|
| "Sign in to use Uncloud Plus on this Mac. Export is free without an account." | "Sign in to use Uncloud Plus on this Mac." (keep the old text only if D1 = yes) |
| Buttons "Sign In…" + "Create Account…" | One button "Continue with Email…" → `account.show(.signUp)` (same window activation as today) |
| "Already Subscribed? Refresh" | "Already Subscribed? Check Again" |

### Views/Account/AccountButton.swift, Account/AccountSummary.swift (chunk A3)
| Old | New |
|---|---|
| `.help(isExporting ? "Sign out after the export finishes." : "Sign out of Uncloud on this Mac.")` | unchanged (good) |
| Free status "Export is free. Uncloud Plus adds automatic backups, Browse Backup and more." | unchanged (**T** AccountSummaryCopyTests) |

### Views/MainWindow.swift
| Old | New | Chunk |
|---|---|---|
| Sidebar "Export" `photo.on.rectangle` | "Library" | Q1 ⏳ |
| `.navigationTitle("Export")` | `.navigationTitle(model.source.title)` | Q1 ⏳ |
| Browse row symbol `map` | `photo.stack` | B1 |
| Rows order Export, Backup, Browse, [iCloud] Clean Up | Backup, Library, Browse Backup, [iCloud] Clean Up iCloud | Q1 ⏳ |

### Views/SettingsView.swift + Views/NewPhotosViews.swift (chunk B2)
| Old | New |
|---|---|
| Tabs General, Account | General, **Backups**, Account |
| Section "Automatic Backup" | "Automatic Backups" |
| Toggle "Export when the backup drive is connected" | "Export when the backup drive connects" |
| LabeledContent "Backup folder" + Choose…/Change… | removed. Caption: "Exports to “\(name)”." or "Choose a backup folder in Uncloud first." + link button "Choose Backup Folder…" |
| Status "Last export: \(x). While automatic backups are on, Uncloud keeps running in the menu bar." | "Last export \(x). While automatic backups are on, Uncloud keeps running in the menu bar." (no colon; "never" → "Not exported yet. While …") |
| Section "General" (inside General tab) | no header |
| Section "New Photos" | "New Photo Reminders" |
| LockedSettingRow "Reminders are part of Uncloud Plus." | "New photo reminders are part of Uncloud Plus." |
| `.help` "Uncloud checks every six hours while it runs, which automatic backups or the menu bar keeps it doing." | "Checks every 6 hours while Uncloud is running" (and the same hint) |

### Views/LandingView.swift (chunk B3)
| Old | New |
|---|---|
| Title "Your Photos, on Your Own Drive" | "Connect Your Photos" |
| Subtitle "Full-size originals go from iCloud straight to your external drive, without filling up your Mac." | "Choose where Uncloud exports from. You can change it later in the File menu." |
| "Sign In to iCloud…" | unchanged |
| "Use Photos on This Mac" | unchanged |
| "Photos may download to this Mac first." | "Photos stored only in iCloud may download to this Mac first." |
| Highlights (3 lines) | removed (Welcome already said it) |
| Footer "Your password goes only to Apple." + "How It Works" | unchanged |
| `AppLogo(size: 96)` | `AppLogo(size: 64)` (a task screen, not a hero) |

### Views/BenefitsCarousel.swift, Views/HowItWorksSteps.swift, Views/GettingStartedView.swift (chunk B3)
| Old | New |
|---|---|
| Benefit "Built for Huge Libraries": "… Pause, resume, and next time copy only what’s new." | "… Pause, resume, and next time export only what’s new." |
| PrivacyNote "Your photos go straight to your own drive. Your password goes only to Apple, through icloudpd, the open-source tool built into Uncloud, and is saved in your keychain only if you choose." | "Your photos go straight to your own drive. Your password goes only to Apple and is saved in your keychain only if you choose. Uncloud uses icloudpd, an open-source tool, to talk to iCloud." (the tool's name stays here, in Getting Started only, for transparency) |
| HowItWorksStep "Sign In" / "Use your Apple Account, or Photos on this Mac." | "Connect Your Photos" / "Sign in to iCloud Photos, or use Photos on this Mac." |
| HowItWorksStep "Choose a Drive" / "Choose an external drive or folder, then export." | "Choose a Backup Folder" / "Pick a folder on your external drive, then export." |
| Step order Sign In, Choose Photos, Choose a Drive | Connect Your Photos, Choose a Backup Folder, Choose Photos ("Export everything, or pick the ones you want in Library.") |
| Step and benefit tints (`.blue/.purple/.teal/.orange/.indigo/.pink/.green`) | accent (`@Environment(\.uncloudAccent)` ?? `.accentColor`), passed in at render time |

### Views/ICloudSignInSheet.swift (chunk B3)
| Old | New |
|---|---|
| "Your password goes only to Apple, through icloudpd, the open-source tool built into Uncloud." | "Your password goes only to Apple. Uncloud never sees it." |
| "Saved in your keychain, so automatic backups can sign in on their own. Otherwise you’re asked again about every two months." | unchanged |

### Views/BackupPane.swift + Views/BackupToolSheets.swift (chunk B4)
| Old | New |
|---|---|
| notReady `ContentUnavailableView` "Nothing to Export Yet" / "Sign in to iCloud or choose Photos on This Mac first." / "Get Started" | replaced by `LandingView()` |
| `Label(issue…).foregroundStyle(.red)` and `Label(warning…).foregroundStyle(.orange)` (four places) | §3.11 pattern (symbol-only colour) |
| Free Up Space button for iCloud: disabled with help "Only for Photos on This Mac." | not shown unless `model.source == .photosLibrary` |
| — | locked tools: `.accessibilityValue("Requires Uncloud Plus")` |
| Free Up Space symbol `externaldrive.badge.minus` | `internaldrive` |

### Views/CleanupView.swift, BrowseBackupView.swift, ExportView.swift, MenuBarContent.swift (chunk B5)
| File | Old | New |
|---|---|---|
| CleanupView | Photos-on-this-Mac state: "Clean Up iCloud works with iCloud Photos. Switch to iCloud Photos to choose photos to delete." + "Switch to iCloud Photos" | Description "Clean Up iCloud works with iCloud Photos. To make room on this Mac instead, use Free Up Space." Buttons: "Switch to iCloud Photos" (prominent) + "Free Up Space…" (bordered; `account.require(.freeUpSpace) { tools.showFreeUpSpace() }`, needs `@Environment(BackupTools.self)` and `AccountModel`) |
| CleanupView | Signed-out state button "Sign In…" | "Sign In to iCloud…" |
| BrowseBackupView | "Show Backup" (nothing to browse) | "Go to Backup" |
| ExportView | "Waiting to Resume" toolbar label `.foregroundStyle(.orange)` on the whole label | orange on the icon only (§3.11) |
| ExportView | "Sign In Again" (signInRequired title) | "Sign In to iCloud Again" |
| MenuBarContent | "Export Now" | "Export New Photos" |

### Views/BackupHero.swift (chunk Q3 ⏳)
| Old | New |
|---|---|
| "Choose a backup folder" / "Pick a folder on your external drive." | unchanged |
| "Getting ready…" | unchanged |
| "Ready to export" + summary | unchanged |
| "Waiting to resume" | "Waiting to resume" (unchanged), subtitle nil → `ExportModel.resumeTimeText`-based "Resumes at \(time)." when known (read `model.autoResume`) |

(The hero copy is already in good shape. Q3 is small.)

### App/ExportCommands.swift (chunks Q1, Q2 ⏳)
| Old | New |
|---|---|
| View "Export" ⌘1, "Backup" ⌘2 | "Backup" ⌘1, "Library" ⌘2 |
| Backup › "Check Now" | "Check Backup Folder" |
| Help: Getting Started, —, Show Diagnostic Logs in Finder | Getting Started, Uncloud Website, Contact Support…, —, Show Diagnostic Logs in Finder |

### Model/ExportModel.swift (chunk Q1 ⏳)
| Old | New |
|---|---|
| `var pane: Pane = .export` | `var pane: Pane = .backup` (**T** ExportPaneRenameTests: expect `.backup`, rename the test "The first pane is Backup, the home screen") |
| "Export started. Progress is in Backup." (MainWindow) | Announce only when `model.pane == .export` (unchanged logic). The text is unchanged. |

---

## 5. Build chunks

Rules for every chunk: read `polish-plan.md` §2 (glossary) first. Use curly quotes and apostrophes (’ “ ”) in all
copy. Don't touch the five blocked files unless the chunk is marked ⏳. Build with
`xcodebuild -scheme Uncloud -destination 'platform=macOS' build`, then run the unit tests named in the chunk with
the lock script:
`/private/tmp/claude-501/-Users-barishiz-Developer-icloud-photo-export/df886b0f-d79a-4d1c-973d-23c5d89614c2/scratchpad/locked-test.sh /Users/barishiz/Developer/icloud-photo-export -only-testing:UncloudTests/<Suite>`.
Snapshot tests are env-gated (`TEST_RUNNER_…`). Re-record only the snapshots named. Don't launch the app. Don't commit.

### Parallel lanes (no shared files)
- **Lane A** (account files, run in order): A1 → A2 → A3.
- **Lane B** (run in parallel with each other and with Lane A): B1, B2, B3, B4, B5.
  B3 and B4 both touch `LandingView` usage, but only B3 edits `LandingView.swift`; B4 only references it. They're
  safe in parallel.
- **Lane Q** (⏳ after quick-update lands, run in order): Q1 → Q2 → Q3.
- **A4** (only if D1 = yes; Opus, not Haiku): after A1–A3.

---

### A1. Welcome and sign-in: one button, three rows, no "we"
Files: `Uncloud/Views/Account/WelcomeView.swift`, `AccountEmailView.swift`, `AccountCodeView.swift`,
`FeatureRow.swift` (read only, unless a badge colour change is needed).
Changes:
1. WelcomeView `hero`: subtitle per §4.
2. WelcomeView `features`: replace the `LazyVGrid` and `ForEach(PaidFeature.allCases)` with a `VStack(alignment:
   .leading, spacing: Tokens.Space.l)` of exactly 3 `FeatureRow`s, using the titles, badges, symbols and summaries
   in §4. `.frame(maxWidth: 440)`. Badge strings are "Free" and "Plus".
3. WelcomeView `buttons`: keep the signed-out warning label, but change its `foregroundStyle` to the §3.11 pattern
   (warning colour on the icon, `.primary` text). Replace the two-button HStack with one Button labelled "Continue
   with Email" (`.frame(minWidth: 200)`, `.borderedProminent`, `.controlSize(.large)`,
   `.keyboardShortcut(.defaultAction)`, action `account.show(.signUp)`). Under it, a `Text` caption per §4
   (`.font(.footnote)`, `.foregroundStyle(.secondary)`).
4. AccountEmailView: `title` returns "Continue with Email". `explanation` returns the one new sentence. `footnote`
   always shows the terms line with the new wording, and the `switchLink` calls and the function are deleted.
5. AccountCodeView: the two string changes.
Acceptance: Welcome shows 3 rows and 1 button. Return starts the email flow. No "we" or "We" in these three files
(`grep -nE '\b[Ww]e\b|we’' Uncloud/Views/Account/{WelcomeView,AccountEmailView,AccountCodeView}.swift` is empty).
The build passes.
Tests: `AccountModelTests`, `AccountSnapshotTests` (re-record Welcome, email and code snapshots if gated ones exist
for them; check with `grep -n "Welcome\|EmailView\|CodeView" UncloudTests/AccountSnapshotTests.swift`).

### A2. Paid-feature names, symbols, plan line, paywall copy
Files: `Uncloud/Account/AccountTypes.swift`, `Uncloud/Views/Account/PaywallSheet.swift`,
`UncloudTests/EntitlementGatingTests.swift`.
Changes: every AccountTypes and PaywallSheet row in §4. `paywallTitle` becomes `var paywallTitle: String { title }`.
Keep the property, because PaywallSheet and its tests use it.
Acceptance: the paywall lists "New Photo Reminders". The locked Browse pane shows the `photo.stack` symbol.
`grep -rn '"Reminders"' Uncloud` is empty.
Tests: update `EntitlementGatingTests` lines 105-108 to `#expect(PaidFeature.newPhotos.paywallTitle == "New Photo
Reminders")` and rename the test "Reminders are the paid part of New Photos". Run `EntitlementGatingTests`,
`EntitlementPolicyTests`, `AccountModelTests`.

### A3. Account settings copy
Files: `Uncloud/Views/Account/AccountSettingsForm.swift`.
Changes: §4 rows. The single "Continue with Email…" button replaces the "Sign In…" and "Create Account…" pair and
calls the same code path the old "Create Account…" button used, with route `.signUp`.
Acceptance: signed-out Settings › Account shows one button. "Already Subscribed? Check Again".
Tests: `AccountSummaryCopyTests`, `AccountMenuTests`, `SettingsTabTests`. Re-record the `menu-settings-account-*`
snapshots.

### A4. (D1 = yes only) Continue Without an Account — Opus chunk, outline only
Add `AccountModel.Phase.guest`. `showsAppMenus` is true for `.guest`, and `allows(_:)` is false for every
PaidFeature. Welcome gets a `.link` button "Continue Without an Account" under the caption. In guest mode, `require`
opens a sign-in sheet (reusing AccountEmailView/AccountCodeView in a sheet) before the paywall. The avatar slot
shows a "Sign In…" text button. Persist the choice. Needs its own plan section and tests. Not Haiku-sized.

### B1. Sidebar: no auto-paywall, Browse symbol
Files: `Uncloud/Views/MainWindow.swift`.
Changes:
1. Delete the whole `.onChange(of: model.pane) { … }` block that calls `account.require(.browseBackup)` and
   `account.require(.cleanUpICloud)`.
2. Browse Backup row symbol: `"map"` → `"photo.stack"`.
Acceptance: selecting a locked row shows `LockedFeatureView` and no sheet. Its button still opens the paywall.
Tests: check `AccountSnapshotTests.swift:356` (`fresh.require(.browseBackup) {}`). It calls `require` directly, so
it still passes. Run `EntitlementGatingTests`, `AccountSnapshotTests`.

### B2. Settings: General / Backups / Account
Files: `Uncloud/Views/SettingsView.swift`, `Uncloud/Views/NewPhotosViews.swift` (`NewPhotosReminderSection`,
`LockedSettingRow` only), `UncloudTests/SettingsTabTests.swift`.
Changes:
1. `enum SettingsTab: String, CaseIterable { case general, backups, account }`. `showsTabs(for:)` now always
   returns true. Remove the `off` branch, which shows General + Backups (no Account tab when `account.mode == .off`).
2. Split `GeneralSettingsForm` into:
   - `GeneralSettingsForm`: one `Section` with no header: Open at login (+ error), Show in menu bar + caption
     "Shown while automatic backups are on."
   - `BackupSettingsForm`: Section "Automatic Backups" (both toggles with the existing `lockable` and `.disabled`
     logic, the LockedSettingRow, the folder caption per §4, and the status line per §4), then
     `NewPhotosReminderSection`.
   Both forms are `.formStyle(.grouped).frame(width: 460)`.
3. TabView: General (`gearshape`), Backups (`externaldrive`), Account (`person.crop.circle`, only when
   `account.mode != .off`).
4. NewPhotosReminderSection: section title, LockedSettingRow text and help text per §4.
Acceptance: three tabs (two in off mode). No Change… button in Settings. The remembered tab still works (an
unknown raw value falls back to General).
Tests: update `SettingsTabTests` (`allCases == [.general, .backups, .account]`; `showsTabs(for: .off)` is now
true). Re-record `menu-settings-general-*` and add `menu-settings-backups-*` if the snapshot suite has a pattern
for it.

### B3. Landing, Getting Started, iCloud sign-in copy and tints
Files: `Uncloud/Views/LandingView.swift`, `BenefitsCarousel.swift`, `HowItWorksSteps.swift`,
`GettingStartedView.swift`, `ICloudSignInSheet.swift`.
Changes: §4 rows for these files. Tints: change `HowItWorksStep.tint` and `Benefit.tint` to be ignored by the
views. In `HowItWorksColumn`, `HowItWorksRow` and `BenefitRow`, read `@Environment(\.uncloudAccent) private var
accent` and pass `accent ?? .accentColor` to `IconTile`. Leave the `tint` stored properties in place, so no other
code breaks. Delete `highlights` from LandingView and its use in `column`.
Acceptance: the landing reads "Connect Your Photos". No "icloudpd" in `ICloudSignInSheet.swift`. All Getting Started
tiles use the accent colour.
Tests: `LandingSnapshotTests`, `DesignSnapshotTests` (re-record the landing and Getting Started images),
`LibrarySourceWordingTests`.

### B4. Backup pane: landing when not ready, warning colours, tools
Files: `Uncloud/Views/BackupPane.swift`, `Uncloud/Views/BackupToolSheets.swift`.
Changes:
1. `notReady` → `LandingView()`.
2. The four coloured warning Labels → §3.11 pattern (`destinationIssue` danger; `storageWarning`,
   `flatFolderWarning`, `layoutSwitchNotice` warning; the last two keep `.font(.caption)`).
3. BackupToolButtons: wrap the Free Up Space button in `if model.source == .photosLibrary { … }`. Change its
   symbol to `internaldrive`. Add `.accessibilityValue(account.allows(f) ? "" : "Requires Uncloud Plus")` to each
   of the three buttons. Delete the now-unused iCloud branch of `freeUpSpaceHelp`.
Acceptance: with the iCloud source, the Tools row shows two buttons. With Photos on This Mac, it shows three.
Backup › Free Up Space… in the menu bar stays visible and disabled for iCloud (that's ExportCommands, unchanged).
Tests: `NewPhotosSnapshotTests`, `UIRefreshSnapshotTests`, `DesignSnapshotTests` (re-record the Backup pane images).

### B5. Empty states and small copy in Clean Up, Browse, Library, menu bar extra
Files: `Uncloud/Views/CleanupView.swift` (only the top `CleanupView` struct), `BrowseBackupView.swift`,
`ExportView.swift`, `MenuBarContent.swift`.
Changes: §4 B5 rows. For CleanupView, add `@Environment(BackupTools.self) private var tools` and
`@Environment(AccountModel.self) private var account` to `CleanupView`. Both are in the environment from
`UncloudApp`/`RootView`; confirm in previews and snapshot tests, and add `.environment(BackupTools(model:))` there
if they crash.
Acceptance: the Photos-on-this-Mac Clean Up state has two buttons. The menu bar extra says "Export New Photos".
Tests: `CleanupSnapshotTests`, `BrowseBackupSnapshotTests`, `NewPhotosTests`.

### Q1. ⏳ Sidebar order, "Library", default pane Backup, View-menu shortcuts
Files: `Uncloud/Views/MainWindow.swift`, `Uncloud/App/ExportCommands.swift`, `Uncloud/Model/ExportModel.swift`
(one line), `UncloudTests/ExportPaneRenameTests.swift`, `UncloudTests/DesignSnapshotTests.swift` (line ~102 `Text("Export")`
→ "Library" if it mimics the sidebar).
Changes:
1. MainWindow sidebar order: Backup row (with its badge modifiers) first, then `Label("Library", systemImage:
   "photo.on.rectangle").tag(.export)`, then Browse Backup, then Section "iCloud". The `.export` case's
   `.navigationTitle(model.source.title)`.
2. ExportCommands `CommandGroup(before: .sidebar)`: "Backup" ⌘1 (`.backup`), "Library" ⌘2 (`.export`), Browse
   Backup ⌘3, Clean Up iCloud ⌘4.
3. ExportModel: `var pane: Pane = .backup`.
Acceptance: the app opens on Backup. ⌘1/⌘2 match the visual order. The Library title reads "iCloud Photos" or
"Photos on This Mac".
Tests: `ExportPaneRenameTests` → expect `.backup`. Run the full unit suite (pane defaults leak into many tests;
fix any that assumed `.export`, e.g. `grep -rn "pane == .export\|\.pane)" UncloudTests`).

### Q2. ⏳ Menu bar fixes
Files: `Uncloud/App/ExportCommands.swift`.
Changes:
1. "Check Now" → "Check Backup Folder".
2. Backup menu primary item: when `model.destination == nil`, show `Button("Export All Photos") {}.disabled(true)`
   in place of the dynamic button. Otherwise keep it as it is.
3. Help: after Getting Started, add `Button("Uncloud Website") { NSWorkspace.shared.open(URL(string:
   "https://uncloud-app.vercel.app")!) }` and `Button("Contact Support…") { NSWorkspace.shared.open(URL(string:
   "mailto:support@uncloud.app")!) }`. **Use the address in decision D4.** Wrap both in `if account.showsAppMenus`
   only if the owner wants them hidden when signed out. Recommended: show them always.
Acceptance: the menus match §3.1.
Tests: `AccountMenuTests` and the full build.

### Q3. ⏳ Hero: resume time
Files: `Uncloud/Views/BackupHero.swift`, `UncloudTests/BackupHeroContentTests.swift`.
Changes: add a `resumeAt: Date?` parameter (default nil) to `BackupHeroContent.make`. When `hasAutoResume` and
`resumeAt != nil`, the subtitle is "Resumes at \(ExportModel.resumeTimeText(resumeAt))." `BackupHero` passes
`model.autoResume?.isWaitingForDestination == true ? nil : model.autoResume?.resumeAt`. When waiting for the
destination, the subtitle is "Connect your backup drive to continue."
Tests: add two rows to `BackupHeroContentTests`.

---

## 6. Decisions for the owner

| # | Decision | Recommendation |
|---|---|---|
| D1 | Let people export without an Uncloud account ("Continue Without an Account")? | **Yes.** HIG asks for exactly this, Settings already promises it, and Export is free. Sign-in is asked for only when they open a Plus feature. (Chunk A4, Opus-sized.) If you need emails for every user, say no, and A1's single button still helps. |
| D2 | Rename the "Export" pane to **Library** and make **Backup** the first and default pane? | **Yes** (Q1). |
| D3 | Replace "Create Account" + "Sign In" with one **Continue with Email** button? | **Yes.** The server already treats both the same. |
| D4 | Support contact for Help › Contact Support… | Give an address (e.g. support@…). Until then, ship only "Uncloud Website". |
| D5 | Keep naming icloudpd anywhere in the UI? | **Only in Getting Started** (transparency, open-source credit), not in the sign-in sheet. |

## Owner decisions (2026-10-19)
- D1: **No.** Sign-in stays required before the app. Drop A4. Any copy that says export works without an account must say instead that Export is free with a free account.
- D2: **Yes.** Backup is the home pane; the grid "Export" is renamed "Library" (chunk Q1).
- D3: **Yes.** One "Continue with Email" button.
- D4: Support email is **barishiz@gmail.com** for now. Add Help › Contact Support (mailto) next to the Website item, and fill AccountLinks / site / privacy pages.
- D5: Yes, as recommended.
