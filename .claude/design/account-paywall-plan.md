# Uncloud accounts, Export rename and paywall: plan

Status: design and architecture only. No Swift code was changed. Author: product design + architecture (Opus), 2026-10-18.
Branch: `feature/duplicates-and-icloud-cleanup` (5b91d66, v0.1.8).

Owner's requests:
1. "Design the sign up, sign in page as a separate page, show all the menus once logged in. Sign up page should be
   appealing and briefly describe all features, without making it sophisticated."
2. "i want to charge people for all features other than library one (and rename it to Export) so paywall will be needed
   along with stripe integration. first design it then we can connect it to stripe."

Agreed: $10 USD a year. Card, Apple Pay and Google Pay through Stripe Checkout on the web. DMG distribution, no App Store,
no Developer ID yet, so no StoreKit and no Sign in with Apple. The repo is public, so the app holds **no secrets**.

This phase builds the UI and the client architecture against a **stub backend** (`PreviewAccountService`), working end to
end on this Mac. Stripe and a real server are the next phase (section E). Everything here follows the direction, the
glossary and the components of `polish-plan.md` (one primary button per screen, colour means status, sentence-case
status, title-case commands, `Tokens.*`, `SheetScaffold`, `IconTile`, `AppLogo`, `HelpText`).

---

## 0. Decisions at a glance

| Topic | Decision |
|---|---|
| Account type | Passwordless: **email + 6-digit code**. No passwords to store, reset or leak. |
| Plan name | **Uncloud Plus**, $10/year. The free tier is just "Free". (Owner to confirm the name, Q1.) |
| Free | **Export**: choose photos, choose the backup folder, folders, start/pause/resume/cancel, progress, resume after an interruption, Check Now, export history, activity. |
| Paid | Automatic backups, New Photos (badge, hero line, reminders), Browse Backup, Find Duplicates, Verify Backup (incl. Re-export), Free Up Space, Clean Up iCloud (incl. Recover). |
| Where the free controls live | The **Backup pane stays, and stays free** for the folder, Folders, progress and history. Only its Tools row is locked. |
| Locked features | Stay visible with a small lock; choosing one opens **one** paywall sheet. Never hidden. |
| Running work | Entitlement is checked only when a paid feature **starts**. Nothing in progress is ever stopped by a plan change, expiry or sign-out. |
| Release builds before the server exists | `UNCLOUD_ACCOUNT_MODE = off`: no Welcome, no locks, the app is exactly v0.1.8. Debug defaults to `preview`. `live` arrives with the server. |
| Return from checkout | `uncloud://checkout/success`, `uncloud://checkout/cancel`, `uncloud://account/refresh`, handled in `AppDelegate`. |
| Tokens | Keychain (live). The stub uses UserDefaults behind the same `AccountTokenStore` seam. |

---

## A. The Uncloud account

### A.1 Why passwordless email + code

- **Nothing secret to keep.** No password hashing, reset flow, "forgot password" screen or breach exposure. The server
  stores an email and a Stripe customer ID.
- **One screen fewer.** Sign Up and Sign In are the same two steps (email, then code). The owner wants them as separate
  pages; they stay separate in the UI but share one view and one service call with an `intent`.
- **Works without Apple.** Sign in with Apple needs an entitlement this app can't have yet. Magic links need a
  universal link or a custom-scheme hop through the browser, which is fragile in a sandboxed, ad hoc-signed app; a code
  the user types is robust. (A magic link can be added later on the same `uncloud://` handler, section D.4.)
- **Matches the existing iCloud sign-in**, which already asks for a 6-digit code, so users know the pattern.
- Email + password was rejected: more UI, more server work, and a weaker result for a $10 utility.

The server decides new versus returning at `verify`: Sign Up with an email that already has an account just signs in
("Welcome back"), and Sign In with a new email creates one. No dead ends, and no "this email isn't registered" message,
which would leak who has an account.

### A.2 Types (new `Uncloud/Account/AccountTypes.swift`)

All value types are `Sendable`, `Codable`, `Equatable`.

```swift
struct UncloudAccount { let id: String; let email: String }

enum AuthIntent: String { case signUp, signIn }

/// What `requestCode` returns: the challenge to verify against.
struct AuthChallenge { let id: String; let email: String; let expiresAt: Date; let resendAfter: Date }

struct AuthSession { let account: UncloudAccount; let tokens: AccountTokens; let entitlement: Entitlement; let isNewAccount: Bool }

struct AccountTokens { let accessToken: String; let refreshToken: String; let accessExpiresAt: Date }

enum Plan: String { case free, plus }

/// The plan as the server last reported it. Cached on disk with `checkedAt`.
struct Entitlement {
    enum Status: String { case none, active, trialing, pastDue, canceled, expired }
    let plan: Plan
    let status: Status
    /// End of the paid period: the renewal date while active, the end date once canceled.
    let currentPeriodEnd: Date?
    let cancelAtPeriodEnd: Bool
    let checkedAt: Date
    static let free: Entitlement
}

enum PaidFeature: String, CaseIterable, Identifiable {
    case automaticBackups, newPhotos, browseBackup, findDuplicates, verifyBackup, freeUpSpace, cleanUpICloud
    var title: String   // "Automatic Backups", "New Photos", "Browse Backup", "Find Duplicates", "Verify Backup", "Free Up Space", "Clean Up iCloud"
    var symbol: String  // section F.1 table
    var summary: String // one line, section F.1 table
}

enum AccountError: Error, Equatable {
    case invalidEmail, wrongCode, codeExpired, tooManyAttempts, rateLimited(retryAfter: Date?)
    case offline, server(message: String?), signedOut, checkoutUnavailable
    var message: String   // section F.7
}
```

### A.3 `AccountService` (new `Uncloud/Account/AccountService.swift`)

```swift
/// The account backend. `PreviewAccountService` now; `HTTPAccountService` (section E) next phase.
/// Implementations are actors or otherwise Sendable; every call is async and may throw `AccountError`.
protocol AccountService: Sendable {
    /// Sends a 6-digit code to `email`. Sign Up and Sign In both call this; `intent` only affects the email's wording.
    func requestCode(email: String, intent: AuthIntent) async throws -> AuthChallenge
    /// Exchanges the code for a session. Creates the account if the email is new.
    func verify(challenge: AuthChallenge, code: String) async throws -> AuthSession
    /// The current account and plan, using (and refreshing if needed) the stored tokens.
    func currentEntitlement(tokens: AccountTokens) async throws -> (Entitlement, AccountTokens)
    /// Exchanges the refresh token for new tokens.
    func refresh(tokens: AccountTokens) async throws -> AccountTokens
    /// Revokes the refresh token on the server. Best effort: local sign-out happens whatever this returns.
    func signOut(tokens: AccountTokens) async
    /// A Stripe Checkout URL for Uncloud Plus. The app opens it in the browser.
    func checkoutURL(tokens: AccountTokens) async throws -> URL
    /// A Stripe customer portal URL (manage, cancel, change card, invoices).
    func manageSubscriptionURL(tokens: AccountTokens) async throws -> URL
}
```

"Restore" is `currentEntitlement` (there is no store receipt; the server is the source of truth), so it needs no
separate call. "Sign up" is `requestCode(intent: .signUp)` + `verify`.

### A.4 `PreviewAccountService` (new `Uncloud/Account/PreviewAccountService.swift`)

An `actor`. Deterministic, no network, used by Debug builds and by every test.

- `requestCode`: validates the email with `EmailAddress.normalized(_:)` (A.7); returns a challenge that expires in 10
  minutes with `resendAfter` = now + 30 s. Records `lastIssuedCode`.
- Code: **`123456`** always (`PreviewAccountService.code`). The Code screen shows it in preview mode (F.4), so nobody
  has to look it up.
- Up to 5 wrong codes per challenge, then `.tooManyAttempts`. After `expiresAt`, `.codeExpired`.
- Simulation emails, so every error state can be seen without a server:
  `offline@example.com` → `.offline`; `slow@example.com` → 2 s delay on every call; `limit@example.com` →
  `.rateLimited`; `plus@example.com` → signs in already on Plus; `pastdue@example.com` → Plus with `pastDue`.
- Entitlement state lives in an injected `PreviewAccountStore` (UserDefaults suite `com.example.Uncloud.preview-account`,
  or in-memory for tests) keyed by email, so it survives relaunches.
- `checkoutURL` returns `uncloud://checkout/success?session_id=preview_<uuid>` and flips the stored plan to Plus with
  `currentPeriodEnd` = now + 1 year. `AccountModel` opens it with `NSWorkspace.shared.open`, so the **real URL-scheme path
  is exercised** end to end (the app receives its own URL). Tests call the handler directly instead.
- `manageSubscriptionURL` returns `uncloud://account/refresh`. Settings in preview mode adds Debug-only buttons
  (F.6) to cancel or expire the plan, since there is no portal.
- Init takes a `now: @Sendable () -> Date` clock so tests can move time.

### A.5 Token storage

`protocol AccountTokenStore: Sendable { func load() -> AccountTokens?; func save(_:) throws; func clear() }`

- `KeychainAccountTokenStore` (written now, used in `live`): one generic-password item, service
  `"\(bundleID).uncloud-account"`, account `"tokens"`, value = JSON of `AccountTokens`,
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. Same calls as `ICloudCredentialStore` (copy its pattern; don't
  share code with it).
  - **Sandbox:** an app's own generic-password items in the login (file-based) keychain need no extra entitlement. Don't
    use `kSecUseDataProtectionKeychain`; that needs a keychain-access-groups entitlement and a team ID, which the ad hoc
    build doesn't have.
  - **Ad hoc signing caveat:** the item's ACL is tied to the code signature, and an ad hoc signature changes every
    build, so after an update macOS may ask "Uncloud wants to use your keychain". Treat that like a missing item: if
    `SecItemCopyMatching` fails or the user denies, `load()` returns nil, and the app **keeps the cached entitlement** and
    asks the user to sign in again only when a server call needs a token. A Developer ID fixes this for good.
- `DefaultsAccountTokenStore` (preview and tests): the same JSON in UserDefaults under `uncloudAccountTokens`. Fine
  because the preview tokens are fake.
- The cached `Entitlement` and the `UncloudAccount` (email) go in UserDefaults (`uncloudEntitlement`,
  `uncloudAccount`) in every mode. They aren't secret. Next phase the server signs the entitlement (E.4), so editing
  defaults doesn't unlock Plus.

### A.6 Account mode and Release safety

A build setting, `UNCLOUD_ACCOUNT_MODE`, written into Info.plist as `UncloudAccountMode`:

| Mode | Where | Behaviour |
|---|---|---|
| `off` | **Release, this phase** | No Welcome, no sign-in, no locks, no paywall, no Account section. `allows(_:)` is always true. The app is exactly v0.1.8 plus the Export rename. |
| `preview` | Debug (default) | Welcome, sign-in and paywall against `PreviewAccountService`. |
| `live` | Release, next phase | `HTTPAccountService` at `UncloudAPIBaseURL`. |

`AccountConfiguration.current` reads the key once at launch. Guards:
- `preview` in a non-DEBUG build is treated as `off` (`#if !DEBUG`), so a DMG can never ship the fake plan.
- `live` with a missing or non-https `UncloudAPIBaseURL` falls back to `off` and logs to Activity. It never locks
  people out because of a configuration mistake.
- Debug only: the launch argument `-UncloudAccountMode off|preview` overrides the plist, to compare both.

Effect: until the owner flips Release to `live`, a DMG neither hands out a fake paid plan nor locks anyone out. The
test host target gets `UncloudAccountMode = preview` too, but tests build their own `AccountModel` anyway.

### A.7 Email and code validation (pure, new `Uncloud/Account/AccountValidation.swift`)

- `EmailAddress.normalized(_ raw: String) -> String?`: trims whitespace, lowercases; nil unless it has exactly one `@`, a
  non-empty local part with no spaces, a domain with at least one `.` that doesn't start or end with `.` or `-`, a
  TLD of 2+ letters, and a total of ≤ 254 characters. Deliberately simple; the server is the real check.
- `OneTimeCode.sanitized(_ raw: String) -> String`: ASCII digits only, first 6. (Same rule as `ICloudSignInSheet`.)
  `OneTimeCode.isComplete(_:)`: exactly 6 digits. Pasting "123 456" or "Your code is 123456" gives "123456".

### A.8 `AccountModel` (new `Uncloud/Account/AccountModel.swift`)

`@MainActor @Observable final class AccountModel`. The one object the views read.

```swift
enum Phase { case off, restoring, signedOut(Route), signedIn }
enum Route: Hashable { case welcome, signUp, signIn, code(AuthChallenge, AuthIntent) }

let mode: AccountMode
private(set) var phase: Phase
private(set) var account: UncloudAccount?
private(set) var entitlement: Entitlement          // cached, see D.6
var paywall: PaywallRequest?                         // drives the one paywall sheet; Identifiable
private(set) var isBusy: Bool                        // a request is in flight
private(set) var error: AccountError?                // shown on the current screen

var access: Access { EntitlementPolicy.access(entitlement, now: clock()) }   // .plus, .plusGrace(until:), .free
func allows(_ feature: PaidFeature) -> Bool           // mode == .off || access != .free
/// Runs `action` when allowed; otherwise opens the paywall for `feature`, and runs `action` after a successful
/// subscribe if the paywall was opened by it (so "Verify Backup…" → subscribe → Verify opens).
func require(_ feature: PaidFeature, _ action: @escaping @MainActor () -> Void)

func show(_ route: Route)                             // Welcome ↔ Sign Up ↔ Sign In
func submitEmail(_ raw: String, intent: AuthIntent) async
func submitCode(_ raw: String) async
func resendCode() async
func cancelRequest()                                  // Esc while busy
func signOut() async                                  // disabled while an export runs (F.6)
func refreshEntitlement(force: Bool) async            // launch, becoming active (if checkedAt > 24 h), Refresh buttons
func openCheckout(for feature: PaidFeature?) async
func openManageSubscription() async
func handle(_ url: URL) -> Bool                       // D.4
```

`init(mode:service:tokens:defaults:clock:openURL:)` with defaults for the app; tests inject everything. `openURL` is a
`@MainActor (URL) -> Void` (defaults to `NSWorkspace.shared.open`).

Wiring in `UncloudApp.init`: create `AccountModel(configuration: .current)`, put it in the environment of the main
window, Settings and the menu bar extra, give it to `ExportCommands`, set `AppDelegate.account`, and give the
`ExportModel` and `AutoBackupController` a gate closure (C.4). Call `refreshEntitlement(force: false)` from a `.task` on
the root view.

---

## B. Launch flow

### B.1 States of the main window

New `Uncloud/Views/Account/RootView.swift` is the `Window("Uncloud", id: "main")` content:

```
mode == .off                  → MainWindow (today's app)
phase == .restoring           → empty window background (≤ 1 frame normally; restoring is synchronous from defaults)
phase == .signedOut(route)    → AccountFlowView(route)   full window, no sidebar, no toolbar items
phase == .signedIn            → MainWindow
```

Restoring is synchronous (read the cached account + entitlement from defaults); there is no splash. A token that turns
out to be revoked on the next refresh signs the user out to Welcome with the message "You’ve been signed out. Sign in
again to keep using Uncloud Plus." **unless an export is running**, in which case the sign-out waits until it ends.

After sign-in: `MainWindow` opens on the Export pane. If no source is ready, the Export pane shows today's `LandingView`
(Sign In to iCloud… / Use Photos on This Mac), exactly as now. A **new account** (`isNewAccount`) gets a one-line
announcement "Welcome to Uncloud" via `AccessibilityNotification.Announcement`; no extra screen.

Transitions between routes: a cross-fade with `Tokens.Motion.animation(reduceMotion)` (none with Reduce Motion).

### B.2 Menus while signed out (`phase == .signedOut`)

Only these remain:

| Menu | Items |
|---|---|
| Uncloud | About Uncloud, Settings… (⌘,), Services, Hide Uncloud, Hide Others, Show All, Quit Uncloud (⌘Q) — all system |
| File | Close (⌘W) — system. Our `newItem` replacement contributes nothing. |
| Edit | Undo, Redo, Cut, Copy, Paste, Select All — **system, needed for the email and code fields**. Our Deselect All and Delete from iCloud… are not added. |
| View | Enter Full Screen — system. No pane items, no Sort, no Show Sidebar (`SidebarCommands` not added). |
| Window | system items |
| Help | Show Diagnostic Logs in Finder. ("Getting Started" is hidden; the Welcome page says the same.) |

The Backup menu (`CommandMenu("Backup")`) is not added.

Implementation: `ExportCommands` takes the `AccountModel` and wraps its groups in `if account.showsAppMenus` (true for
`.off` and `.signedIn`). `CommandsBuilder` supports `if` (buildOptional/buildEither) from macOS 13. If the build
rejects a conditional `CommandMenu`, fall back to keeping it with every item disabled, and say so in the PR.
`SidebarCommands()` moves into the same `if`.

Settings while signed out shows the Account section (F.6, signed-out state) and General only.
The menu bar extra is never inserted while signed out (it already requires automatic backups, which are paid).

### B.3 Keyboard and accessibility, for every account screen

- **Return** submits (the screen's primary button is `.keyboardShortcut(.defaultAction)`, disabled until the input is valid).
- **Esc** goes back: Sign Up / Sign In → Welcome; Code → the email screen it came from (email kept). While a request is
  busy, Esc cancels it instead. Welcome has no Esc action. Implement with a hidden or the visible Back button carrying
  `.keyboardShortcut(.cancelAction)`.
- The email field is focused on appear (`@FocusState`); the code field is focused on appear and after an error (text selected).
- Tab order: field → primary button → secondary links → Back.
- Every screen's title is `.accessibilityAddTraits(.isHeader)`. Errors are announced with
  `AccessibilityNotification.Announcement(error.message)` and shown next to the field with `exclamationmark.triangle`
  in `Tokens.Status.danger` (symbol + colour, never colour alone).
- Feature rows on Welcome and the paywall are `.accessibilityElement(children: .combine)`; decorative tiles and the logo
  are `.accessibilityHidden(true)`.
- Dynamic Type is limited on macOS, but nothing uses a fixed height: everything sits in a `ScrollView` with
  `.scrollBounceBehavior(.basedOnSize)` like `LandingView`, so a 760 × 500 window scrolls instead of clipping.

---

## C. Export rename, free and paid

### C.1 Rename the Library pane to "Export"

| Where | Now | New |
|---|---|---|
| `ExportModel.Pane` | `case library` | `case export` (`export` is not a Swift keyword). Default `pane = .export`; `ExportModel.swift:230` `.library` → `.export`. |
| Sidebar row (`LibraryWindow.swift:14`) | `Label("Library", systemImage: "photo.on.rectangle")` | `Label("Export", systemImage: "photo.on.rectangle")` (the symbol stays: the pane is the photo grid) |
| Detail title (`LibraryWindow.swift:42`) | `.navigationTitle("Library")` | `.navigationTitle("Export")` |
| View menu (`ExportCommands.swift:55`) | "Library" ⌘1 | "Export" ⌘1 |
| `BackupPane` not-ready button | `model.pane = .library` | `model.pane = .export` |
| Comments | "Library pane", "from the Library" | "Export pane", "from Export" (`LibraryWindow.swift:79`, `LibraryView.swift:4`, `LibraryView.swift:40`) |
| Types | `struct LibraryView`, file `LibraryView.swift`; `LibraryToolbar` | `struct ExportView`, file `Uncloud/Views/ExportView.swift`; `ExportToolbar` |
| Types | `struct LibraryWindow`, file `LibraryWindow.swift` | `struct MainWindow`, file `Uncloud/Views/MainWindow.swift` (it is the whole window, not the library) |
| Accessibility | "Export started. Progress is in Backup." | unchanged |

**Not renamed** (they name the photo library, not the pane): `LibraryBrowser`, `LibraryGrid`, `LibrarySelection`,
`LibrarySource`, `LibraryCleanup`, `ICloudCleanup.Mode.library` and its "Library" segment in Clean Up iCloud,
`ICloudBridgeAlbum.library`, "Couldn’t Open Your Library", "Loading your library…".

Tests to update: `UIRefreshSnapshotTests.swift:96` `LibraryWindow()` → `MainWindow()`. Grep `UncloudTests` for
`.library` pane uses and "Library" titles before closing the chunk (none found at 5b91d66 besides that line).

### C.2 Free and paid

| Feature | Tier | Why |
|---|---|---|
| Export pane: the grid, Select All / Deselect All, the primary Export button, Export All Photos, the toolbar progress ring | **Free** | The owner's "library one". |
| Choose / change the backup folder, Show in Finder, Space needed / free | **Free** | An export can't run without a folder. |
| Folders (By Month, By Album, …) and Save XMP metadata files | **Free** | Part of how an export is written. Locking it would make Free feel broken. |
| Export progress, Pause / Resume / Cancel, Resume Export after it didn't finish, waiting to resume (Apple limits) | **Free** | Never block an export. Resume protects the user's data. |
| Check Now (quick recount of the drive) and the automatic check before an export | **Free** | The engine relies on it to skip what's already backed up. |
| Export history (runs) and Activity | **Free** (Q3) | Read-only facts about the user's own exports, and the first thing support asks for. |
| Exporting only what's new on a later run | **Free** | That's the manifest, not a feature. |
| **Automatic backups** (when the drive connects, once a day) and the menu bar item | **Plus** | Set-and-forget is the clearest paid value. |
| **New Photos**: sidebar badge, hero "N new photos" line, reminder notifications | **Plus** (Q2) | Part of keeping a backup current without thinking. |
| **Browse Backup** (dates, map, places) | **Plus** | Owner's list. |
| **Find Duplicates** | **Plus** | Owner's list. |
| **Verify Backup**, including Re-export of damaged files | **Plus** | Owner's list. Re-export starts from the Verify sheet. |
| **Free Up Space** | **Plus** | Owner's list. |
| **Clean Up iCloud**, including Recover | **Plus** (Q4) | Owner's list. |

**Where the free controls live.** The Backup pane holds the folder chooser, Folders, progress and history, all free. It
stays in the sidebar, unlocked. Its only locked part is the **Tools** row (Verify, Find Duplicates, Free Up Space).
Moving the folder and progress into the Export pane was considered and rejected: it duplicates the hero, `BackupHero`
already handles every export state, and the toolbar ring already links Export → Backup. Zero layout churn, and the
"Backup" name still makes sense as "your backup on the drive".

Sidebar after this change:

```
Export            ⌘1
Backup            ⌘2   (badge: export % while running; the new-photos count only on Plus)
Browse Backup  🔒 ⌘3
iCloud
  Clean Up iCloud 🔒 ⌘4
```

### C.3 How each lock looks (disable/explain, never hide)

| Place | Locked look | Choosing it |
|---|---|---|
| Sidebar rows Browse Backup, Clean Up iCloud | Trailing `lock.fill`, `.caption`, `.secondary`, `.accessibilityValue("Requires Uncloud Plus")`. No badge. | Selects the pane, which shows `LockedFeatureView` (F.5b) **and** presents the paywall sheet for that feature. Dismissing leaves the locked view, whose button reopens the sheet. ⌘3 / ⌘4 do the same. |
| Backup pane › Tools buttons | Same titles; the symbol becomes `lock` (instead of `checkmark.shield`, `doc.on.doc`, `externaldrive.badge.minus`). `.help` gains " Part of Uncloud Plus." | Opens the paywall. After subscribing, the tool opens. |
| Backup menu › Verify Backup…, Find Duplicates…, Free Up Space… | Titles unchanged (macOS 14 menus don't show symbols). Enabled whenever today's condition allows. | Opens the paywall (via `account.require`). |
| View › Sort | Disabled unless the pane is Browse Backup and unlocked. | — |
| Edit › Delete from iCloud… | Only enabled from the Clean Up grid, which isn't shown while locked. | — |
| Settings › Automatic Backup toggles and New Photos reminder | Toggles `.disabled(true)` and shown **off**; the user's saved values are kept, not overwritten. A row under the section: `lock` + "Automatic backups are part of Uncloud Plus." + **Get Uncloud Plus…** (link style). | The button opens the paywall over the Settings window. |
| New Photos badge and hero line | Not shown (the hero falls through to `.upToDate`/`.ready`). No lock, since nothing is there to choose. | — |
| Menu bar item | Not inserted (requires automatic backups). | — |
| Welcome page | No locks. One line says what's free (F.1). | — |

### C.4 Gating seams (keeps `ExportModel` free of account code)

- `ExportModel.isFeatureAllowed: @MainActor (PaidFeature) -> Bool = { _ in true }`, set in `UncloudApp.init` to
  `{ [weak account] in account?.allows($0) ?? true }`. Same pattern as `isExportBlocked`.
  - `newPhotosStatus` consumers: `ExportModel` exposes `visibleNewPhotosStatus` = `isFeatureAllowed(.newPhotos) ? newPhotosStatus : nil`.
    `BackupHeroContent.make(newPhotos:)`, the sidebar badge, `MenuBarContent` and the hero use it. Don't change the tracker.
- `AutoBackupController` gets `isAllowed: @MainActor (PaidFeature) -> Bool`. Checked **at the moment a run would
  start**: `volumeDidMount`, `runDailyBackupIfDue`, the startup catch-up (`.automaticBackups`), and `checkForNewPhotos`
  before posting a reminder (`.newPhotos`). The schedulers keep running; they just do nothing when not allowed, so
  subscribing takes effect without a relaunch.
- `AutoBackupSettings.isEnabledInDefaults` (used by `applicationShouldTerminateAfterLastWindowClosed` and the menu
  bar binding) is ANDed with `account.allows(.automaticBackups)` in the app layer, not inside the settings class.
- `BackupTools.showVerify/showDuplicates/showFreeUpSpace` stay as they are; callers go through
  `account.require(.verifyBackup) { tools.showVerify() }`. `canOpen*` conditions don't change.
- Pane gating: `MainWindow` decides between the real pane and `LockedFeatureView` with `account.allows(.browseBackup)` /
  `.cleanUpICloud`. `BrowseBackup` indexing (which runs in `BackupTools` even when the pane isn't shown) only starts
  when allowed: `BrowseBackup.isEnabled` flag set by the app layer.
- **Never interrupt:** none of these closures are consulted after a thing starts. An export, automatic backup, Verify,
  Find Duplicates, Free Up Space or Clean Up iCloud run already in progress finishes even if the plan lapses or the
  user signs out mid-run (Sign Out is disabled during an export anyway, F.6).

---

## D. Paywall, checkout return and entitlement

### D.1 The paywall sheet (`PaywallSheet`, F.5)

One sheet, presented from `MainWindow` and from `SettingsView` with `.sheet(item: $account.paywall)`.
`PaywallRequest { let feature: PaidFeature?; let then: (@MainActor () -> Void)? }`.

States (`PaywallModel` inside `AccountModel`, or `AccountModel.checkout` enum):
`idle` → `opening` ("Opening checkout…") → `waiting` (browser is open; "Finish in your browser, then come back.") →
`active` (success) | `failed(AccountError)`. While `waiting`, becoming active (`NSApplication.didBecomeActiveNotification`)
triggers one `refreshEntitlement(force: true)`; "Check Again" does the same.

On `active`: the sheet shows the thank-you state; **Continue** dismisses it and runs `then` (the action that opened it).

### D.2 Return from checkout: `uncloud://`

Stripe's `success_url` must be https, so the server's success page (`https://uncloud.app/checkout/done`, E.2) redirects
to `uncloud://checkout/success?session_id={CHECKOUT_SESSION_ID}` and also shows a "Return to Uncloud" link. If the
browser blocks the hop, the user just switches back to the app and `didBecomeActive` refreshes anyway. The URL is a
**hint to refresh**, never a proof of payment: the entitlement always comes from the server.

| URL | Action |
|---|---|
| `uncloud://checkout/success?session_id=…` | `refreshEntitlement(force: true)`; paywall → `active` if Plus, else stays `waiting` with "Payment is still processing. This can take a minute." |
| `uncloud://checkout/cancel` | paywall → `idle`, no message. |
| `uncloud://account/refresh` | `refreshEntitlement(force: true)` (returns from the customer portal). |
| anything else, other scheme, or mode `off` | ignored, returns false. |

Parsing is a pure `enum AccountURL { case checkoutSuccess(sessionID: String?), checkoutCancel, refresh; init?(_ url: URL) }`
(scheme compared case-insensitively; host + path matched exactly; `session_id` ≤ 255 chars of `[A-Za-z0-9_]`, otherwise
nil). Unit-tested.

### D.3 Info.plist and project.yml

`GENERATE_INFOPLIST_FILE: YES` can't express `CFBundleURLTypes`, so the **Uncloud** target gets an XcodeGen `info:`
block, which writes `Uncloud/App/Info.plist` and merges with the generated keys:

```yaml
  Uncloud:
    info:
      path: Uncloud/App/Info.plist
      properties:
        CFBundleURLTypes:
          - CFBundleURLName: com.example.Uncloud.account
            CFBundleURLSchemes: [uncloud]
        UncloudAccountMode: $(UNCLOUD_ACCOUNT_MODE)
        UncloudAPIBaseURL: $(UNCLOUD_API_BASE_URL)
    settings:
      configs:
        Debug:
          UNCLOUD_ACCOUNT_MODE: preview
        Release:
          UNCLOUD_ACCOUNT_MODE: off
      base:
        UNCLOUD_API_BASE_URL: ""
```

The **UncloudTestHost** target gets its own `info:` (`Uncloud/App/TestHost-Info.plist`) with `UncloudAccountMode:
preview` and **no `CFBundleURLTypes`**, so a test build never registers `uncloud://` with Launch Services and steals
the scheme from the real app. Exclude both plist files from `sources` (`excludes: ["App/*Info.plist"]`), and remove
the old `INFOPLIST_KEY_*` lines only if they move into `info:` (they don't need to). Run `xcodegen generate`.
No entitlement change: the scheme needs none, and `network.client` is already on.

### D.4 Handler

In `AppDelegate`: `func application(_ application: NSApplication, open urls: [URL])` → for each URL,
`Self.account?.handle(url)`; then bring the main window forward (`NSApp.activate()`; the window is a single `Window`
scene, so it is reused). Implementing `application(_:open:)` means SwiftUI's `.onOpenURL` won't fire; use only the
delegate. `AppDelegate.account` is a `@MainActor static weak var`, like `model`.
Cold start (the app wasn't running when the URL arrived): AppKit delivers `open urls` after
`applicationDidFinishLaunching`, by which time `UncloudApp.init` has set `AppDelegate.account`; queue the URL if it is
still nil and replay it on set.

### D.5 Settings › Account

A new first section in `SettingsView`, `AccountSection` (F.6). Plan, renewal, Manage Subscription…, Refresh, Sign Out….
Hidden entirely in mode `off`.

### D.6 Offline, caching and grace (`EntitlementPolicy`, pure)

```swift
enum Access: Equatable { case plus, plusGrace(until: Date), free }
static let offlineValidity: TimeInterval = 30 days   // how long a cached "active" is trusted without a check
static let gracePeriod: TimeInterval = 7 days        // past the period end or a failed payment
static func access(_ e: Entitlement, now: Date) -> Access
```

Rules, in order:
1. `plan == .free` or `status ∈ {none, expired}` → `.free`.
2. `status ∈ {active, trialing}` and `now < currentPeriodEnd` and `now < checkedAt + offlineValidity` → `.plus`.
3. `status ∈ {active, trialing, pastDue}` and `now < (currentPeriodEnd ?? checkedAt) + gracePeriod` → `.plusGrace(until:)`.
   (Covers: offline over a renewal date; a card that failed and Stripe is retrying.)
4. `status == .canceled` and `now < currentPeriodEnd` → `.plus` (paid until the end); after it → `.free`, no grace.
5. Otherwise → `.free`.

When to refresh: at launch (non-forced: only if `checkedAt` > 24 h ago), on becoming active (same), on any Refresh
button, after `uncloud://` URLs, and before opening a paid feature when `access` is `.plusGrace` (fire and forget; the
feature opens on the grace answer). A refresh that fails with `.offline` keeps the cache untouched. A refresh that
returns `.signedOut` (refresh token revoked) → signed out, per B.1.

What the user sees in grace: a caption in Settings › Account (F.6) and, on Plus features, nothing. No banners in the
panes; a lapsed card is the only case worth a banner and that is email's job (Stripe sends it).

---

## E. Next phase: server sketch (not built now)

### E.1 Stack

- **Vercel** functions (TypeScript, `api/v1/*`), one project, domain e.g. `api.uncloud.app` (Q5).
- **Stripe**: one Product "Uncloud Plus", one Price `$10.00 USD / year`. **Stripe Checkout** (hosted page, mode
  `subscription`) shows card, Apple Pay and Google Pay automatically where the browser supports them; Apple Pay on the
  web needs the domain verified in Stripe (Settings › Payment methods). **Customer portal** for manage/cancel.
  Stripe Tax optional (Q6).
- **DB**: Supabase Postgres (or Vercel Postgres/Neon). Tables: `accounts(id, email unique, stripe_customer_id, created_at)`,
  `auth_challenges(id, email, code_hash, expires_at, attempts, created_at)`, `refresh_tokens(id, account_id, hash, created_at, revoked_at)`,
  `entitlements(account_id pk, plan, status, current_period_end, cancel_at_period_end, stripe_subscription_id, updated_at)`.
  (KV is enough for challenges but Postgres keeps it to one store.)
- **Email**: Resend or Postmark for the code email. From "Uncloud <hello@uncloud.app>".
- Secrets (Stripe secret key, webhook secret, signing key, email API key) live only in Vercel env vars.

### E.2 Endpoints and JSON contract (the stub returns these same shapes)

All JSON, `Content-Type: application/json`, dates ISO 8601 UTC. Authenticated calls send `Authorization: Bearer <accessToken>`.
Errors: HTTP 4xx/5xx with `{ "error": { "code": "wrong_code", "message": "…", "retryAfter": "…?" } }`, codes mapping 1:1 to
`AccountError`: `invalid_email`, `wrong_code`, `code_expired`, `too_many_attempts`, `rate_limited`, `unauthorized` (→ `signedOut`
after one refresh attempt), `checkout_unavailable`, `server_error`.

| Method, path | Request | Response 200 |
|---|---|---|
| `POST /v1/auth/code` | `{ "email", "intent": "signUp" \| "signIn" }` | `{ "challenge": { "id", "email", "expiresAt", "resendAfter" } }` |
| `POST /v1/auth/verify` | `{ "challengeId", "code" }` | `{ "account": { "id", "email" }, "tokens": { "accessToken", "refreshToken", "accessExpiresAt" }, "entitlement": Entitlement, "isNewAccount" }` |
| `POST /v1/auth/refresh` | `{ "refreshToken" }` | `{ "tokens": … }` (refresh token rotates) |
| `POST /v1/auth/signout` | `{ "refreshToken" }` | `204` |
| `GET /v1/me` | — | `{ "account", "entitlement": Entitlement }` |
| `POST /v1/checkout` | `{}` | `{ "url": "https://checkout.stripe.com/…" }` |
| `POST /v1/portal` | `{}` | `{ "url": "https://billing.stripe.com/…" }` |
| `POST /v1/stripe/webhook` | Stripe event (signature-checked) | `200` |
| `GET /checkout/done` | `?session_id=` | HTML: "You’re subscribed. Return to Uncloud." + redirect to `uncloud://checkout/success?session_id=…` |
| `GET /checkout/cancelled` | — | HTML + redirect to `uncloud://checkout/cancel` |

`Entitlement` JSON: `{ "plan": "free"|"plus", "status": "none"|"active"|"trialing"|"pastDue"|"canceled"|"expired",
"currentPeriodEnd": "…"|null, "cancelAtPeriodEnd": bool, "checkedAt": "…", "signature": "…" }`.

Server rules: codes are 6 random digits, stored hashed, valid 10 min, 5 attempts, resend after 30 s, at most 5 codes per
email per hour and 20 per IP per hour. Access token: 1 h JWT. Refresh token: 90 days, rotating. `checkout` creates the
Stripe customer on first use, passes `client_reference_id = account.id`, `customer_email`, `success_url` / `cancel_url`
above. Webhook handles `checkout.session.completed`, `customer.subscription.created|updated|deleted`,
`invoice.payment_failed` and upserts `entitlements`. `/v1/me` reads the DB, never Stripe, so it's fast.

### E.3 Client: `HTTPAccountService`

`actor HTTPAccountService: AccountService` over `URLSession` with `baseURL` from `UncloudAPIBaseURL`. Maps the error
codes, retries `unauthorized` once after `refresh`, treats `URLError.notConnectedToInternet` / timeouts as `.offline`.
Timeout 15 s. No secrets in the client: the base URL and the entitlement public key (E.4) are public.

### E.4 Signed entitlement (anti-tamper, cheap)

The server signs the entitlement JSON (Ed25519) and the app verifies it with CryptoKit and an embedded **public** key
before caching. An edited `uncloudEntitlement` default then reads as Free. It's a $10 app with a public repo; this stops
casual edits, not a determined patcher, and that's fine.

---

## F. Visual spec

Shared: system window background, `AccentColor` (sky blue), SF Pro via system fonts, `Tokens.Space`, `Tokens.Radius`,
`IconTile` tinted with the accent (one hue: colour isn't decoration). Light and dark come from system colours; no
custom colours are added. No Apple logos or Apple-styled sign-in buttons. All screens live in the 1000 × 700 default
window (min 760 × 500) and scroll when shorter.

### F.1 Welcome (`WelcomeView`)

```
┌───────────────────────────────────────────────────────────────────────────┐
│                         [ App icon 88 pt ]                                  │
│                      Take Your Photos Home                                  │  .largeTitle bold
│     Export full-quality originals from iCloud to your own drive,            │  .title3 secondary, max 460
│          then keep your backup safe, tidy and easy to browse.               │
│                                                                             │
│   [tile] Export  · Free           [tile] Automatic Backups                  │  2-column grid, max 640
│          Copy originals from…            Exports new photos when…           │
│   [tile] New Photos               [tile] Browse Backup                      │
│   [tile] Find Duplicates          [tile] Verify Backup                      │
│   [tile] Free Up Space            [tile] Clean Up iCloud                    │
│                                                                             │
│     Export is free. Everything else is Uncloud Plus, $10 a year.            │  .callout secondary
│              [ Create Account ]   [ Sign In ]                               │  .large; prominent + bordered
│                                                                             │
│   🔒 Your photos go straight from Apple to your drive, never through Uncloud.│  .footnote
└───────────────────────────────────────────────────────────────────────────┘
```

- Column `maxWidth: 640`, centred vertically like `LandingView` (GeometryReader + ScrollView + Spacers), horizontal
  padding `Tokens.Space.l`, vertical `Tokens.Space.xxxl`. Spacing: logo → title `Space.m`; title → subtitle `Space.s`;
  hero → grid `Space.xxxl`; grid → plan line `Space.xxl`; plan line → buttons `Space.m`; buttons → footer `Space.xxl`.
- Background: window background plus a very light accent wash from the top (a `LinearGradient` of accent at
  `Tokens.Hero.wash` to clear over the top 280 pt). In dark mode the same wash at `wash` (it already reads as subtle).
- Grid: `Grid(horizontalSpacing: Space.xxl, verticalSpacing: Space.l)`, two `GridRow`s per pair, each cell a `FeatureRow`
  (new, in `Uncloud/Views/Account/FeatureRow.swift`): `IconTile(symbol:, tint: accent, size: Tokens.Tile.feature)` +
  `VStack(spacing: 2) { title .headline; summary .callout secondary, 2 lines max, fixedSize vertical }`. Export's title
  is followed by a "Free" capsule: `.caption2.weight(.semibold)`, accent foreground, accent at 0.12 fill, `Radius.s`,
  padding 2 × 6, `.accessibilityLabel("free")`.
- Under 700 pt of column width (window < ~760) the grid stays two columns; the cells' text wraps. No one-column switch.
- Buttons: `HStack(spacing: Space.m)`, both `.controlSize(.large)`, min width 140. **Create Account**
  `.borderedProminent` `.keyboardShortcut(.defaultAction)`; **Sign In** `.bordered`.
- Footer: `lock.shield` + text, `.footnote`, secondary.

Feature rows (title / symbol / one line). `PaidFeature.summary` reuses the same lines; Export's lives in `WelcomeView`.

| Title | Symbol | Line |
|---|---|---|
| Export | `photo.on.rectangle.angled` | Copy full-quality originals from iCloud Photos or Photos on this Mac to any drive. |
| Automatic Backups | `clock.arrow.circlepath` | Exports new photos on its own when your drive connects, or once a day. |
| New Photos | `bell.badge` | Lets you know when new photos are waiting to be backed up. |
| Browse Backup | `map` | Look through your backup by date or on a map, no iCloud needed. |
| Find Duplicates | `doc.on.doc` | Finds photos saved more than once, so you can tidy up. |
| Verify Backup | `checkmark.shield` | Checks that every file in your backup is intact. |
| Free Up Space | `externaldrive.badge.minus` | Removes backed-up photos from this Mac to make room. |
| Clean Up iCloud | `icloud` | Deletes backed-up photos from iCloud, and recovers them if you change your mind. |

Strings: hero "Take Your Photos Home"; subtitle as above; plan line "Export is free. Everything else is Uncloud Plus,
$10 a year."; footer "Your photos go straight from Apple to your drive, never through Uncloud." (Q7 alt hero lines.)

### F.2 Sign Up (`AccountEmailView(intent: .signUp)`)

Centred column, `maxWidth: 360`. Top-left of the window (not the column): **Back** button, `chevron.left` + "Back",
`.borderless`, `.cancelAction`, padding `Space.l`.

```
                 [ App icon 56 pt ]
            Create Your Uncloud Account                .title semibold, header
   Enter your email and we’ll send you a 6-digit       .body secondary, centred
         code. There’s no password to remember.
   ┌──────────────────────────────────────────┐
   │ name@example.com                          │       TextField, .roundedBorder, .large
   └──────────────────────────────────────────┘
   ⚠ Enter a valid email address.                       only after a submit attempt
   [               Continue               ]             .borderedProminent .large, full width, default
   By creating an account, you agree to the Terms of Use and Privacy Policy.   .footnote secondary, links
            Already have an account? Sign In            .callout; "Sign In" is a .link button
```

- Field: `TextField("Email", text:, prompt: Text("name@example.com"))`, `.textContentType(.emailAddress)` (macOS 14
  has it; fall back to `.username` if not), `.autocorrectionDisabled()`, `.onSubmit` submits.
  Accessibility label "Email".
- **Continue** disabled until `EmailAddress.normalized` is non-nil. Pressing Return while invalid shows the inline error
  (the button is disabled, so `.onSubmit` triggers the validation message instead).
- Loading: the button's label becomes `ProgressView().controlSize(.small)` + "Sending code…" and stays the same width;
  the field is disabled; Esc cancels.
- Errors appear under the field (F.7). Terms / Privacy links go to `https://uncloud.app/terms` / `/privacy` (Q5); in
  preview mode they point at the GitHub repo's README.

### F.3 Sign In (`AccountEmailView(intent: .signIn)`)

Same layout. Title "Sign In to Uncloud". Body "Enter the email you used for your Uncloud account and we’ll send you a
code." No terms line. Bottom: "New to Uncloud? Create Account" (link). The email typed on one screen carries to the
other when switching.

### F.4 Code (`AccountCodeView`)

```
                 [ envelope.badge  IconTile 44, accent ]
                  Check Your Email                      .title semibold
      Enter the 6-digit code we sent to name@example.com.   email in .semibold
             ┌──────────────────────┐
             │      1 2 3 4 5 6      │                   .system(.title, design: .monospaced), tracking 6, centred, width 220
             └──────────────────────┘
   ⚠ That code isn’t right. Check it and try again.
   [                 Verify                 ]           prominent, large, full width, default
       Send a New Code  ·  Use a Different Email        .link buttons, .callout
       🔨 Preview build: the code is 123456.             preview mode only, .footnote secondary, symbol hammer
```

- Field: `.textContentType(.oneTimeCode)`, `OneTimeCode.sanitized` on change; **auto-submits** when it reaches 6 digits
  (once per value; not again until edited). Accessibility label "Verification code".
- Verify disabled until 6 digits. Loading: "Checking…" in the button.
- **Send a New Code** disabled until `resendAfter`; its title reads "Send a New Code in 0:24" while counting (a
  `TimelineView(.periodic(from:by: 1))`). After sending: a caption "We sent a new code." for 4 s.
- **Use a Different Email** = Esc = back to the email screen with the email kept.
- On success: the window moves to `MainWindow` (B.1).

### F.5 Paywall sheet (`PaywallSheet`)

`SheetScaffold`-like, width **460**, no fixed height.

```
   [ App icon 64 ]
   Get Uncloud Plus                                      .title2 semibold
   Browse Backup is part of Uncloud Plus.               .callout secondary  (only when opened by a feature)
   Keep your backup safe, tidy and up to date, on its own.   .body
   ─────────────────────────────────────
   ◉ Automatic Backups   ◉ New Photos                   2-column compact list: symbol (accent, .body) + title
   ◉ Browse Backup       ◉ Find Duplicates               .callout; the opening feature's row in .semibold
   ◉ Verify Backup       ◉ Free Up Space
   ◉ Clean Up iCloud
   ─────────────────────────────────────
   $10 a year. Cancel anytime.                           .headline
   Pay with card, Apple Pay or Google Pay on Stripe’s secure checkout page.   .caption secondary
   ─────────────────────────────────────
   Already Subscribed? Refresh            [ Not Now ] [ Subscribe — $10/Year ]
```

- Footer: left `.link` "Already Subscribed? Refresh"; right **Not Now** (`.cancelAction`) and **Subscribe — $10/Year**
  (`.borderedProminent`, `.defaultAction`).
- States:
  - `opening`: primary shows a small spinner + "Opening Checkout…", disabled.
  - `waiting`: the price block is replaced by symbol `arrow.up.forward.app` +
    "Finish checking out in your browser, then come back here." Buttons: **Not Now**, **Open Checkout Again** (bordered),
    **Check Again** (prominent, default).
  - Refreshing: "Checking your plan…" spinner in place of the price block.
  - `active`: the whole content becomes `checkmark.seal.fill` (44 pt, `Tokens.Status.success`) + "You’re all set" (.title2)
    + "Uncloud Plus is on. Thank you for supporting Uncloud." Buttons: **Continue** only (default).
  - Refresh found no plan: caption "We couldn’t find a subscription for name@example.com." under the link.
  - Errors: `StatusBanner`-style inline label above the footer (F.7).
- `PaidFeature` symbols as in F.1.

### F.5b Locked pane (`LockedFeatureView(feature:)`)

`ContentUnavailableView`: label `"\(feature.title)"` with the feature's symbol + a `lock.fill` overlay (bottom-trailing,
`.caption`); description `feature.summary` + "It’s part of Uncloud Plus, $10 a year."; actions **Get Uncloud Plus…**
(prominent) and **Already Subscribed? Refresh** (link). `.navigationTitle` stays the pane's title.

### F.6 Settings › Account (`AccountSection`, first section of the `SettingsView` form)

Section header "Account". Rows by state:

| State | Rows |
|---|---|
| Signed out (mode preview/live) | "Not signed in" (secondary) · **Sign In…** (opens the main window on Sign In) |
| Free | `LabeledContent("Email", email)` · `LabeledContent("Plan", "Free")` · **Get Uncloud Plus…** (bordered) · "Already Subscribed? Refresh" (link) · **Sign Out…** |
| Plus, renewing | Email · Plan "Uncloud Plus" · `LabeledContent("Renews", "October 18, 2027")` · **Manage Subscription…** · **Sign Out…** |
| Plus, canceled | Plan "Uncloud Plus" · "Ends" date · caption "Your plan won’t renew. You can turn renewal back on in Manage Subscription." |
| Grace (offline) | caption with `wifi.slash`: "Couldn’t check your plan. Uncloud Plus stays on until October 25 while you’re offline." · Refresh |
| Grace (past due) | caption with `exclamationmark.triangle` (warning): "Your last payment didn’t go through. Update your card by October 25 to keep Uncloud Plus." · **Manage Subscription…** |
| Always (signed in) | caption, `.caption` secondary: "Plan checked today at 9:41." (relative date) |

Buttons in an `HStack` at the row's trailing edge, `.controlSize(.regular)`. **Sign Out…** opens a confirmation dialog:
title "Sign Out of Uncloud?", message "Your backup, backup folder and settings stay on this Mac. Uncloud Plus features
stay locked until you sign in again.", buttons **Sign Out** (default, not destructive-red: nothing is lost) / Cancel.
Disabled while `model.isExporting`, with `.help("You can sign out when the export finishes.")`.

Preview mode only (`#if DEBUG` and mode `preview`), a final "Preview" section: buttons **Make Plan Free**,
**Make Plan Plus**, **Cancel at Period End**, **Expire Now**, **Simulate Offline** (toggle). They edit the
`PreviewAccountStore` and call `refreshEntitlement(force: true)`.

Settings width stays 460.

### F.7 Final strings (errors and status)

| Case | String |
|---|---|
| invalidEmail | Enter a valid email address. |
| wrongCode | That code isn’t right. Check it and try again. |
| codeExpired | That code has expired. Send a new one. |
| tooManyAttempts | Too many tries. Send a new code and try again. |
| rateLimited | Too many codes requested. Try again in a few minutes. |
| offline | Can’t reach Uncloud. Check your internet connection and try again. |
| server | Something went wrong on our side. Try again in a moment. |
| signedOut (revoked) | You’ve been signed out. Sign in again to keep using Uncloud Plus. |
| checkoutUnavailable | Checkout isn’t available right now. Try again later. |
| Code sent caption | We sent a new code. |
| Welcome back (verify, existing account via Sign Up) | Announcement only: "Welcome back" |

Button titles (title case): Create Account, Sign In, Continue, Verify, Send a New Code, Use a Different Email, Back,
Subscribe — $10/Year, Not Now, Already Subscribed? Refresh, Open Checkout Again, Check Again, Continue,
Get Uncloud Plus…, Manage Subscription…, Sign Out…, Sign Out. Ellipses only where another step follows (polish rule).

---

## G. Tests

Swift Testing, `@MainActor` where the model is involved, everything with injected clocks and in-memory stores. Owned
by the chunk that adds the code (H).

**Unit (new):**
- `AccountValidationTests`: emails (valid, uppercase → lowercased, spaces trimmed, two `@`, no dot, trailing dot,
  255 chars, unicode local part rejected or accepted as decided — accept), codes (sanitize paste with spaces/text,
  7 digits truncated, letters stripped, `isComplete`).
- `PreviewAccountServiceTests`: request → verify with 123456 succeeds; wrong code ×5 → `tooManyAttempts`; expired
  after 10 min (clock); resend before `resendAfter` → `rateLimited`; simulation emails; checkout flips to Plus with a
  one-year period end; isNewAccount true then false for the same email.
- `AccountModelTests`: signed out → submitEmail → `.code` route → submitCode → `.signedIn` and tokens saved; Esc/back
  from code keeps the email; cancelRequest leaves the route; signOut clears tokens + account and returns to Welcome;
  signOut refused while an export runs (inject an `isExportRunning` closure); revoked token on refresh while exporting
  defers the sign-out; mode `.off` → `phase == .off`, `allows` always true; `preview` in a non-DEBUG configuration
  maps to `off` (test `AccountConfiguration.resolve(mode:isDebug:baseURL:)` as a pure function); `live` without an
  https base URL → `off`.
- `EntitlementGatingTests`: `require` runs the action when allowed; opens `paywall` with the feature when not; runs the
  pending action after the paywall reaches `active`; doesn't run it on Not Now. `ExportModel.visibleNewPhotosStatus` is nil
  when `.newPhotos` isn't allowed. `AutoBackupController` doesn't start an automatic run when not allowed (use the
  existing fakes or a seam closure).
- `EntitlementPolicyTests`: every rule in D.6 at its boundaries (period end ± 1 s, checkedAt + 30 days, grace end,
  canceled before/after end, pastDue in grace, free).
- `AccountURLTests`: each URL in D.2 parses; wrong scheme, wrong host, extra path, uppercase scheme, a 300-char or
  non-alphanumeric `session_id` → nil/no id; `handle` in mode `.off` returns false; success URL → refresh → paywall
  `active`.
- `ExportPaneRenameTests` (tiny): `ExportModel().pane == .export`.

**Snapshots (new `AccountSnapshotTests.swift`)**, gated on `UNCLOUD_ACCOUNT_SNAPSHOTS`, rendered with the same
`renderWindow` helper pattern as `UIRefreshSnapshotTests` (copy the helper; don't import it), recorded as `Attachment`s,
light and dark, default accent only:
Welcome (1000 × 700 and 760 × 500), Sign Up (empty, invalid, loading), Sign In, Code (empty, error, preview hint,
resend countdown), Paywall (no feature, opened by Browse Backup, waiting, active), LockedFeatureView, Settings with the
Account section in Free, Plus, Grace offline, and signed out; the full `MainWindow` sidebar with locks.

**Existing tests to update:** `UIRefreshSnapshotTests.swift:96` (`LibraryWindow()` → `MainWindow()`); any test that
builds `SettingsView()` or `MainWindow()` now needs `.environment(AccountModel.preview(...))` — add a
`AccountModel.forTesting(mode: .off)` helper so old snapshots look exactly as before. `BackupHeroContentTests` are
unaffected (gating is upstream of `make`).

---

## H. Build chunks

Three chunks, sequential (each builds on the last). Shared rules from `polish-plan.md` §6 apply: Swift 6 strict
concurrency, macOS 14 target, `#available(macOS 26, *)` with else branches, `xcodegen generate` after adding files,
decorative symbols hidden from accessibility, no change to `Uncloud/Export/**`, `Uncloud/Helper/**` or export logic.
Run your own tests while developing; the orchestrator runs the full suite at the end.

### Chunk 1: Export rename + account core (no UI)

Owns: `Uncloud/Model/ExportModel.swift` (Pane rename, `isFeatureAllowed`, `visibleNewPhotosStatus` only),
`Uncloud/Views/LibraryView.swift` → `ExportView.swift`, `LibraryWindow.swift` → `MainWindow.swift` (rename + strings only),
`Uncloud/App/ExportCommands.swift` (Export ⌘1 only), `Uncloud/Views/BackupPane.swift` (`.export` only),
**new** `Uncloud/Account/{AccountTypes,AccountService,AccountValidation,PreviewAccountService,AccountTokenStore,EntitlementPolicy,AccountURL,AccountConfiguration,AccountModel}.swift`,
`project.yml` (D.3), **new** `Uncloud/App/Info.plist`, `Uncloud/App/TestHost-Info.plist` (generated by XcodeGen),
tests: `AccountValidationTests`, `PreviewAccountServiceTests`, `AccountModelTests`, `EntitlementPolicyTests`,
`AccountURLTests`, `ExportPaneRenameTests`, and the `UIRefreshSnapshotTests.swift:96` fix.

Acceptance:
- No user-visible string "Library" names the pane anywhere (sidebar, title, View menu). ⌘1 says Export.
- `AccountModel` runs every flow in A/B/D against the stub in unit tests; all listed tests pass.
- `plutil -p` on the built Debug app shows `CFBundleURLTypes` with `uncloud` and `UncloudAccountMode = preview`;
  Release shows `off`; the test host has no URL types.
- The app looks and behaves exactly as before (AccountModel exists but isn't wired into views yet).

### Chunk 2: Welcome, Sign Up, Sign In, Code, root switch, menus (UI, designer agent)

Owns: **new** `Uncloud/Views/Account/{RootView,WelcomeView,FeatureRow,AccountEmailView,AccountCodeView}.swift`,
`Uncloud/App/UncloudApp.swift` (RootView, AccountModel creation and environment, `AppDelegate.account` +
`application(_:open:)`), `Uncloud/App/ExportCommands.swift` (the `showsAppMenus` conditionals), `UncloudTests/AccountSnapshotTests.swift`
(account screens part), `AccountModel.forTesting` usage in existing snapshot tests.

Acceptance:
- Debug launch, signed out: the window shows Welcome with no sidebar; the menu bar matches B.2 exactly (verify by
  listing menu titles in a snapshot or manually).
- Create Account → email → Continue → Code shows "Preview build: the code is 123456" → typing it auto-verifies → main
  window with all menus, on Export (or the landing page if no source).
- Return submits and Esc goes back on every screen; errors from the simulation emails appear with the F.7 strings.
- Quit and relaunch: still signed in. `-UncloudAccountMode off` launches straight into today's app.
- Snapshots for F.1–F.4 in light and dark render without clipping at 1000 × 700 and 760 × 500.

### Chunk 3: Paywall, locks, Settings › Account, gating (UI + wiring)

Owns: **new** `Uncloud/Views/Account/{PaywallSheet,LockedFeatureView,AccountSection}.swift`,
`Uncloud/Views/MainWindow.swift` (sidebar locks, locked panes, paywall sheet), `Uncloud/Views/BackupToolSheets.swift`
(`BackupToolButtons` lock symbols + `require`), `Uncloud/App/ExportCommands.swift` (`require` on Backup menu tools, Sort
disabled when locked), `Uncloud/Views/SettingsView.swift` + `NewPhotosViews.swift` (AccountSection, locked toggles row),
`Uncloud/Model/AutoBackupController.swift` (`isAllowed` at run start), `Uncloud/Model/BrowseBackup.swift` (`isEnabled`
only), `Uncloud/Views/MenuBarContent.swift` + `UncloudApp.swift` (menu bar insertion ANDed with the entitlement),
`Uncloud/Views/BackupHero.swift` callers (use `visibleNewPhotosStatus`), tests: `EntitlementGatingTests`,
`AccountSnapshotTests` (paywall, locked, Settings parts).

Acceptance:
- Free account: Browse Backup and Clean Up iCloud show a lock; choosing either shows the locked view and the paywall.
  Verify / Find Duplicates / Free Up Space (buttons and menu items) open the paywall. Settings shows the automatic
  backup toggles off and disabled with the Plus row; saved values are untouched (`defaults read` before/after).
- Subscribe in preview → the app receives `uncloud://checkout/success…` → the paywall shows "You’re all set" →
  Continue opens the feature that was chosen. Settings shows Plus with a renewal date a year out.
- Preview › Expire Now locks everything again **without** stopping a running export or Verify.
- Simulate Offline + clock past the period end shows the grace caption; after the grace end, Free.
- Sign Out is disabled during an export and returns to Welcome otherwise.
- With `-UncloudAccountMode off`, every lock, the Account section and the paywall are gone and every existing snapshot
  matches its pre-change image.

---

## Questions for the owner

1. **Plan name**: "Uncloud Plus"? (Alternatives: "Uncloud Pro", or no name, just "Subscription".)
2. **New Photos**: paid as a whole (badge, hero line, reminders), or keep the sidebar count free and charge only for
   reminders? Recommended: paid as a whole.
3. **Export history and Activity**: free (recommended), or part of Plus?
4. **Clean Up iCloud's Recover**: paid with the pane (recommended), or always free so nobody who deleted while
   subscribed is ever stuck? (A lapsed user can still recover in iCloud.com/Photos, so paid is safe.)
5. **Domain** for the API, the checkout return page, Terms and Privacy (e.g. `uncloud.app`), and who writes the Terms.
6. **Tax**: turn on Stripe Tax (prices shown as $10 + tax where required), or price tax-inclusive?
7. **Hero line**: "Take Your Photos Home" — or "Your Photos, Safely on Your Own Drive" / "Keep Every Photo. Free Up iCloud."
8. **Free trial** (e.g. 7 days via Stripe `trial_period_days`)? The design supports `trialing` already; default is none.

---

## Owner decisions (2026-10-18) — these override anything above

1. Plan name: **Uncloud Plus**.
2. New Photos: the sidebar badge / "N new photos" count and hero line stay **free** (and Export New Photos, being an export, is free). **Reminders and automatic backups are paid.**
3. **Recover (Recently Deleted in Clean Up iCloud) is free**, so someone whose plan lapsed can always get back photos they deleted with Uncloud. Deleting from iCloud stays paid. The Clean Up iCloud pane therefore opens for free users in Recently Deleted mode only; the Library/delete mode shows the lock and paywall.
4. **No free trial.**
5. Welcome hero line: **"Take Your Photos Home"**.
6. Domain, Terms/Privacy URLs and tax handling are deferred to the Stripe phase; use placeholders behind constants.
