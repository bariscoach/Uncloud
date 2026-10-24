# Remove payments; every feature needs only an Uncloud account (owner request, 2026-10-23)

Owner: "unlock paid features and remove payment integration - the only thing we will need would be signing up to the app"

Build automatically, then make the DMG. The owner granted publish autonomy for this work.

## Rule after the change

- Sign-up and sign-in (Supabase email code) stay exactly as they are. Signed in, **every feature is available**.
  Signed out, the app shows the welcome/sign-in screen as today.
- There is no plan, price, Plus, subscription, checkout, renewal, billing portal, paywall or lock anywhere.
- Delete Account stays.

## Part 1 — macOS app (`Uncloud/`)

1. **Gate.** `AccountModel.allows(_:)` returns true. Then remove the gating concept entirely:
   - `PaidFeature`, `require(_:_:)`, `paywall`, `checkout` state and `access` (free/plus/…).
   - Call sites call the action directly.
   - `MainWindow.showsCleanup` / the `LockedFeatureView` branches show the real pane.
   - `LockableSidebarRow` becomes a plain `Label`.
   - The `ExportModel` and `AutoBackupController` checks of `allows`.
   - The Browse, Cleanup, NewPhotos, BackupHero and BackupPane gates.

   `grep -rn "allows(\|require(\|PaidFeature\|paywall\|isLocked" Uncloud` must come back empty, except for unrelated
   uses.
2. **Remove these files:**
   - `PaywallSheet.swift`, `LockedFeatureView.swift`, `RenewalOptionRow.swift`, `FeatureRow.swift`, if it's only
     used by the paywall or welcome feature list. Check welcome first.
   - `EntitlementPolicy.swift`.
   - `EntitlementVerifier.swift`, **only if** nothing else needs it. See item 3.
3. **Service** (`AccountService`, `LiveAccountService`, `PreviewAccountService`):
   - Remove `checkoutURL`, `manageSubscriptionURL` and `setAutoRenew`, and the `Renewal` type.
   - `currentEntitlement` is how the app confirms the session with `/v1/me`. Keep a "confirm the account" call:
     either keep `/v1/me` and stop reading the plan fields, or rename it to `currentAccount` returning email/name.
   - If the signed entitlement / Ed25519 verification exists only to prove a plan, drop it and trust the session
     instead. Keep token refresh and sign-out.
4. **Account UI:**
   - `AccountFooter`, `AccountMenuItems`, `AccountSettingsForm`, `AccountSummary`, `AccountButton`,
     `MenuBarContent`, `ExportCommands` and `SettingsView`: remove the plan line, Upgrade/Subscribe/Manage
     Subscription/Renewal items, price text, "Plus" badges and the past-due/renewing/ending states.
   - The account area shows the avatar, name/email, Sign Out and Delete Account.
5. **Welcome and benefits** (`WelcomeView`, `BenefitsCarousel`, `GettingStartedView`, `LandingView`, and any copy with
   "Plus", "free", "$", "subscribe", "plan", "upgrade" or "Stripe"):
   - Reword to "Create your free Uncloud account to start."
   - Drop Free/Plus labels.
6. **`DeleteAccountSheet`:** remove any subscription/billing wording. Deleting just deletes the account.
7. **Config:** `UNCLOUD_ACCOUNT_MODE` (off/live) stays. It controls whether accounts are used at all.
8. **Tests:**
   - Delete the paywall, entitlement policy, renewal and checkout tests.
   - Update `AccountModelTests`, `AccountSummaryTests`, `EntitlementGatingTests` (delete it if it only tests gating),
     `AccountSnapshotTests` and `AccountFooterContentTests`.
   - Add a test that a signed-in free account can open Delete from iCloud, Browse Backup and automatic backups.
   - All tests pass. Run `xcodegen generate` after removing files.

## Part 2 — server (`server/uncloud-api/`)

1. **Remove these endpoints and their library code:**
   - `api/v1/checkout.js`, `api/v1/checkout/sync.js`, `api/v1/portal.js`, `api/v1/subscription/renewal.js`,
     `api/v1/stripe/webhook.js`.
   - `lib/checkout.js`, `lib/stripe.js`, `lib/stripe-shapes.js`, `lib/sync.js`.
   - The Stripe parts of `lib/entitlement.js`, `lib/handlers.js`, `lib/deps.js` and `lib/config.js`.
   - `public/checkout/*` and `public/account/return.html`, if it exists only for the billing portal, plus
     `public/assets/return.js` if unused.
   - The `stripe` dependency (`npm uninstall stripe`, which updates the lockfile).
2. **`/v1/me`:** returns the account (id, email, name) with no Stripe lookup. If the app still verifies a signed
   payload (Part 1.3), keep the signing but drop plan fields. Coordinate by reading the app's `LiveAccountService`.
   The Part 1 and Part 2 agents run separately, so the server agent must keep `/v1/me` **backward compatible**:
   - Keep returning what 0.1.22 reads, with the plan reported as `plus`/active forever (or the equivalent), so
     every build unlocks.
   - Don't break the response shape.
3. **`/v1/account/delete`:** remove the Stripe cancellation/cleanup. It deletes the Supabase user and rows only.
4. **`/v1/waitlist`, `/v1/health` and the catch-all:** unchanged.
5. **Tests:** delete `checkout`, `webhook` and Stripe-shape tests. Update `entitlement`, `config`, `routes`,
   `account-delete`, `sync` and `helpers`. `npm test` passes.
6. **`public/terms.html` and `public/privacy.html`:**
   - Remove payment, subscription, refund, Stripe and tax wording.
   - Uncloud is free. An account (email) is needed.
   - Keep the support email as is.
7. **Don't touch:** the Vercel env vars, the Supabase schema/migrations and the Stripe dashboard. Their leftovers are
   harmless. List them in the report so the owner can tidy up.

## Part 3 — website (`site/`)

- `index.html`:
  - Remove the "Simple Pricing" section, the Free/Plus badges, "$9.99", the "Is it really free?" Plus answer and any
    "Free Up Space", "Verify Backup" or "Find Duplicates" mentions. Those tools were removed in 0.1.22.
  - The feature list shows what the app does now:
    - Export from iCloud
    - Export Photos by Date
    - Automatic backups
    - Browse Backup by date/place/map
    - Delete from iCloud
  - Add one line: "Free. Create an account in the app to start."
- `styles.css`: remove the unused badge/pricing styles.
- `site/checks/site.test.mjs`: update. Its checks pass.
- Don't deploy. Opus deploys after review.

## Constraints

- **App:** Swift 6, XcodeGen. Run tests with `scratchpad/locked-test.sh` and read the results with
  `xcrun xcresulttool get test-results summary`.
- **Don't touch:** the running app, `~/Library/Containers/com.example.Uncloud`, `/Volumes` or the Keychain.
- **No secrets in the repo.** The repo is public.
- **No deploys and no DMG by agents.**
