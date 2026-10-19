# Uncloud Plus payments: security and correctness review

Branch `feature/duplicates-and-icloud-cleanup`, commits 0190708, cbc2d98, eb334f6, 387d7ad. Read-only review, 2026-10-18.
`npm test` in `server/uncloud-api`: 107 pass, 0 fail. (Several tests pass only because their fixtures use pre-2025 Stripe
object shapes; see H1.) The Stripe SDK pins API `2026-09-30.endive`, so the webhook endpoint uses that version too.

Severity: **High** means money moves wrongly or Plus is granted or revoked wrongly. **Medium** means a real defect
with a narrower trigger. **Low** means hardening.
**[T]** means it blocks the test-mode deploy or makes a §7.3 test-plan step fail. **[L]** means it must be fixed before launch.

---

## High

### H1 [T] A duplicate subscription is cancelled but never refunded
`server/uncloud-api/lib/sync.js:35-40` (`cancelAndRefund`)

The code reads `invoice.charge`. That field was removed from Invoice in API 2025-03-31 (basil). The pinned 2026-09-30
API never returns it (checked in `node_modules/stripe/esm/resources/Invoices.d.ts`: Invoice has only `payments?`). So
`chargeId` is always null and the function returns before it refunds anything.

**Scenario:** a user pays in two tabs (test step 12). The second subscription is cancelled, but the customer is charged
$9.99 twice and gets no refund. The tests miss this because `test/sync.test.js:130,154` use a fixture
`{ charge: 'ch_old' }` that the real API no longer returns.

**Fix:** find the payment through Invoice Payments. Call `stripe.invoicePayments.list({ invoice: invoiceId })` (or
retrieve the invoice with `expand: ['payments']`), take the paid entry's `payment.payment_intent`, and call
`stripe.refunds.create({ payment_intent, metadata: { uncloud_reason: 'duplicate', subscription: subscriptionId } }, { idempotencyKey })`.
Update the fixtures to the basil shape. Add "Invoices read" and "Refunds write" to the key (see M3).

### H2 [T] `charge.refunded` cancels the user's current subscription, whichever charge was refunded
`server/uncloud-api/lib/sync.js:147-164` (`handleRefund`)

The handler goes from customer to user to `entitlements.stripe_subscription_id` and cancels that subscription. It
never checks that the refunded charge paid for that subscription. In this API version, Charge has no `invoice` field
either.

**Scenarios:**
1. **Duplicate resolution, once H1 is fixed.** In the `duplicate_replaced` branch, the row is rewritten to the kept
   subscription B, and then the refund of A's charge arrives, so `handleRefund` cancels **B**. In the
   `duplicate_cancelled` branch, the row still holds the kept subscription, so `handleRefund` cancels it. Either way,
   resolving a duplicate leaves the user with no plan and only one of the two payments refunded.
2. **Older invoice.** The owner refunds last year's renewal invoice, or any other charge on the customer, from the
   Dashboard. The current year is cancelled.

**Fix:**
- Skip refunds that carry `metadata.uncloud_reason = duplicate`. The metadata is on `charge.refunds.data[]`, or
  retrieve the refund.
- Map the charge to its invoice with `stripe.invoicePayments.list({ payment: { type: 'payment_intent', payment_intent: charge.payment_intent } })`.
  Read the subscription with `subscriptionIdOf(invoice)`.
- Cancel only when that subscription equals the row's `stripe_subscription_id` and the invoice is that subscription's
  `latest_invoice`. Otherwise log `refund_other_invoice` and change nothing.

### H3 [L] The duplicate path refunds a subscription that has already ended
`server/uncloud-api/lib/sync.js:65-75` and `29-41`

"Existing is live" is decided from the database row only. `other` is fetched from Stripe, but its `status` is never
checked. `cancelAndRefund` skips the cancel when the subscription is already cancelled, but still refunds its latest
invoice.

**Scenario:** a one-year plan ends. Stripe cancels it, but the `customer.subscription.deleted` webhook is late or failed
(an outage, or a bad env var during a deploy), so the row still says `active`. `/v1/checkout` lets the user buy again,
because `toWire` (`entitlement.js:60`) reads the row as expired. When the new subscription syncs, the code finds two
"live" subscriptions and refunds the **old, fully used year**. Once H1 is fixed, this refund really happens.

**Fix:** treat it as a duplicate only if `other.status` is `active`, `trialing` or `past_due`. If `other` has ended,
re-sync it (`applySubscription(other)`) and then apply the new subscription normally. Refund only when the latest
invoice was paid within the last N days (for example 1), so a refund can never go back to an old period.

### H4 [T] A failed renewal keeps Plus for about a year, not 7 days
`Uncloud/Account/EntitlementPolicy.swift:33-37`, and the data from `server/uncloud-api/lib/entitlement.js:40-44`

When a renewal invoice fails, Stripe has already moved the subscription item's `current_period_end` to the **new**
period's end, and the status becomes `past_due`. The policy gives `pastDue` a grace that lasts until
`currentPeriodEnd + 7 d`, which is about 372 days.

**Scenarios:**
- Test step 8 ("`-UncloudClockOffsetDays 8` → Free") fails.
- In production, if the Stripe dunning setting is "leave the subscription past due" (it is account-level, and on
  PageReady.ca it is whatever that business chose), a failed card gets a free year.
- A user with a blocked network keeps Plus for the year in any case.

**Fix (server, so the app keeps one rule):** for `past_due`, compute when it became past due. Use the item's
`current_period_start`, or the latest invoice's `created` or `due_date`.
- Store and send that date as the grace anchor: either a new signed field `graceFrom`, or send `currentPeriodEnd` set
  to the period start while the status is `pastDue`.
- Map `past_due` older than 7 days to `expired` on the server.
- In the app, base `pastDue` grace on that anchor, never on the advanced period end.

---

## Medium

### M1 [L] The 30-day offline validity is never enforced, so a blocked network keeps Plus for the whole term
`Uncloud/Account/EntitlementPolicy.swift:26-38` (spec D.6 rule 3 has the same flaw)

Rule 2 is the only rule that checks `checkedAt + offlineValidity`. When it fails, rule 3 still returns
`.plusGrace(until: periodEnd + 7 d)` for any `active` plan, whatever `checkedAt` is.

**Scenario:** a user buys, asks for a refund (the server cancels the subscription), and blocks `uncloud-api.vercel.app`
with a firewall. They keep Plus until the old period end plus 7 days, up to a year. The same works for someone who
restores an old signed `uncloudEntitlement` from the same account. The signature binds the account, not freshness.

**Fix:**
- Allow rule 3 only when `now >= periodEnd`, which is the renewal-crossing case it was meant for.
- In every branch, require `now < checkedAt + offlineValidity`.
- After 30 days without a successful check, return `.free`, or a short "check needed" grace.

### M2 [T] The one-year flag is re-applied on every success-page load and on late webhooks
`server/uncloud-api/lib/sync.js:136-143`

Every call to `/v1/checkout/sync` with the session id re-runs `syncCheckoutSession`. This happens every time someone
reloads `/checkout/success?session_id=…`, the browser restores the tab, or the page is opened from history. The call
sets `cancel_at_period_end: true` whenever the subscription currently renews. Test step 6 can trip this.

**Scenarios:**
- **Within 24 h of checkout:** the user chose One Year, then turned renewal on in Settings. A reload sends the same
  idempotency key, so Stripe returns the **cached** response from the first call (`cancel_at_period_end: true`)
  without changing anything. `applySubscription` writes that stale value. The app now says "won't renew" while Stripe
  will charge next year.
- **After 24 h:** the key has expired, so the reload really turns renewal off again, without telling the user.
- **Late webhook:** a `checkout.session.completed` that arrives late can override a toggle the user made a few seconds
  earlier.

**Fix:**
- Apply the flag once per session. Put a marker in the same update call: `metadata[one_year_applied] = session.id` on
  the subscription. Skip the update if that marker is already set, or store applied session ids in the database.
- Always call `applySubscription` with a fresh `subscriptions.retrieve`, never the update's response, which can be a
  cached idempotent replay.

### M3 [T] The restricted-key permissions in plan §4.2 don't cover what the code calls
`.claude/design/stripe-payments-plan.md:389`, used by `server/scripts/RUNBOOK.md:40`

The plan lists "Charges read, Refunds read". The code calls `invoices.retrieve` (needs Invoices read) and
`refunds.create` (needs Refunds write). The fixes for H1 and H2 also need Invoice Payments read.

**Scenario (test step 12):** after the cancel, the next call fails with a permission error, and `applySubscription`
throws. The webhook returns 500, and Stripe retries for 3 days. The kept subscription is not recorded until the old
one's `deleted` event happens to arrive.

**Fix:** update the permission list: Invoices read, Invoice Payments read (if listed separately), Refunds write.

### M4 [T] A revoked session during an export removes the main window and the export controls
`Uncloud/App/UncloudApp.swift:37` and `Uncloud/Account/AccountModel.swift:121-140`

The convenience `AccountModel(configuration:)` never passes `isExportRunning`, so it stays `{ false }`. Nothing calls
`exportDidFinish()`. As a result `revokeSession()` is never deferred, and the model's sign-out guard is inactive. Only
the Settings button is disabled.

**Scenario:** a token refresh fails with `signedOut` while a long export runs. For example, the refresh token was
reused outside the 10 s window, or the session was revoked. `phase` becomes `.signedOut`, `RootView` swaps
`MainWindow` for Welcome, and `showsAppMenus` hides the Backup menu (Pause, Cancel Export). The export goes on with no
UI. The rule "never interrupt a running export" is broken in effect.

**Fix:** pass `isExportRunning: { model.isExporting || model.isEngineRunning }` when `UncloudApp.init` builds the
account. That means building the account after `model`, or adding a settable hook. Call `account.exportDidFinish()`
where the export ends (`ExportModel.swift:~927`, next to `storage.exportDidFinish()`).

### M5 [L] A missing or denied Keychain item signs the user out and drops Plus
`Uncloud/Account/AccountModel.swift:104-113`

`signedIn` requires the tokens from the Keychain. Spec A.5 says a failed Keychain load must keep the cached account
and the signed entitlement, and ask for sign-in only when a server call needs a token.

**Scenario:** an ad hoc-signed update triggers the "Uncloud wants to use your keychain" prompt. If the user denies it,
or it fails, Welcome appears, the Uncloud Plus features lock, and the reduced menus show, even offline.

**Fix:** treat cached account plus verified entitlement without tokens as signed in, with `tokens == nil`.
`authorized` then throws `.signedOut`. Route that to a "Sign in again" prompt rather than a full revocation.

### M6 [L] No rate limit on `/v1/checkout/sync` (no auth) or `/v1/checkout`
`server/uncloud-api/lib/handlers.js:76-93`

Any well-formed `cs_test_…` or `cs_live_…` id causes a Stripe `checkout.sessions.retrieve` call. A script can drain the
Stripe API rate limit, which is per account (today the PageReady.ca account), and that breaks checkout and webhooks.
The `rate_limited` error code exists but nothing returns it.

**Fix:**
- Add a per-IP limit with Vercel's firewall rules or a small Supabase counter.
- Optionally, look up the session in a local table (written by `/v1/checkout`) before calling Stripe.
- Cap `/v1/checkout` per user, and expire the user's earlier open sessions, which also reduces duplicates.

---

## Low

- **L1 [L] Grants rely on Supabase's default privileges.** `server/supabase/migrations/20261018120000_uncloud_plus.sql:44-45`.
  `customers` and `entitlements` keep TRUNCATE, REFERENCES and TRIGGER for `anon` and `authenticated`. TRUNCATE ignores
  RLS, although PostgREST can't issue it. If the project doesn't grant table access to API roles by default, `/v1/me`
  fails with "permission denied". **Fix:** `revoke all on public.customers, public.entitlements from anon, authenticated;`
  then `grant select … to authenticated;` and `grant select, insert, update, delete … to service_role;` (and the same
  for service_role on `stripe_events`).
- **L2 `cancel_at` is ignored.** `server/uncloud-api/lib/entitlement.js:45`. A Dashboard cancellation "on a date", or
  a flexible-billing `cancel_at`, leaves `cancel_at_period_end=false`, so the app says "Renews on …". **Fix:** treat
  `cancel_at != null && cancel_at <= periodEnd` as not renewing. In test, also check what the portal's "Cancel plan"
  sets on this API version.
- **L3 Token refresh bypasses the single-flight.** `Uncloud/Account/LiveAccountService.swift:100-102`.
  `currentEntitlement` refreshes inside the service, outside `AccountModel.sharedRefresh`. At launch with an
  unverifiable cache, `init`'s `refreshTask` and `RootView`'s `.task` can both spend the same refresh token. Outside the
  10 s reuse window, Supabase revokes the session, which leads to M4. **Fix:** have `refreshEntitlement` call
  `currentTokens()` first, and make the service never refresh by itself.
- **L4 Stale customer row.** `server/uncloud-api/lib/checkout.js:41-61`. If the Stripe customer was deleted (test-data
  cleanup), `/v1/checkout` returns 500 forever. If the email changes within 24 h, the same idempotency key comes with a
  different body: 400, then 500. **Fix:** on `resource_missing`, delete the row and create a new customer. Include a
  hash of the email in the idempotency key.
- **L5 Unknown `/v1/*` paths return the HTML 404 page.** A catch-all `api/v1/[...].js` could return the JSON envelope.
- **L6 The delete sheet stays open if Plus lapses.** `Uncloud/Views/CleanupView.swift:121-127`. If the plan lapses
  while the confirmation sheet is open, the sheet stays and Delete still works. **Fix:** check `allows(.cleanUpICloud)`
  in `onDelete`, or close the sheet when the plan locks.
- **L7 Dead code.** `ExportModel.isFeatureAllowed` (`ExportModel.swift:448`) is set but never read. Remove it, or use
  it at run start as C.4 intended.
- **Accepted risk:** the app is built from public source, so a local build with `off` (or a patched binary) unlocks
  everything. The signature only stops editing defaults, as designed.

---

## Checked and correct

- **Webhook raw body:** the functions use the Web `Request` signature (`export { handler as POST }`), so there is no
  body parser. `request.text()` is the raw body, and `constructEvent` runs before anything else (bad signature: 400).
  `event.livemode` is checked against the key mode. Event ids are recorded after a successful apply, so a failure gives
  500 and Stripe retries. Every path re-fetches the subscription (`syncSubscription`), so event order doesn't matter.
  Foreign prices from PageReady's own subscriptions are ignored. The `stale_ignored` guard stops an old subscription
  from overwriting the live one.
- **JWT:** `jose.jwtVerify` with the project JWKS, issuer `${SUPABASE_URL}/auth/v1`, audience `authenticated`,
  algorithms ES256 and RS256 only, plus `role`, a UUID `sub` and a non-empty `email` (which rejects anonymous users).
  Remember the manual step in `setup-supabase.sh`: the project must have asymmetric JWT keys, or every call returns 401.
- **Binding:** every authenticated route keys on the JWT `sub`. `/v1/me` reads through RLS with the caller's JWT.
  Portal and renewal look up the caller's own rows. `client_reference_id` and the metadata are set by the server. The
  sync endpoint with no auth only re-derives Stripe state for the user named in the session, after the price check. No
  route lets user A act on user B.
- **Signing:** the Ed25519 message format matches between `entitlement.js:74-84` and `EntitlementVerifier.swift:53-63`
  (both use whole-second ISO dates, and both encode the cache's dates exactly). The account id is inside the signed
  message. Unsigned or invalid entitlements are rejected live, and an invalid cache loads as Free. The client can't
  forge one without the private key. The weaknesses are freshness and grace (M1, H4), not the signature.
- **Release and Debug:**
  - Release is `off` in `project.yml`.
  - `make-dmg.sh` builds Release.
  - `preview` resolves to `off` outside DEBUG.
  - Overrides from defaults or launch arguments are compiled only under `#if DEBUG`.
  - A `live` configuration with values missing resolves to `off`.
  - The publishable key and public key are empty, so Release can't go live by accident.
- **App plumbing:** `uncloud://` links only trigger a refresh. Checkout and portal URLs must be https and exactly
  `checkout.stripe.com` or `billing.stripe.com`. The Keychain item is generic-password with
  `AfterFirstUnlockThisDeviceOnly`. Tokens are never put in defaults or logs.
- **Gating:**
  - Browse Backup is gated in the sidebar, the pane and View › Sort.
  - Verify, Duplicates and Free Up Space go through `require` in the Backup menu and the pane buttons.
  - ⌘⌫ (Delete from iCloud) is disabled through `isLibraryLocked`.
  - Library mode is locked, while Recently Deleted and Recover stay free.
  - Automatic backups (drive connect, daily), reminders, the menu bar extra and keep-running-after-close are gated.
  - Export, Recover, the New Photos count and export history stay free.
  - A Clean Up run that already started keeps going.
- **Secrets:**
  - No real keys in the diff `534d9e2..HEAD`; the test keys are marked FAKE.
  - `.env*` and `.vercel/` are gitignored.
  - The scripts move secrets file → pipe → `vercel env add --sensitive` and print only names (the publishable key is
    printed on purpose).
  - The test-mode guards work: balance `livemode=false`, `rk_test_` regex, health `livemode=false`.
  - Logs contain only event ids, user ids and result names.
- **Vercel:** `/v1/:path*` is rewritten to `/api/v1/:path*`, and the static pages come from `public/` with clean URLs.
  `no-store` is set on `/v1`, and Node is 22.x. `setup-vercel.sh`'s health check confirms the routing after the first
  deploy.
