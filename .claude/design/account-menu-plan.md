# Uncloud account menu, Account settings and Delete Account: plan

Status: plan only. Author: architecture (Opus), 2026-10-18. Branch `feature/duplicates-and-icloud-cleanup` (after
c6b542f). Builds on `account-paywall-plan.md` (A–D, F, owner decisions) and `stripe-payments-plan.md` (§4 routes, §5.4
Settings › Account, orchestrator decisions). Where they disagree, this file wins for the account menu, the Settings
window layout and account deletion. Style and terms follow `polish-plan.md` §2 (glossary) and §6 (shared rules).

Owner's request (after a working Stripe test checkout): "We now need user profile and subscription management menu."

---

## 0. Decisions at a glance

| Topic | Decision |
|---|---|
| Where the account lives | A round **account button** (email initial) in the **sidebar's titlebar area** of the main window. It opens a **popover** (280 pt) with the email, the plan badge, one status line and the actions. |
| Menus | **Uncloud ▸ Account Settings…**, the plan action (**Get Uncloud Plus…** / **Manage Subscription…** / **Update Payment Method…**) and **Sign Out of Uncloud…**, placed after Settings…. The menu bar extra gains lines **only** when a payment failed or the plan can't be checked. |
| Settings window | Becomes a **tabbed** window: **General** and **Account**. In mode `off` it stays the single form it is today (snapshots unchanged). |
| Profile | Email (selectable) and **Member since**. **No display name** (nothing in Uncloud shows it; Stripe receipts use the billing name). |
| Change email | **Deferred** (§5). A caption tells people how to get it changed. |
| Delete Account | **Included**, server + app: `POST /v1/account/delete`, typed-email confirmation, subscription cancelled now with no automatic refund, saved cards removed, Stripe customer kept for tax records with the user link scrubbed, Supabase user deleted (rows cascade). |
| Naming | "**Uncloud account**" for ours, "**Apple Account**" for Apple's. Account menu items always say "Uncloud"; the sidebar footer keeps the photo source and Apple Account. |
| State → view | One pure view model, `AccountSummary`, feeds the popover, the Account tab, the app menu and the menu bar extra, so all four say the same thing. |

---

## 1. Where the account lives

### 1.1 The account button (main window)

- Placement: `.toolbar { ToolbarItem(placement: .automatic) { AccountButton() } }` attached to the **sidebar `List`** in
  `MainWindow`. On macOS 14+ an item on the sidebar column sits in the sidebar's part of the titlebar, at its trailing
  edge, beside the sidebar toggle. That is the "top of the sidebar" and stays clear of each pane's own toolbar (Export,
  Backup, Clean Up and Browse all put their primary buttons in the detail toolbar).
  - The engineer checks it on macOS 14 and 26. If the item lands in the detail toolbar on either, move it to
    `ToolbarItem(placement: .primaryAction)` on the `NavigationSplitView` as the **last** item and note it in the PR.
  - When the sidebar is collapsed the button is hidden with it. The app menu items (§1.3) still work, and that's fine.
- Shown only when `account.mode != .off` and `phase == .signedIn`. Signed out, the window shows Welcome, which has no
  sidebar. While `restoring`, the button shows the `person.crop.circle` symbol, disabled.
- **Look** (`AccountAvatar`, 22 pt circle, reused at 40 pt in Settings and the popover):
  - Initial: the first character of the email's local part, uppercased, `.system(size: 11 / 18, weight: .semibold)`.
    If it isn't a letter or digit, show `person.crop.circle.fill` instead.
  - Free: fill `.quaternary`, initial `.secondary`.
  - Plus (any paid state): fill accent at 0.18 opacity, initial in the accent colour.
  - Needs attention (past due, offline grace): a 7 pt `Tokens.Status.warning` dot at the top-trailing edge with a
    1.5 pt ring in the window background. Colour means status only (polish-plan rule).
  - `.buttonStyle(.borderless)`, hit area 28 × 28, `.help("Your Uncloud account and plan")`.
- **Accessibility**: label "Uncloud Account". Value: "name@example.com, Free" / "…, Uncloud Plus" / "…, Uncloud Plus,
  payment didn’t go through" / "…, Uncloud Plus, couldn’t check your plan". Trait `.isButton`. The dot and initial are
  hidden from VoiceOver (the value says it).

### 1.2 The account popover (`AccountPopover`, width 280)

```
 ( B )  barishiz@gmail.com                          avatar 40, email .headline, middle-truncated, selectable
        [ Uncloud Plus ]                            badge capsule: Free = .quaternary fill / .secondary text;
                                                    Plus = accent 0.12 fill / accent text; .caption.weight(.semibold)
 Renews on October 18, 2027.                        status line .callout .secondary (warning lines: symbol + warning colour)
 ───────────────────────────────────────────
 [ Manage Subscription… ]                           the one primary action (style per state, §3), full width
 Account Settings…                                  .buttonStyle(.link), leading aligned
 Sign Out of Uncloud…                               .buttonStyle(.link), disabled while an export runs
```

- Padding `Tokens.Space.l`, spacing `Tokens.Space.m`; `Divider()` between header and actions.
- Opening it puts focus on the primary button; Tab moves through the three actions; Esc closes (system). Each action
  closes the popover first.
- **Account Settings…** writes `SettingsTab.account` (§2.1) and calls `openSettings()`.
- **Sign Out of Uncloud…** sets `account.isConfirmingSignOut = true`. The dialog is hosted once in `RootView`
  (signed-in branch), so the popover and the app menu share it. Settings keeps its own dialog for its own button.
- Tooltip on a disabled Sign Out: "Sign out after the export finishes."

### 1.3 App menu (Uncloud ▸)

`CommandGroup(after: .appSettings)`, only when `mode != .off` and `phase == .signedIn`:

```
Uncloud
  About Uncloud
  ─────
  Settings…                    ⌘,      (system)
  Account Settings…                    opens Settings on the Account tab
  Get Uncloud Plus…                    Free; or "Manage Subscription…" (Plus); or "Update Payment Method…" (past due)
  Sign Out of Uncloud…                 disabled while an export runs
  ─────
  Services ▸ … Hide, Quit (system)
```

- No new shortcuts. ⌘, already opens Settings and the Account tab is one click away. macOS has no standard shortcut
  for a Settings tab, so we don't invent one.
- `Commands` gets `@Environment(\.openSettings)` (macOS 14) and writes the tab (§2.1) before calling it. If that
  environment value doesn't work inside `Commands` on 14, use `SettingsLink { Text("Account Settings…") }` and set
  `account.pendingSettingsTab = .account` from the button's own action path. `SettingsView` reads it in
  `.onAppear`/`.onChange` and clears it. The engineer uses whichever works and notes it in the PR.
- Signed out: nothing is added (B.2 of the paywall plan keeps signed-out menus minimal; Welcome is on screen).
- The File menu's **Sign In to iCloud… / Sign Out of iCloud…** stay where they are. "of iCloud" vs "of Uncloud" keeps
  the two apart.

### 1.4 Menu bar extra

The extra is shown only to Plus accounts with automatic backups on, so it adds lines **only when there is something to
do**, between the new-photos line and Export Now:

| State | Lines |
|---|---|
| Past due | disabled text "Uncloud Plus: your last payment didn’t go through" · button **Update Payment Method…** (opens the portal) |
| Offline grace | disabled text "Uncloud Plus: couldn’t check your plan" · button **Check Again** |
| Anything else | nothing |

`MenuBarContent` gains `.environment(account)` from `UncloudApp`.

### 1.5 Keeping it apart from the photo source

- The sidebar footer stays the **photo source** (iCloud Photos / Photos on This Mac, and the Apple Account for iCloud).
  Change only its `.help` to "Choose where photos come from, or change the Apple Account used for iCloud Photos".
- The account button is a round initial at the **top**; the source is a symbol row at the **bottom**. Never put the
  Uncloud email in the footer or the Apple Account in the popover.
- Glossary additions (`polish-plan.md` §2):

| Concept | Use (UI) | Retire |
|---|---|---|
| Our account | **Uncloud account** ("Sign Out of Uncloud…", "Delete Your Uncloud Account?") | "profile", "login", "user" |
| Apple's account | **Apple Account** (unchanged) | Apple ID, iCloud account |
| The paid plan | **Uncloud Plus**; the free plan **Free** | Pro, Premium, subscription tier |
| Stripe's page | **the billing page** (in sentences); button **Manage Subscription…** | Stripe portal, customer portal |

---

## 2. Settings window: General and Account tabs

### 2.1 Structure

```swift
enum SettingsTab: String { case general, account }   // @AppStorage("uncloudSettingsTab"), default .general
```

- `SettingsView.body`:
  - `mode == .off` → today's single `Form` exactly (rename it `GeneralSettingsForm`, move the body there unchanged
    except that the `AccountSection` line is removed from it).
  - otherwise → `TabView(selection: $tab)` with
    `GeneralSettingsForm().tabItem { Label("General", systemImage: "gearshape") }.tag(.general)` and
    `AccountSettingsForm().tabItem { Label("Account", systemImage: "person.crop.circle") }.tag(.account)`.
- Width stays 460; each tab's `Form` is `.formStyle(.grouped)` and sizes to its content (the window resizes per tab,
  as System Settings–style tabbed preference windows do on macOS).
- `AccountSection.swift` is replaced by `AccountSettingsForm.swift` (same folder). The renewal binding, `checkedText`
  and the preview debug rows move over unchanged.

### 2.2 Account tab, signed in

```
Profile
  ( B )  barishiz@gmail.com                          avatar 40 + email (.textSelection), trailing nothing
         Member since October 2026                   .callout .secondary (hidden when createdAt is nil)
  To change your email, contact support.             .caption .secondary; "contact support" is a mailto Link (AccountLinks.support)

Subscription
  Plan                         [ Uncloud Plus ]      badge as in the popover
  Status                       Renews on October 18, 2027     the summary's status line (§3), warning style when it is one
  Price                        $9.99/year + tax      PlanCopy.yearlyPricePlusTax
  Renew automatically                     ( on )     Toggle(.switch); hidden for Free and past due; as today
                               Renews on October 18, 2027 for $9.99 plus tax.   caption, as today
  [ Manage Subscription… ]   Receipts and Invoices   bordered button + link; both open the billing page
  Plan checked today at 9:41.              Refresh   as today

  ─ (Free) ─
  Plan                         [ Free ]
  Status                       Export is free. Uncloud Plus adds automatic backups, Browse Backup and more.
                               (or) Uncloud Plus ended on October 18, 2027.
  Price                        $9.99/year + tax
  [ Get Uncloud Plus… ]  Already Subscribed? Refresh
  Receipts and Invoices        only when the plan ever existed (entitlement.status != .none)

(section without header)
  Sign Out…                                          destructive role, disabled while exporting (as today)

Delete Account
  Delete Account…                                    .buttonStyle(.link) in Tokens.Status.danger, disabled while exporting
  Deletes your Uncloud account and stops Uncloud Plus. Your photos and backup aren’t changed.   .caption .secondary

  Terms of Use · Privacy Policy                      as today
```

- Errors from any account action show under Subscription with `exclamationmark.triangle` in `Tokens.Status.danger`
  (as today).
- The preview Debug rows (Turn Renewal On/Off, Expire Now) stay at the bottom of Subscription in preview builds.

### 2.3 Account tab, other phases

| Phase | Content |
|---|---|
| `restoring` | one row: `ProgressView().controlSize(.small)` + "Loading your account…" |
| `signedOut` | Section "Uncloud Account": "Sign in to use Uncloud Plus on this Mac. Export is free without an account." · **Sign In…** (bordered) · **Create Account…** (link). Each calls `account.show(.signIn / .signUp)`, opens the main window and activates the app (as today). If `account.notice == .accountDeleted`, a first line "Your Uncloud account was deleted." (.callout .secondary). |
| `off` | the tab doesn't exist (§2.1) |

### 2.4 Delete Account sheet (`DeleteAccountSheet`, width 420, presented from the Account tab)

```
  [ person.crop.circle.badge.xmark, 40 pt, Tokens.Status.danger ]
  Delete Your Uncloud Account?                                     .title3 semibold
  This deletes the Uncloud account barishiz@gmail.com and signs you out on this Mac. It can’t be undone.   .body

  •  Uncloud Plus stops now and won’t renew. Time left on your plan isn’t refunded.    (only when paid)
  •  Your photos, your backup folder and iCloud Photos aren’t changed.
  •  Stripe keeps your receipts, as tax rules require. Your saved card is removed.      (only when a plan ever existed)

  Type your email to confirm                                       .callout label
  [ barishiz@gmail.com                       ]                     TextField, placeholder = the email, autocorrect off
  <inline error>                                                    .callout danger

                                   [ Cancel ]  [ Delete Account ]
```

- **Delete Account** is `role: .destructive`, **not** the default action (Return never triggers it, as Clean Up's typed
  confirmation). Enabled only when the field, trimmed and lowercased, equals the account email lowercased, and no
  export is running. **Cancel** is `.cancelAction` (Esc).
- While deleting: the button shows a small `ProgressView` and "Deleting…"; both buttons and the field are disabled.
- Success: the sheet and Settings stay open; the tab switches to the signed-out content with "Your Uncloud account was
  deleted."; the main window shows Welcome. Failure: inline error, the field keeps its text.
- If the refund line ever changes (owner Q1), only this sheet's string and the server's cancel options change.
- Accessibility: the bullets are one combined element each; the field's label is "Type your email to confirm"; the
  disabled button's help is "Type your email to delete your account."

### 2.5 Final strings

| Key | String |
|---|---|
| Popover / tab status, Free (never paid) | "Export is free. Uncloud Plus adds automatic backups, Browse Backup and more." |
| Free (ended) | "Uncloud Plus ended on October 18, 2027." |
| Plus renewing | "Renews on October 18, 2027." |
| Plus ending | "Ends on October 18, 2027. Renewal is off." |
| Past due | "Your last payment didn’t go through. Update your card by October 25 to keep Uncloud Plus." (`exclamationmark.triangle`, warning) |
| Offline grace | "Couldn’t check your plan. Uncloud Plus stays on until October 25 while you’re offline." (`wifi.slash`, secondary) |
| Unverified (Plus, last check failed offline, checked over a day ago) | extra meta line "Last checked October 12." |
| Member since | "Member since October 2026" (`.dateTime.month(.wide).year()`) |
| Change email caption | "To change your email, contact support." |
| Sign out dialog | title "Sign Out of Uncloud?" (title case, matching "Sign Out of iCloud?"), message unchanged: "Your photos and backup aren’t changed. Sign in again to use Uncloud Plus." |
| Delete sheet | as §2.4 |
| New `AccountError.confirmationMismatch` | "The email doesn’t match your Uncloud account." |
| Notice after delete | "Your Uncloud account was deleted." |
| Menu bar, past due | "Uncloud Plus: your last payment didn’t go through" · "Update Payment Method…" |
| Menu bar, offline grace | "Uncloud Plus: couldn’t check your plan" · "Check Again" |

Dates use `PlanText.date` (long, no time). The past-due "by" date keeps today's rule (anchor + `EntitlementPolicy.gracePeriod`).

### 2.6 SF Symbols (no Apple logos, no `applelogo`, no `icloud` on account UI)

`person.crop.circle` (tab, restoring, fallback), `person.crop.circle.fill` (avatar fallback), `gearshape` (General tab),
`exclamationmark.triangle` (past due, errors), `wifi.slash` (offline), `person.crop.circle.badge.xmark` (delete sheet),
`arrow.up.forward.app` (no new use; the paywall keeps it). Decorative symbols `.accessibilityHidden(true)`.

---

## 3. States and the view model

New pure file `Uncloud/Account/AccountSummary.swift`:

```swift
struct AccountSummary: Equatable {
    enum State: Equatable {
        case hidden                    // mode off
        case loading                   // restoring
        case signedOut
        case free(endedOn: Date?)      // endedOn when a plan existed and is over (expired/canceled past end)
        case plusRenewing(renewsOn: Date)
        case plusEnding(endsOn: Date)  // cancelAtPeriodEnd, still in the period
        case pastDue(updateBy: Date)
        case offlineGrace(until: Date)
    }
    enum PrimaryAction: Equatable { case getPlus, manage, updatePayment, checkAgain, signIn, none }

    let state: State
    let email: String?
    let initial: String?               // nil → symbol fallback
    let memberSince: Date?
    let badge: String?                 // "Free" / "Uncloud Plus" / nil
    let needsAttention: Bool           // the warning dot
    let primary: PrimaryAction
    let lastCheckedNote: Date?         // the "Last checked …" meta line, when unverified
    let showsReceipts: Bool            // entitlement.status != .none
    let showsRenewalToggle: Bool       // plusRenewing / plusEnding / offlineGrace with a period end

    static func make(mode: AccountMode, phase: AccountModel.Phase, account: UncloudAccount?,
                     entitlement: Entitlement, access: EntitlementPolicy.Access,
                     lastError: AccountError?, now: Date) -> AccountSummary
}
```

Rules (in order):

| # | Condition | State | Primary | Attention |
|---|---|---|---|---|
| 1 | `mode == .off` | hidden | none | no |
| 2 | `phase == .restoring` | loading | none | no |
| 3 | `phase == .signedOut` | signedOut | signIn | no |
| 4 | `entitlement.status == .pastDue` and `access != .free` | pastDue(anchor + grace) | updatePayment | yes |
| 5 | `access == .plusGrace(until)` (not past due) | offlineGrace(until) | checkAgain | yes |
| 6 | `access == .plus`, `cancelAtPeriodEnd` | plusEnding(periodEnd) | manage | no |
| 7 | `access == .plus` | plusRenewing(periodEnd) | manage | no |
| 8 | `access == .free` | free(endedOn: status != .none ? periodEnd : nil) | getPlus | no |

`lastCheckedNote` = `checkedAt` when access ≠ free, `lastError == .offline` and `now − checkedAt > 24 h`.
Primary styles: `getPlus`, `updatePayment` → `.borderedProminent`; `manage`, `checkAgain` → `.bordered`.
Actions: getPlus → `account.showPaywall()` (opens the main window first from Settings/menus, as `openPaywall` does
today); manage/updatePayment → `account.openManageSubscription()`; checkAgain → `refreshEntitlement(force: true)`.

The `canceled` status (rare; Stripe "canceled" maps to `expired` on the server) follows `access`: Plus until the end
(→ rule 6, shown as ending), then Free.

`AccountModel` additions: `var summary: AccountSummary { .make(..., now: .now) }`, `var isConfirmingSignOut = false`,
`private(set) var notice: Notice?` (`enum Notice { case accountDeleted }`, cleared on the next sign-in),
`private(set) var isDeletingAccount = false`, `func deleteAccount(confirmEmail: String) async -> Bool` (§4.4).

---

## 4. Delete Account (server + app)

### 4.1 Route `POST /v1/account/delete` (auth)

File `server/uncloud-api/api/v1/account/delete.js` (same `route('POST', …)` wrapper as `portal.js`), handler
`deleteAccount(request, deps)` in `lib/handlers.js`, Stripe/DB work in new `lib/account.js`.

Body `{ "confirmEmail": "name@example.com" }` → `204` on success.

| Code | HTTP | When |
|---|---|---|
| `unauthorized` | 401 | no/invalid JWT |
| `confirmation_mismatch` | 400 | `confirmEmail.trim().toLowerCase() !== auth.email.toLowerCase()` (new code → `AccountError.confirmationMismatch`) |
| `bad_request` | 400 | body not JSON / field missing |
| `rate_limited` | 429 | over 5 calls per user per hour (`enforceRateLimit`, key `delete:<userId>`) |
| `server_error` | 500 | Stripe or Supabase failed; nothing after the failing step ran |

### 4.2 Steps (order matters: stop charging first, delete the user last; every step is idempotent)

1. `auth = deps.verify(request)`; validate the body; rate-limit.
2. `customer = db.select('customers', { user_id }, { service: true })[0]`.
3. If `customer`:
   1. `subs = stripe.subscriptions.list({ customer, status: 'all', limit: 20 })`, keep ours (price lookup key
      `config.priceLookupKey`) with status in `active, trialing, past_due, unpaid, incomplete, paused`.
   2. For each: `subscriptions.update(id, { metadata: { user_id: '', uncloud_account_deleted: nowISO } })` **before**
      cancelling (a cancelled subscription can't be updated), then
      `subscriptions.cancel(id, { prorate: false, invoice_now: false }, { idempotencyKey: 'delete-' + id })`.
      `prorate: false` = no automatic refund (owner Q1).
   3. Void open invoices of those subscriptions: `invoices.list({ subscription: id, status: 'open' })` →
      `invoices.voidInvoice(inv.id)` (stops past-due retries).
   4. Detach saved cards: `paymentMethods.list({ customer, limit: 20 })` → `paymentMethods.detach(pm.id)`.
   5. `customers.update(customer, { metadata: { user_id: '', uncloud_account_deleted: nowISO } })`. The customer and
      its invoices stay in Stripe for tax records; the email on it stays (receipts need it). (Owner Q2.)
4. Delete the Supabase user: new `db.deleteUser(userId)` in `lib/supabase.js` →
   `DELETE {SUPABASE_URL}/auth/v1/admin/users/{id}` with the secret key headers the service mode already sends, body
   `{ "should_soft_delete": false }`. A 404 counts as success (retry after a partial failure). `on delete cascade`
   removes `customers` and `entitlements`; the user's refresh tokens die with the user.
5. `logEvent({ evt: 'account_delete', user: userId, result: 'deleted', subscriptions: n })`. Never the email.
6. `204`.

Restricted key: add **Invoices: write** and **PaymentMethods: write** to `STRIPE_SECRET_KEY`'s permissions
(`stripe-payments-plan.md` §4.2 list; orchestrator updates the key in the Dashboard, engineers don't).

### 4.3 Webhook and checkout after a deletion (changes in `lib/sync.js`)

- Subscription events for a deleted user: `resolveUser` finds metadata `user_id = ''`, no `customers` row and no hint
  → `no_user` → ignored, 200. Already true; add a test.
- Race (an event applied while the user is being deleted): `apply_subscription` fails on the foreign key
  (PostgREST 409 / code 23503). `applySubscription` catches a `DbError` with status 409 and returns `'ignored'`
  (logged `result: 'user_gone'`) instead of 500, so Stripe doesn't retry for 3 days.
- Checkout completed for a deleted user (paid in a browser tab after deleting): `syncCheckoutSession`'s `customers`
  upsert fails the same way → call the existing `cancelAndRefund(deps, subscriptionId)` and log
  `result: 'user_gone_refunded'`; return 200. They paid for an account that no longer exists, so they get the money back.
- `/v1/me` with a still-valid access token after deletion returns `free` (the RPC reads by `auth.uid()`); the app has
  already signed out locally, so it doesn't matter.

### 4.4 App side

- `AccountService`: `func deleteAccount(confirmEmail: String, tokens: AccountTokens) async throws`.
- `LiveAccountService`: `POST /v1/account/delete` with the bearer token, 204 → return; map `confirmation_mismatch` →
  `.confirmationMismatch`, others as today.
- `PreviewAccountService`: removes the account from its in-memory store; `slow@example.com` and `offline@example.com`
  behave as their other calls do.
- `AccountModel.deleteAccount(confirmEmail:)`: guard `mode != .off`, `.signedIn`, `!isExportRunning()`,
  `!isDeletingAccount`, and the local match (else `error = .confirmationMismatch`, return false). Calls through
  `authorized(_:)` (one token refresh + retry). Success → `forgetAccount()` (tokens, cache, account cleared),
  `notice = .accountDeleted`, `phase = .signedOut(.welcome)`, paywall/checkout settled, return true. `.signedOut`
  error → the usual revoke. Other errors → `error`, return false.
- `WelcomeView` shows the notice as one `.callout .secondary` line under the hero when set.

---

## 5. Change email: deferred

Supabase supports it (`PUT /auth/v1/user { email }` → codes to the new address, and with "secure email change" also to
the old one; then `POST /auth/v1/verify { type: "email_change", email, token }`). Deferred because:
- It needs a two-code flow (both addresses) and its own screens and errors.
- The Stripe customer email would go stale; the server would have to update it on the next `/v1/me` when the JWT
  email differs from the customer's, plus tests for that.
- The portal can't fix it either (`customer_update` allows only `address` today).

For now the Profile caption says "To change your email, contact support." with a `mailto:` link
(`AccountLinks.support`, placeholder `support@<domain>` behind a constant, as the other seller placeholders). Support
changes it in the Supabase dashboard and Stripe. Revisit after launch.

---

## 6. Accessibility and keyboard (every new view)

- Every control reachable with Tab when Full Keyboard Access is on; the popover's first focus is the primary action.
- Popover: header is one combined element "barishiz@gmail.com, Uncloud Plus, Renews on October 18, 2027".
- Badges: real text, not colour only. Warning lines carry their symbol and text.
- Dynamic Type isn't a macOS setting, but nothing truncates at the 460 pt width with the longest email in tests
  (`a.very.long.address.for.testing@example-domain.com`, middle truncation, full text in `.help`).
- Increase Contrast: badge fills use semantic colours, so they adapt.
- Keyboard: ⌘, Settings (system). Settings tabs: click or VoiceOver; no custom shortcuts. Delete sheet: Esc cancels,
  Return does nothing.

---

## 7. Tests

### 7.1 Swift unit (`UncloudTests`)

- **`AccountSummaryTests`** (new, pure): one test per rule in §3 at its boundaries (period end ± 1 s, grace end ± 1 s,
  past due with and without anchor, cancelAtPeriodEnd before/after end, `.canceled` before/after end, offline note at
  24 h ± 1 s, error not offline → no note), plus: initial from "barishiz@…" is "B", from "_x@…" is nil, from "9a@…" is
  "9"; `showsReceipts` false for `.none`; `showsRenewalToggle` false for Free and past due; `mode .off` → hidden even
  when signed in.
- **`AccountSummaryCopyTests`**: the status strings of §2.5 with `en_US` locale and UTC time zone (make
  `PlanText.date` take an optional `locale`/`timeZone` for tests, defaulting to current).
- **`AccountModelTests`** additions: deleteAccount happy path (tokens cleared, phase `.signedOut(.welcome)`,
  notice set, cached account gone); mismatch is refused locally without a service call; refused during an export;
  `.signedOut` from the server revokes; offline leaves the account signed in with `error == .offline`; a second call
  while one runs is ignored; notice clears on the next successful sign-in; `isConfirmingSignOut` round trip.
- **`LiveAccountServiceTests`** additions (MockURLProtocol): request path, method, bearer header and body; 204;
  400 `confirmation_mismatch` → `.confirmationMismatch`; 401 → `.signedOut`; 429 → `.rateLimited`.
  `verify`/`refresh` parse `user.created_at` (fractional seconds and without) into `UncloudAccount.createdAt`;
  missing → nil; a cached account without the field decodes.
- **`AccountMenuTests`** (pure helper `AccountMenuItems.make(summary:isExporting:)` used by `ExportCommands` and
  `MenuBarContent`): which items appear and their titles per state; Sign Out disabled while exporting; menu bar lines
  only for past due / offline grace; nothing for `off` and signed out.
- **`SettingsTabTests`**: `off` builds `GeneralSettingsForm` only (no `TabView`); raw value round trip.

### 7.2 Snapshots (`AccountSnapshotTests`, gated on `UNCLOUD_ACCOUNT_SNAPSHOTS`, light and dark, default accent)

New test `rendersAccountMenuAndSettings()`, using the existing `states()`/`signedIn(email:)` helpers and
`renderTitledWindow`:
- Popover (280 pt) in: Free, Free ended, Plus renewing, Plus ending, Past due, Offline grace, Plus with the
  "Last checked" note, long email.
- Account button alone (22 pt) in Free, Plus, needs-attention.
- Account tab (460 pt) in: loading, signed out, signed out after delete, Free, Free ended, Plus renewing, Plus ending,
  renewal saving, Past due, Offline grace, error banner, long email.
- General tab (unchanged content) in a signed-in build; Settings in `off` (must match the pre-change image).
- Delete sheet (420 pt): empty, matched, deleting, error; paid and never-paid variants.
- Main window sidebar with the account button (Free and Plus) at 1000 × 700 and 760 × 500.

### 7.3 Server (`server/uncloud-api/test/account-delete.test.js`, `node --test`, no network, fakes from `helpers.js`)

1. 401 without a token; 405 on GET.
2. 400 `bad_request` for a missing/odd body; 400 `confirmation_mismatch` for another email; case and surrounding
   spaces are ignored ("  Name@Example.com ").
3. No customer row → no Stripe calls → admin delete called with the user id → 204.
4. Active renewing subscription → metadata scrubbed, then cancel with `prorate: false` and idempotency key
   `delete-<subId>` (order asserted), cards detached, customer metadata scrubbed, user deleted → 204.
5. Past due with an open invoice → invoice voided.
6. Foreign-price subscription on the same customer is left alone.
7. Already-cancelled subscription → no cancel call.
8. Stripe cancel throws → 500, user **not** deleted; a retry succeeds and makes the same calls (idempotent).
9. Admin delete 404 → 204; admin delete 500 → 500 (Stripe side already done; retry → 204).
10. Rate limit: 6th call in an hour → 429 with `Retry-After`.
11. Logs contain no email and no token (capture `console.log`).
12. `sync.test.js` additions: subscription event with scrubbed metadata and no customer row → ignored 200;
    `apply_subscription` 409 → ignored 200 (`user_gone`); checkout completed with the customers upsert failing on the
    foreign key → `cancelAndRefund` called, 200.
13. `routes.test.js`: `/v1/account/delete` is routed; `permissions.test.js`: the new Stripe calls are in the
    restricted-key permission list.

---

## 8. Build chunks

Shared rules as `account-paywall-plan.md` §H and `stripe-payments-plan.md` §9: Swift 6 strict concurrency, macOS 14,
`#available(macOS 26, *)` with else branches, `xcodegen generate` after adding files, no change to
`Uncloud/Export/**` / `Uncloud/Helper/**` / export logic, no secrets, engineers don't call Stripe/Supabase/Vercel.

**Order.** **M2 (server)** has no overlap with N1 and can start now. **M1 (app)** starts **after N1 of
`export-new-only-plan.md` lands**. M1 codes against the contract in §4.1 with MockURLProtocol and the preview service,
so it doesn't wait for M2; the orchestrator deploys M2 and runs the live check (below) after both.

**Overlap with N1** (M1 must rebase on N1 and not touch N1's lines):
- `Uncloud/Views/MainWindow.swift` — N1 edits the Clean Up lock; M1 adds only the sidebar `.toolbar` item and the
  footer `.help` string.
- `Uncloud/Account/AccountTypes.swift` — N1 edits `lockedNote`; M1 adds `UncloudAccount.createdAt` and
  `AccountError.confirmationMismatch`.
- `UncloudTests/AccountSnapshotTests.swift` — N1 re-records "locks"; M1 adds a new test function.
- `UncloudTests/EntitlementGatingTests.swift` — M1 doesn't touch it (listed so nobody does).
- No overlap with ExportView, CleanupView, NewPhotos*, BackupHero, LockedFeatureView, ExportModel.

### Chunk M1 — App: account button, popover, menus, Account tab, Delete Account (Haiku; designer agent reviews the snapshots)

Owns:
- **new** `Uncloud/Account/AccountSummary.swift`, `Uncloud/Account/AccountMenuItems.swift`
- **new** `Uncloud/Views/Account/{AccountAvatar,AccountButton,AccountPopover,AccountSettingsForm,DeleteAccountSheet}.swift`
- **removed** `Uncloud/Views/Account/AccountSection.swift` (content moves to `AccountSettingsForm`)
- `Uncloud/Views/SettingsView.swift` (tabs; `GeneralSettingsForm` extracted, content unchanged)
- `Uncloud/Account/{AccountModel,AccountService,LiveAccountService,PreviewAccountService,AccountTypes,AccountLinks}.swift`
  (§3 additions, §4.4, `createdAt`, `confirmationMismatch`, `AccountLinks.support`)
- `Uncloud/Views/Account/{RootView,WelcomeView}.swift` (sign-out dialog host; deleted notice)
- `Uncloud/Views/Account/PaywallSheet.swift` (`PlanText.date` locale/timeZone parameters only)
- `Uncloud/Views/MainWindow.swift` (toolbar item + footer help only)
- `Uncloud/App/ExportCommands.swift` (`CommandGroup(after: .appSettings)` only)
- `Uncloud/Views/MenuBarContent.swift`, `Uncloud/App/UncloudApp.swift` (account environment for the menu bar extra only)
- tests: new `AccountSummaryTests`, `AccountSummaryCopyTests`, `AccountMenuTests`, `SettingsTabTests`; additions to
  `AccountModelTests`, `LiveAccountServiceTests`, `PreviewAccountServiceTests`, `AccountSnapshotTests`
  (new function only), `AccountTestSupport.swift` (fakes gain `deleteAccount`)
- `.claude/design/polish-plan.md` (§2 glossary rows from §1.5 only)

Acceptance:
1. Signed in (preview), the account button sits at the top of the sidebar on macOS 14 and 26 with the email initial;
   Plus shows the accent fill, past due/offline grace shows the warning dot; VoiceOver reads label and value as §1.1.
2. The popover shows email, badge, status line and the right primary action for every state in §3; each action does
   what §3 says and closes the popover; Sign Out of Uncloud… is disabled during an export.
3. Uncloud ▸ shows Account Settings…, the state's plan action and Sign Out of Uncloud… after Settings…; Account
   Settings… opens Settings on the Account tab whether Settings was closed or open on General.
4. Settings has General and Account tabs; General looks exactly as the old form minus the Account section. In
   `-UncloudAccountMode off` there are no tabs, no button, no menu items, no menu bar lines, and every existing
   snapshot matches its pre-change image.
5. The Account tab matches §2.2/§2.3 in every state with the §2.5 strings verbatim; Member since appears after a fresh
   sign-in or token refresh in live mode.
6. Delete Account…: the sheet's button stays disabled until the email is typed (case-insensitive); Return never
   deletes; in preview, deleting returns the main window to Welcome with "Your Uncloud account was deleted." and the
   tab shows the signed-out content; relaunch stays signed out; refused during an export.
7. The menu bar extra shows the past-due and offline lines only in those states.
8. The source footer still reads iCloud Photos / Photos on This Mac and the Apple Account; no account UI uses
   `icloud` or `applelogo` symbols; `git grep -n "Apple ID"` finds nothing new.
9. All listed tests pass; snapshots in §7.2 render light and dark without clipping.

### Chunk M2 — Server: delete account (Haiku)

Owns: **new** `server/uncloud-api/api/v1/account/delete.js`, **new** `server/uncloud-api/lib/account.js`,
`server/uncloud-api/lib/{handlers,supabase,sync,http}.js` (handler, `deleteUser`, the §4.3 changes, the
`confirmation_mismatch` code), **new** `server/uncloud-api/test/account-delete.test.js`, additions to
`test/{sync,routes,permissions,supabase}.test.js` and `test/helpers.js` (fake Stripe gains `subscriptions.list`,
`invoices.list/voidInvoice`, `paymentMethods.list/detach`, `customers.update`; fake DB gains `deleteUser`),
`server/README.md` (one line for the route), `stripe-payments-plan.md` §4.2 permission list (two rows).

Acceptance:
1. `cd server/uncloud-api && npm test` passes with no network; every case in §7.3 exists.
2. The route, codes, step order and idempotency keys match §4.1–4.3 exactly; no new dependency.
3. A failure at any step leaves later steps undone and a retry completes the deletion.
4. No email, token or key in logs; `git grep -nE 'sk_(test|live)_|rk_(test|live)_|whsec_|sb_secret_'` is empty.

**Orchestrator after M1 + M2:** add the two Stripe key permissions, `vercel deploy`, then in a live-mode Debug build:
sign up a test address → buy Plus (test card) → Account tab shows Renews on → Delete Account → Stripe test dashboard
shows the subscription cancelled, no card on the customer, metadata scrubbed; Supabase shows no user, no rows; the
webhook log shows the `customer.subscription.deleted` event ignored with 200.

---

## 9. Owner questions

1. **Refund on delete**: no automatic refund (recommended; the sheet says so, and the 14-day refund policy is by email
   before deleting), or refund the latest payment automatically when deleting within 14 days of it?
2. **Stripe customer on delete**: keep it with the user link scrubbed and cards removed (recommended; invoices and tax
   records keep their email), or delete the customer in Stripe as well?
3. **Change email**: OK to defer it and handle requests by email for now? If so, which **support address** should the
   "contact support" link use (placeholder until the domain is set)?
4. **Display name**: none is planned, since nothing would show it. Want one anyway?

---

## Orchestrator decisions (2026-10-19; owner may revise)

1. Delete Account does not refund automatically. Copy points to support for refund requests within 14 days.
2. Keep the Stripe customer with the user link removed (tax records).
3. Change of email is deferred. The support link uses the placeholder `SUPPORT_EMAIL` constant (one place, TODO).
4. No display name.
