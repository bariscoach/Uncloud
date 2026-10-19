# Uncloud Plus payments: Stripe + Supabase + Vercel plan

Status: plan only. No app code, no Stripe/Supabase/Vercel calls were made. Author: architecture (Opus), 2026-10-18.
Branch: `feature/duplicates-and-icloud-cleanup` (after b84eca8 "Export rename + account core").

This plan **replaces section E** (server sketch) and **the paywall part of chunk 3** of `account-paywall-plan.md`, and
absorbs the rest of that chunk 3 (locks, Settings › Account, gating). Everything else in that plan (A–C, D.2–D.6, F.1–F.4,
F.7, the owner decisions) still holds unless this file says otherwise. Chunk 2 there (Welcome / Sign Up / Sign In / Code)
is being built concurrently and is not touched here except where noted in §9.

---

## 0. Decisions at a glance

| Topic | Decision |
|---|---|
| Plan | **Uncloud Plus**, **$9.99 USD/year before tax**, no trial. Free = Export (+ the New Photos count and Clean Up iCloud › Recently Deleted/Recover). |
| Tax | Stripe Tax, `automatic_tax: enabled`, price `tax_behavior=exclusive`. App says "$9.99/year + tax". **Blocked for live until registrations + head-office address are set** (§2.5). |
| Renewal choice | **One recurring yearly subscription for both choices.** "One year, no auto-renewal" = the same subscription with `cancel_at_period_end=true`, set by the server right after checkout. Toggle anytime from Settings › Account or the Stripe portal (§1). |
| Auth | **Supabase Auth, email 6-digit OTP**, called **directly from the app** over REST (no SDK). The app holds only the public URL + publishable key. |
| API | Vercel Node functions, plain ESM JavaScript, deps `stripe` + `jose` only, base URL **`https://uncloud-api.vercel.app`** in one build setting (`UNCLOUD_API_BASE_URL`). |
| Source of truth | Postgres `public.entitlements`, written only by the server from Stripe data; the app reads it through `GET /v1/me`, which returns an **Ed25519-signed** entitlement. |
| Return from checkout | Stripe → `https://uncloud-api.vercel.app/checkout/success?session_id=…` → page syncs the session and opens `uncloud://checkout/success?session_id=…` (button fallback). |
| Repo layout | `server/uncloud-api/` (Vercel project root), `server/supabase/` (CLI workdir: config + migrations). Neither is inside `Uncloud/` or `UncloudTests/`, so XcodeGen and `make-dmg.sh` never see them. |
| Stripe account | Testing on the owner's existing **PageReady.ca** account, **test mode only**; setup is a re-runnable script keyed by lookup keys/IDs, re-run later on a separate **Uncloud** Stripe account before live. Account-level settings (branding, public details, emails) are **not** changed on PageReady.ca (§2.6). |
| Release builds | Stay `off` until go-live; then `live`. Debug can opt into `live` with a launch argument (§6.6). |

---

## 1. Renewal option: recommendation

**Recommended: (b) one subscription for both choices; "no auto-renewal" is `cancel_at_period_end = true`.**

| Concern | (a) Yearly subscription + separate one-time $9.99 price (365 days) | (b) One subscription; non-renewing = `cancel_at_period_end` |
|---|---|---|
| Turning auto-renew **on later** | One-time buyer has no subscription: needs a new Checkout with `trial_end = paid_until` to start billing at expiry, which Checkout shows as a **free trial** (owner said no trial; confusing). | Flip `cancel_at_period_end=false`. One API call, no card entry (card is already saved). |
| Turning it **off later** | Same as (b) for subscribers. | Flip to `true`. |
| Stripe customer portal | Portal can't manage one-time purchases; "Renew" doesn't exist for them. | Portal shows "Cancel plan" / "Renew plan" natively for the same object. |
| Renewal reminders | Only for subscribers; one-time expiry emails would be ours to build. | Stripe's upcoming-renewal email for renewing customers; nothing sent to non-renewing (correct). |
| Receipts / invoices | Two shapes (payment receipt vs invoice). | One shape: an invoice + receipt per year, invoice history in the portal. |
| Tax | Same either way. | Same. |
| Refunds | Two code paths (charge on a PaymentIntent vs on an invoice). | One path: refund → cancel subscription now → expired. |
| Entitlement expiry | Two sources to merge (subscription period vs purchase + 365 d; leap years, stacking a second purchase). | One: `current_period_end`; `customer.subscription.deleted` at the end. |
| Checkout wording | One-time page says "Pay $9.99". Clearer for non-renewers. | Page says "Subscribe" and "per year". **Mitigated** with `custom_text.submit` stating no renewal (§5.3). |
| Card stored | Not stored for one-time. | Stored by Stripe for every buyer (needed to turn renewal on later). Disclosed in the paywall caption. |

(b) wins on every lifecycle point; its only cost is Checkout's "Subscribe" wording, which custom text covers. Checkout
can't set `cancel_at_period_end` at creation (not a `subscription_data` field), so the server sets it in
`checkout.session.completed` (and in `/v1/checkout/sync`, whichever runs first; both idempotent) from session metadata
`renewal=oneYear`. The window where a non-renewing subscription reads as renewing is seconds and nothing is charged in it.

After a non-renewing plan ends, the subscription is `canceled` in Stripe; buying again is a fresh Checkout on the same
Stripe customer. Turning renewal on is possible any time **until** the period end.

---

## 2. Stripe

### 2.1 Objects (created by `server/scripts/setup-stripe.sh`, §8.2; re-runnable)

| Object | Identity used to find it again | Settings |
|---|---|---|
| Product | fixed ID **`uncloud_plus`** | name "Uncloud Plus", description "Automatic backups, reminders, Browse Backup, Find Duplicates, Verify Backup, Free Up Space and Clean Up iCloud for Uncloud on the Mac.", `tax_code` = SaaS/personal-use code (§2.5), `statement_descriptor` not set on PageReady (account-level descriptor is the business's; §2.6) |
| Price | lookup key **`uncloud_plus_yearly`** | `unit_amount=999`, `currency=usd`, `recurring[interval]=year`, `tax_behavior=exclusive`, `nickname="Uncloud Plus yearly"` |
| Customer portal configuration | `metadata[app]=uncloud` | §2.4 |
| Webhook endpoint | URL `https://uncloud-api.vercel.app/v1/stripe/webhook` | events in §4.6, `api_version` = the SDK's pinned version |

The server finds the price by lookup key (`prices.list({lookup_keys:['uncloud_plus_yearly'], active:true})`, cached per
instance). A price change = create a new price with the same lookup key and `transfer_lookup_key=true`; no deploy.

### 2.2 Checkout Session (created by `POST /v1/checkout`)

```js
stripe.checkout.sessions.create({
  mode: 'subscription',
  customer: stripeCustomerId,                       // created on first checkout, §4.4
  customer_update: { address: 'auto', name: 'auto' },// required for automatic_tax with an existing customer
  billing_address_collection: 'auto',
  line_items: [{ price: priceId, quantity: 1 }],
  automatic_tax: { enabled: true },
  client_reference_id: userId,
  metadata: { user_id: userId, renewal },           // renewal: 'automatic' | 'oneYear'
  subscription_data: { metadata: { user_id: userId } },
  success_url: `${PUBLIC_BASE_URL}/checkout/success?session_id={CHECKOUT_SESSION_ID}`,
  cancel_url: `${PUBLIC_BASE_URL}/checkout/cancelled`,
  allow_promotion_codes: false,
  locale: 'auto',
  custom_text: { submit: { message: renewal === 'automatic' ? RENEW_TEXT : ONE_YEAR_TEXT } },
  // consent_collection: { terms_of_service: 'required' }  // only once the Uncloud account has a Terms URL in Public details (§2.6)
})
```

Card, Apple Pay and Google Pay appear automatically on hosted Checkout; **no Apple Pay domain verification is needed for
hosted Checkout** (correcting the earlier plan). Dashboard: enable "Limit customers to one subscription"
(Settings › Checkout and Payment Links) on the Uncloud account as a second guard against double subscriptions.

### 2.3 API version gotcha (must handle)

Pin `new Stripe(key, { apiVersion: Stripe.API_VERSION })` (the SDK's own pinned version) and create the webhook endpoint
with the same `api_version`. On versions ≥ 2025-03-31 ("basil") **`current_period_end` lives on subscription items**
(`sub.items.data[0].current_period_end`) and the invoice's subscription is `invoice.parent.subscription_details.subscription`.
`lib/stripe-shapes.js` reads both new and old locations; tests cover both fixtures.

### 2.4 Customer portal configuration

```
business_profile[headline]            = "Manage your Uncloud Plus plan"
business_profile[privacy_policy_url]  = https://uncloud-api.vercel.app/privacy
business_profile[terms_of_service_url]= https://uncloud-api.vercel.app/terms
default_return_url                    = https://uncloud-api.vercel.app/account/return
features[subscription_cancel][enabled]=true, [mode]=at_period_end, [proration_behavior]=none
features[subscription_cancel][cancellation_reason][enabled]=true, [options][]=too_expensive,unused,missing_features,other
features[subscription_update][enabled]=false        # one price, nothing to switch to
features[payment_method_update][enabled]=true
features[invoice_history][enabled]=true
features[customer_update][enabled]=true, [allowed_updates][]=address   # not email: Supabase owns the email
metadata[app]=uncloud
```

The portal's "Cancel plan" is exactly "turn off auto-renew" (at period end), and its "Renew plan" turns it back on, so
the portal and the in-app toggle drive the same field and stay consistent through `customer.subscription.updated`.
The config ID goes into the Vercel env var `STRIPE_PORTAL_CONFIGURATION_ID`.

### 2.5 Tax (flag: blocks going live)

- Price `tax_behavior=exclusive`; Checkout `automatic_tax.enabled=true`; customers get an address via Checkout.
- Product tax code: pick the "Software as a service — personal use" code. Find the exact ID with
  `stripe get /v1/tax_codes --limit 100` and grep "Software as a service"; don't trust a remembered ID.
- **Before live, in the Uncloud account's dashboard (Tax › Settings / Registrations):** head-office (origin) address,
  default tax behavior "exclusive", and a **registration for each jurisdiction where the owner must collect**. Stripe Tax
  only charges tax where a registration exists; with none, it calculates 0 and says so in the dashboard.
- Owner must know: selling digital services to consumers in the **EU, UK, Canada (GST/HST) and other countries usually
  requires registering from the first sale** (no threshold for non-resident sellers in the EU/UK). Stripe Tax monitors
  thresholds but doesn't register for you. Alternative: a Merchant of Record (e.g. Stripe Managed Payments, Paddle) that
  takes on tax liability. See owner Q2.
- Cost per $9.99 sale (US card): ~2.9 % + 30¢ processing, +0.7 % Billing, +0.5 % Stripe Tax ≈ 66¢; international cards
  add ~1.5 %, currency conversion ~1 %.

### 2.6 Branding: what's API vs dashboard

On the **PageReady.ca** test account none of the account-level settings below are changed (they would rebrand
PageReady's own Checkout pages). Test Checkout will show PageReady's name/logo; that's expected. Set them on the
**Uncloud** account before live.

| Setting | Value | Where |
|---|---|---|
| Business / public name | "Uncloud" | Dashboard › Settings › Business › Public details (account-level) |
| Statement descriptor | `UNCLOUD` (7 chars; shortened descriptor `UNCLOUD`) | Dashboard › Public details (account-level). Not settable via API for your own account. |
| Support email / URL, Terms URL, Privacy URL | support address (owner Q5), `/terms`, `/privacy` | Dashboard › Public details. Terms URL there is required for `consent_collection.terms_of_service`. |
| Icon (square, ≥128 px) and logo | `Uncloud/Assets.xcassets/AppIcon.appiconset/icon_512x512.png` (icon); same for logo or a wordmark later | Dashboard › Settings › Branding |
| Accent colour (buttons, links) | `#1E6FD9` | Dashboard › Branding |
| Brand colour (Checkout background panel) | `#1E6FD9` per owner; calmer alternative `#FFFFFF` (owner Q6) | Dashboard › Branding |
| Font / shapes | System default font, "Rounded" | Dashboard › Branding |
| Per-session branding (`branding_settings` on Checkout Sessions: display name, colours, icon, logo) | Same values | **API**, newer API versions only. Verify it exists for the pinned version with the stripe-docs skill before using; if present, it lets test Checkout on PageReady show Uncloud branding. Optional. |
| Submit-button text, terms-acceptance text | §5.3 | **API**: `custom_text` per session |
| Portal headline, Terms/Privacy links, return URL | §2.4 | **API**: portal configuration |
| Customer emails: successful payments, refunds | On | Dashboard › Settings › Customer emails (account-level; **not** on PageReady) |
| Upcoming-renewal reminder | **30 days** before renewal (California-style auto-renewal laws want 15–45 days for yearly plans), link to the portal | Dashboard › Billing › Subscriptions and emails |
| Failed payment emails, expiring card emails, Smart Retries; "if all retries fail: **cancel the subscription**" | On | Dashboard › Billing › Revenue recovery |

---

## 3. Supabase

Project **`uncloud`**, ref `nkcbuwuuatsbskqcqosc`, URL `https://nkcbuwuuatsbskqcqosc.supabase.co`, region us-west-2,
free plan. DB password in `~/.uncloud-secrets/supabase-db-password` (never printed; passed as `SUPABASE_DB_PASSWORD`).

### 3.1 Auth settings (`server/supabase/config.toml`, pushed with `supabase config push`)

```toml
[auth]
site_url = "https://uncloud-api.vercel.app"
additional_redirect_urls = []
jwt_expiry = 3600
enable_refresh_token_rotation = true
refresh_token_reuse_interval = 10
enable_signup = true
enable_anonymous_sign_ins = false

[auth.email]
enable_signup = true
enable_confirmations = true      # OTP verification confirms the email
double_confirm_changes = true
secure_password_change = true
otp_length = 6
otp_expiry = 600                 # 10 minutes, matches the app's challenge
max_frequency = "60s"            # app's live resendAfter = 60 s (preview keeps 30 s)

[auth.email.template.confirmation]   # new users (create_user: true)
subject = "Your Uncloud code is {{ .Token }}"
content_path = "./supabase/templates/code.html"

[auth.email.template.magic_link]     # returning users
subject = "Your Uncloud code is {{ .Token }}"
content_path = "./supabase/templates/code.html"

[auth.rate_limit]
email_sent = 30                  # per hour, project-wide; only effective with custom SMTP
token_verifications = 30         # per 5 min per IP
token_refresh = 150              # per 5 min per IP
sign_in_sign_ups = 30            # per 5 min per IP

# [auth.email.smtp]  — later, with Resend behind the custom domain:
# enabled = true, host = "smtp.resend.com", port = 465, user = "resend",
# pass = "env(RESEND_API_KEY)", admin_email = "hello@<domain>", sender_name = "Uncloud"
```

Key names follow the Supabase CLI's `config.toml`; the chunk-1 engineer verifies them against the installed CLI
(`supabase --version`; `supabase config push --dry-run` if available) and adjusts names, not values.

Other settings:
- **JWT signing keys: asymmetric (ES256/RS256)**, so functions verify against JWKS without a shared secret. If the project
  is on the legacy HS256 secret, migrate in Dashboard › Project Settings › JWT Keys (one click; legacy tokens keep working
  through rotation). Flag for the runbook.
- **Built-in email (testing now):** Supabase's default SMTP only delivers to the project's team-member addresses and is
  limited to a few emails per hour. Test with the owner's own address only. **Public launch needs Resend + a custom
  domain** (verified SPF/DKIM), which also unlocks the `email_sent` limit.
- Keys: the **publishable key** (`sb_publishable_…`) is public and goes in the app's Info.plist; the **secret key**
  (`sb_secret_…`) only in Vercel env. The publishable key can trigger OTP emails, which the rate limits bound.
- Free plan pauses projects after ~7 days without activity, which would break sign-in: **Pro plan before launch** (owner Q3).

Code email (`server/supabase/templates/code.html`, final copy; inline CSS only, light background works in dark clients):

```
Subject: Your Uncloud code is {{ .Token }}

[Uncloud icon]
Your Uncloud code
{{ .Token }}                       (32 px, monospaced, letter-spacing 6px)
Enter this code in Uncloud to sign in. It expires in 10 minutes.
If you didn’t ask for a code, you can ignore this email. Nobody can sign in without it.
— Uncloud · Take Your Photos Home
```

The template must **not** include `{{ .ConfirmationURL }}`; with only `{{ .Token }}` Supabase sends a code, not a link.

### 3.2 Schema: `server/supabase/migrations/20261018120000_uncloud_plus.sql`

```sql
-- Stripe customer per Supabase user.
create table public.customers (
  user_id            uuid primary key references auth.users (id) on delete cascade,
  stripe_customer_id text not null unique,
  livemode           boolean not null,
  created_at         timestamptz not null default now()
);

-- One row per user: the plan as last derived from Stripe. Written only by the server (service role).
create table public.entitlements (
  user_id                uuid primary key references auth.users (id) on delete cascade,
  plan                   text not null default 'free'  check (plan in ('free', 'plus')),
  status                 text not null default 'none'
                         check (status in ('none', 'active', 'trialing', 'pastDue', 'canceled', 'expired')),
  current_period_end     timestamptz,
  cancel_at_period_end   boolean not null default false,
  stripe_subscription_id text unique,
  stripe_price_id        text,
  livemode               boolean not null default false,
  synced_at              timestamptz not null default now()
);

-- Webhook idempotency: an event id is recorded only after it was applied.
create table public.stripe_events (
  id           text primary key,
  type         text not null,
  livemode     boolean not null,
  created      timestamptz not null,
  processed_at timestamptz not null default now()
);

alter table public.customers     enable row level security;
alter table public.entitlements  enable row level security;
alter table public.stripe_events enable row level security;

-- Users can read their own rows; nobody but the service role writes.
create policy "read own customer"    on public.customers    for select to authenticated using ((select auth.uid()) = user_id);
create policy "read own entitlement" on public.entitlements for select to authenticated using ((select auth.uid()) = user_id);
-- stripe_events: no policies → no access for anon/authenticated.

revoke insert, update, delete on public.customers, public.entitlements from anon, authenticated;
revoke all on public.stripe_events from anon, authenticated;

-- What GET /v1/me reads, with the caller's JWT (RLS applies). Always one row for a signed-in user.
create or replace function public.my_entitlement()
returns table (plan text, status text, current_period_end timestamptz, cancel_at_period_end boolean)
language sql stable security invoker set search_path = ''
as $$
  select coalesce(e.plan, 'free'), coalesce(e.status, 'none'), e.current_period_end, coalesce(e.cancel_at_period_end, false)
  from (select (select auth.uid()) as uid) u
  left join public.entitlements e on e.user_id = u.uid
  where u.uid is not null;
$$;
revoke all on function public.my_entitlement() from public, anon;
grant execute on function public.my_entitlement() to authenticated;

-- The server's single write path (secret key / service_role only).
create or replace function public.apply_subscription(
  p_user_id uuid, p_subscription_id text, p_price_id text, p_plan text, p_status text,
  p_current_period_end timestamptz, p_cancel_at_period_end boolean, p_livemode boolean)
returns void language sql security definer set search_path = ''
as $$
  insert into public.entitlements as e (user_id, plan, status, current_period_end, cancel_at_period_end,
                                        stripe_subscription_id, stripe_price_id, livemode, synced_at)
  values (p_user_id, p_plan, p_status, p_current_period_end, p_cancel_at_period_end,
          p_subscription_id, p_price_id, p_livemode, now())
  on conflict (user_id) do update set
    plan = excluded.plan, status = excluded.status, current_period_end = excluded.current_period_end,
    cancel_at_period_end = excluded.cancel_at_period_end, stripe_subscription_id = excluded.stripe_subscription_id,
    stripe_price_id = excluded.stripe_price_id, livemode = excluded.livemode, synced_at = now();
$$;
revoke all on function public.apply_subscription(uuid, text, text, text, text, timestamptz, boolean, boolean) from public, anon, authenticated;
grant execute on function public.apply_subscription(uuid, text, text, text, text, timestamptz, boolean, boolean) to service_role;
```

Notes: `stripe_subscription_id unique` means a second subscription for the same user replaces the row only via
`apply_subscription` on the same user; the webhook detects a different active subscription and logs/cancels per §4.6.
Going live with the same Supabase project: `delete from customers where not livemode; delete from entitlements where not livemode; delete from stripe_events where not livemode;` (users keep their accounts).
Account deletion = deleting the auth user cascades both tables (Stripe customer kept for tax records).

---

## 4. Vercel API (`server/uncloud-api/`)

### 4.1 Layout

```
server/
  README.md                       # one screen: what lives here, how to run tests; links to this plan
  scripts/setup-stripe.sh         # §8.2
  scripts/setup-supabase.sh       # §8.3
  scripts/setup-vercel.sh         # §8.4
  supabase/config.toml
  supabase/templates/code.html
  supabase/migrations/20261018120000_uncloud_plus.sql
  uncloud-api/
    package.json                  # "type":"module", engines.node "22.x", deps: stripe, jose. scripts.test: "node --test"
    vercel.json
    .env.example                  # names only
    api/v1/health.js  me.js  checkout.js  portal.js
    api/v1/checkout/sync.js
    api/v1/subscription/renewal.js
    api/v1/stripe/webhook.js
    lib/config.js                 # reads env once; throws a clear error naming the missing var (never its value)
    lib/http.js                   # json(), error(code,status), readJSON(request) with 16 KB cap, method guard
    lib/auth.js                   # verifySupabaseJWT(request) via jose + JWKS
    lib/supabase.js               # PostgREST fetch helpers: rpc(name, args, {jwt}|{service:true}), select/insert
    lib/stripe.js                 # client, priceId() lookup cache, ensureCustomer()
    lib/stripe-shapes.js          # periodEnd(sub), subscriptionIdOf(invoice): new + old API shapes
    lib/entitlement.js            # mapSubscription(sub, now) → row; toWire(row, userId, now); sign()
    lib/sync.js                   # syncSubscription(subId), syncCheckoutSession(session): shared by webhook + sync route
    public/index.html  404.html  terms.html  privacy.html
    public/checkout/success.html  public/checkout/cancelled.html  public/account/return.html
    public/assets/site.css  public/assets/return.js  public/assets/icon.png
    test/*.test.js  test/fixtures/*.json
```

Handlers use the Web-standard signature (`export async function POST(request) { … }`), supported by Vercel's Node
runtime; `await request.text()` gives the raw body the webhook signature needs. Each handler is a thin wrapper around
`handle(request, deps)` so tests inject fake `stripe`, `db`, `verify`, `now`.

`vercel.json`:
```json
{
  "cleanUrls": true,
  "trailingSlash": false,
  "rewrites": [{ "source": "/v1/:path*", "destination": "/api/v1/:path*" }],
  "headers": [
    { "source": "/(.*)", "headers": [
      { "key": "Content-Security-Policy", "value": "default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'" },
      { "key": "X-Content-Type-Options", "value": "nosniff" },
      { "key": "Referrer-Policy", "value": "no-referrer" } ] },
    { "source": "/v1/(.*)", "headers": [{ "key": "Cache-Control", "value": "no-store" }] }
  ]
}
```

No CORS headers: the API is called by the app (not a browser), except `/v1/checkout/sync`, which is same-origin.
Deploy with the CLI (`vercel deploy --prod` from `server/uncloud-api`), **not** Git integration, so app commits never
trigger builds. Preview deployments are behind Vercel Deployment Protection, so the app always talks to production.

**Xcode / make-dmg check:** `project.yml` sources are `Uncloud` (minus Helper and Info.plists) and `UncloudTests`;
`make-dmg.sh` only runs `xcodegen` + `xcodebuild`. `server/` is outside both, so neither is affected. `.gitignore` gains
`node_modules/`, `.vercel/`, `.env`, `.env.*` (but not `.env.example`), `server/supabase/.temp/`.

### 4.2 Environment variables (Vercel, Production; names only)

| Name | Secret | Value |
|---|---|---|
| `STRIPE_SECRET_KEY` | yes | Test: a **restricted key** `rk_test_…` with: Checkout Sessions read and write, Customers write, Customer portal write, Prices read, Subscriptions read and write, Invoices read and write (account deletion voids open invoices), Invoice Payments read (if the key form lists it), Refunds read and write, Payment Methods read and write (account deletion detaches saved cards). Each call the server makes is listed in `server/uncloud-api/test/permissions.test.js`, and `server/scripts/RUNBOOK.md` carries the same list (review M3). Live later: `rk_live_…` on the Uncloud account. |
| `STRIPE_WEBHOOK_SECRET` | yes | `whsec_…` of the endpoint |
| `STRIPE_PORTAL_CONFIGURATION_ID` | no | `bpc_…` |
| `STRIPE_PRICE_LOOKUP_KEY` | no | `uncloud_plus_yearly` (default if unset) |
| `SUPABASE_URL` | no | `https://nkcbuwuuatsbskqcqosc.supabase.co` |
| `SUPABASE_PUBLISHABLE_KEY` | no | `sb_publishable_…` |
| `SUPABASE_SECRET_KEY` | yes | `sb_secret_…` |
| `ENTITLEMENT_SIGNING_KEY` | yes | Ed25519 private key, PKCS#8 DER, base64 |
| `PUBLIC_BASE_URL` | no | `https://uncloud-api.vercel.app` |

Startup guard: `lib/config.js` refuses (HTTP 503 `checkout_unavailable`) when `STRIPE_SECRET_KEY` mode (`_test_` vs
`_live_`) disagrees with an event's/object's `livemode`. Supabase side, later: `RESEND_API_KEY` (entered in the Supabase
dashboard or `supabase secrets`/config env, never in the repo).

### 4.3 Auth in functions

`verifySupabaseJWT(request)`:
- `Authorization: Bearer <access_token>` required, else 401 `unauthorized`.
- `jose.jwtVerify(token, createRemoteJWKSet(new URL(SUPABASE_URL + '/auth/v1/.well-known/jwks.json')), { issuer: SUPABASE_URL + '/auth/v1', audience: 'authenticated', algorithms: ['ES256','RS256'] })`; JWKS cached per instance (jose handles refresh).
- Require `payload.role === 'authenticated'`, `sub` is a UUID, `email` present. Returns `{ userId: sub, email, jwt }`.
- Any failure → 401 `unauthorized` (no detail in the message).

### 4.4 Routes and JSON

All JSON, UTF-8, dates **ISO 8601 UTC with whole seconds** (`2027-10-18T09:41:00Z`). Errors:
`{ "error": { "code": "<code>", "message": "<human text>" } }`.

| Code | HTTP | App `AccountError` |
|---|---|---|
| `unauthorized` | 401 | `.signedOut` (the model refreshes once and retries before revoking, §6.3) |
| `bad_request` | 400 | `.server(message:)` |
| `already_subscribed` | 409 | `.alreadySubscribed` (new) |
| `no_subscription` | 409 | `.noSubscription` (new) |
| `checkout_unavailable` | 503 | `.checkoutUnavailable` |
| `rate_limited` | 429 | `.rateLimited(retryAfter:)` from `Retry-After` |
| `server_error` | 500 | `.server(message:)` |
| `method_not_allowed` | 405 | `.server` |

**`GET /v1/health`** → `200 { "ok": true, "livemode": false }`. No auth.

**`GET /v1/me`** (auth) → reads `rpc/my_entitlement` **with the caller's JWT** + publishable key (RLS enforced), then
applies the read-time rule: `status=='active' && cancel_at_period_end && current_period_end <= now` → `expired`
(covers a late `subscription.deleted`).
```json
{
  "account": { "id": "8b1c…uuid", "email": "name@example.com" },
  "entitlement": {
    "plan": "plus", "status": "active",
    "currentPeriodEnd": "2027-10-18T09:41:00Z", "cancelAtPeriodEnd": false,
    "checkedAt": "2026-10-18T09:41:07Z",
    "signature": "base64-ed25519"
  }
}
```

**`POST /v1/checkout`** (auth) body `{ "renewal": "automatic" | "oneYear" }`
- 409 `already_subscribed` if the entitlement is `active`/`pastDue`/`trialing` and `current_period_end > now` (they use
  the renewal toggle instead).
- `ensureCustomer(userId, email)`: read `customers` (service key); else `stripe.customers.create({ email, metadata: { user_id } }, { idempotencyKey: 'customer-' + userId })` and insert the row.
- Creates the session (§2.2). → `200 { "url": "https://checkout.stripe.com/c/pay/cs_test_…", "sessionId": "cs_test_…" }`.

**`POST /v1/checkout/sync`** (no auth; called by the success page) body `{ "sessionId": "cs_…" }`
- Validates `^cs_(test|live)_[A-Za-z0-9]{10,200}$`; retrieves the session from Stripe (`expand: ['subscription']`);
  if `status=='complete'` and `mode=='subscription'` → `syncCheckoutSession(session)` → `204`. Otherwise `204` too (no
  information leak). Safe without auth: it only re-derives state from Stripe for the user in `client_reference_id`.

**`POST /v1/portal`** (auth) body `{}` → `stripe.billingPortal.sessions.create({ customer, configuration, return_url: PUBLIC_BASE_URL + '/account/return' })`
→ `200 { "url": "https://billing.stripe.com/p/session/…" }`; 409 `no_subscription` if no `customers` row.

**`POST /v1/subscription/renewal`** (auth) body `{ "autoRenew": true | false }`
- 409 `no_subscription` unless the row has a `stripe_subscription_id` and status ∈ {active, pastDue} and period end > now.
- `stripe.subscriptions.update(subId, { cancel_at_period_end: !autoRenew })` → `syncSubscription(subId)` →
  `200 { "entitlement": { …signed, as in /v1/me } }`.

**`POST /v1/stripe/webhook`** — §4.6. Responds `200 {"received":true}`; `400` on bad signature; `500` on processing
failure (Stripe retries for up to 3 days).

### 4.5 Mapping Stripe → entitlement (`lib/entitlement.js`, pure, table-tested)

| Stripe subscription status | `plan` | `status` | Notes |
|---|---|---|---|
| `active` | plus | `active` | `cancelAtPeriodEnd` = `sub.cancel_at_period_end` (true = "One year, no auto-renewal" or turned off) |
| `trialing` | plus | `trialing` | not expected (no trial) |
| `past_due` | plus | `pastDue` | app grace 7 days (EntitlementPolicy) |
| `unpaid`, `paused` | free | `expired` | |
| `canceled` | free | `expired` | includes refund-cancel and period-end cancel |
| `incomplete`, `incomplete_expired` | free | `none` | 3DS not finished |

`currentPeriodEnd` = `periodEnd(sub)` (§2.3). Price must be the `uncloud_plus_yearly` price; any other price → ignored
(logged), so PageReady.ca's own subscriptions on the shared test account never touch Uncloud rows.

**Signature (`sign()`)**, Ed25519 over the UTF-8 bytes of exactly:
```
uncloud-entitlement-v1\n<accountId>\n<plan>\n<status>\n<currentPeriodEnd or empty>\n<true|false>\n<checkedAt>
```
with dates in the whole-second ISO form above. Node: `crypto.sign(null, Buffer.from(msg), privateKey)`; Swift:
`Curve25519.Signing.PublicKey(rawRepresentation:).isValidSignature(_:for:)`. A shared fixture
`server/uncloud-api/test/fixtures/entitlement-vector.json` (fixed test key pair, message, signature) is copied into
`UncloudTests/Fixtures/` so both sides test the same bytes. Test key ≠ production key.

### 4.6 Webhook (`api/v1/stripe/webhook.js`)

1. `stripe.webhooks.constructEvent(rawBody, request.headers.get('stripe-signature'), STRIPE_WEBHOOK_SECRET)`; fail → 400.
2. `event.livemode` must match the key mode; else 200 and ignore (logged).
3. If `stripe_events` has `event.id` → 200 (already applied).
4. Handle:

| Event | Action |
|---|---|
| `checkout.session.completed` | If `mode=='subscription'` and the line price is ours: `syncCheckoutSession(session)`: upsert `customers` (user from `client_reference_id`, fallback `metadata.user_id`); if `metadata.renewal=='oneYear'` → `subscriptions.update(sub, {cancel_at_period_end:true}, {idempotencyKey:'one-year-'+session.id})`; then `syncSubscription(sub)`. |
| `customer.subscription.updated` | `syncSubscription(event.data.object.id)` |
| `customer.subscription.deleted` | `syncSubscription(id)` (→ expired) |
| `invoice.paid` | `syncSubscription(subscriptionIdOf(invoice))` (renewal moves the period end) |
| `invoice.payment_failed` | `syncSubscription(…)` (→ pastDue) |
| `charge.refunded` | If `charge.refunded === true` (full) and the customer is in `customers` with an active Uncloud subscription → `subscriptions.cancel(subId, {prorate:false}, {idempotencyKey:'refund-'+charge.id})` → `syncSubscription`. Partial refund → no plan change (logged). |
| anything else | 200, ignored |

5. Insert `stripe_events(id, type, livemode, created)`; return 200.

`syncSubscription(id)` **always re-fetches** the subscription from Stripe and writes the derived row, so duplicate,
retried and out-of-order events converge on Stripe's current state; idempotency of the side effects (cancel, one-year
flag) comes from Stripe idempotency keys and from the operations being naturally idempotent. User resolution for
subscription events: `sub.metadata.user_id`, else `customers.stripe_customer_id`. A second, different active Uncloud
subscription for the same user (two tabs) → keep the newer, cancel and refund the older's latest invoice payment, log;
"Limit customers to one subscription" makes this rare.

Logging: `console.log(JSON.stringify({ evt: type, id, user, result }))` — never tokens, emails or keys.

### 4.7 Hosted pages (plain HTML/CSS, light/dark, no frameworks)

`public/assets/site.css` tokens (matching the app: system font, calm neutrals, sky-blue accent, green only for success):
```css
:root { color-scheme: light dark;
  --bg:#F5F6F8; --card:#FFFFFF; --text:#1D1D1F; --secondary:#6E6E73; --hairline:rgba(0,0,0,.08);
  --accent:#1E6FD9; --accent-text:#FFFFFF; --success:#34C759; }
@media (prefers-color-scheme: dark) { :root {
  --bg:#161618; --card:#232326; --text:#F5F5F7; --secondary:#98989D; --hairline:rgba(255,255,255,.10);
  --accent:#4A8FEA; --accent-text:#FFFFFF; --success:#30D158; } }
body { margin:0; min-height:100vh; display:grid; place-items:center; background:var(--bg); color:var(--text);
  font:15px/1.5 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif; padding:24px 16px; }
.card { background:var(--card); border:1px solid var(--hairline); border-radius:16px; max-width:440px; width:100%;
  padding:40px 32px; text-align:center; box-shadow:0 1px 2px rgba(0,0,0,.04); }
.icon { width:64px; height:64px; border-radius:14px; }   h1 { font-size:24px; font-weight:600; margin:16px 0 8px; }
p { margin:0 0 12px; } .secondary { color:var(--secondary); font-size:13px; }
.button { display:inline-block; margin-top:16px; padding:10px 20px; border-radius:10px; background:var(--accent);
  color:var(--accent-text); text-decoration:none; font-weight:600; } .button:focus-visible { outline:3px solid var(--accent); outline-offset:3px; }
.legal { max-width:640px; text-align:left; } .legal h2 { font-size:17px; margin-top:24px; }
.placeholder { background:rgba(255,159,10,.12); border-radius:8px; padding:8px 12px; font-size:13px; }
```

`public/assets/return.js` (no inline scripts, CSP-clean): reads `data-app-url` from `<main>`; on the success page it
validates `session_id` (`^cs_(test|live)_[A-Za-z0-9]+$`), `fetch('/v1/checkout/sync', {method:'POST', …})` with a 4 s
timeout (ignore failures; the webhook covers it), builds `uncloud://checkout/success?session_id=<id>`, sets the button's
`href`, then `location.href = appURL` once. Other pages just open their `data-app-url`. Respects no-JS: the button still
works (success page's button falls back to `uncloud://checkout/success` without the id).

Final copy (curly apostrophes; title-case buttons, sentence-case text):

**`/checkout/success`** — `<title>You’re All Set — Uncloud</title>`
> [icon 64] [green check-seal SVG overlay]
> **You’re all set**
> Your payment went through and Uncloud Plus is on.
> Return to Uncloud to start using it.
> [ Return to Uncloud ]
> Uncloud didn’t open? Switch to it from the Dock. Your plan shows up within a minute.
> A receipt is on its way to your email.

**`/checkout/cancelled`** — auto-opens `uncloud://checkout/cancel`
> **Checkout cancelled**
> You haven’t been charged. You can get Uncloud Plus anytime from Uncloud.
> [ Return to Uncloud ]

**`/account/return`** (portal return) — auto-opens `uncloud://account/refresh`
> **Changes saved**
> Uncloud will show your updated plan in a moment.
> [ Return to Uncloud ]

**`/`** — no auto-open
> **Uncloud**
> Take Your Photos Home. Export full-quality originals from iCloud to your own drive.
> This address is Uncloud’s account service. To use Uncloud, open the app on your Mac.
> Terms of Use · Privacy Policy

**`/404`**: **Page not found** / "There’s nothing here. If you came from Uncloud, return to the app and try again." / [ Return to Uncloud ] (`uncloud://account/refresh`).

**`/terms`** (placeholder, `.legal`):
> [placeholder banner] Draft. These terms are a placeholder until the final version is published.
> **Terms of Use** · Last updated: <date>
> **The service.** Uncloud is a Mac app that exports your photos from iCloud to a drive you choose. Export is free. Uncloud Plus adds automatic backups, reminders, Browse Backup, Find Duplicates, Verify Backup, Free Up Space and Clean Up iCloud.
> **Price and tax.** Uncloud Plus costs $9.99 USD per year, plus any tax that applies where you live. Tax is shown before you pay.
> **Renewal.** If you choose to renew automatically, your plan renews every year at the then-current price, and we remind you by email before it does. You can turn renewal off anytime in Uncloud › Settings › Account or in the billing portal; your plan then runs to the end of the year you paid for. If you choose one year with no auto-renewal, you won’t be charged again unless you turn renewal on.
> **Refunds.** <owner Q4: e.g. "If you’re not happy, email us within 14 days of a charge for a full refund.">
> **Your photos.** Your photos go straight from Apple to your drive. They never pass through Uncloud’s servers. You’re responsible for keeping your backup drive safe.
> **Deleting from iCloud.** Clean Up iCloud deletes photos from your iCloud library only when you confirm. Recently Deleted keeps them for up to 30 days.
> **No warranty.** Uncloud is provided as is. To the extent the law allows, we aren’t liable for lost data or indirect damages.
> **Contact.** <support email> · Seller: <legal name, country>

**`/privacy`** (placeholder):
> [placeholder banner]
> **Privacy Policy** · Last updated: <date>
> **What we store.** Your email address, a Stripe customer ID, and your plan’s status and renewal date. Nothing else.
> **What we never see.** Your photos, your Apple ID password and your iCloud data. Photos go straight from Apple to your drive.
> **Who processes it.** Supabase (account sign-in and the plan database), Stripe (payments, receipts and tax), Vercel (hosting this service) and, later, Resend (sending sign-in codes). Card details go to Stripe only.
> **Emails.** We send sign-in codes and, through Stripe, receipts and renewal reminders. No marketing.
> **Deleting your account.** Email <support email> and we delete your account and plan record. Stripe keeps payment records as tax law requires.
> **Contact.** <support email>

---

## 5. The app: paywall, Settings › Account, locks

Visual language as `account-paywall-plan.md` §F and `polish-plan.md` (one primary button, colour = status, `Tokens.*`).

### 5.1 PlanCopy (extend `AccountTypes.swift`)

```swift
enum PlanCopy {
    static let price = "$9.99"
    static let yearlyPrice = "\(price)/year"                 // "$9.99/year"
    static let yearlyPricePlusTax = "\(price)/year + tax"    // paywall, locked panes
    static let welcomePlanLine = "Export is free. Everything else is Uncloud Plus, \(yearlyPrice)."
}
enum Renewal: String, Codable, Sendable, CaseIterable { case automatic, oneYear }   // wire values
```

### 5.2 Paywall sheet (`Uncloud/Views/Account/PaywallSheet.swift`), width 460

```
   [ App icon 64 ]
   Get Uncloud Plus                                              .title2 semibold, header
   Browse Backup is part of Uncloud Plus.                        .callout secondary (only when opened by a feature)
   Keep your backup safe, tidy and up to date, on its own.       .body
   ───────────────────────────────────────────────
   ◉ Automatic Backups   ◉ Reminders                             2 columns: symbol (accent) + title, .callout;
   ◉ Browse Backup       ◉ Find Duplicates                       the opening feature in .semibold
   ◉ Verify Backup       ◉ Free Up Space
   ◉ Clean Up iCloud
   ───────────────────────────────────────────────
   ┌─────────────────────────────────────────────┐
   │ (●) Renew automatically every year   $9.99/year + tax │   selectable row (radio)
   │     Turn renewal off anytime in Settings.             │   .caption secondary
   └─────────────────────────────────────────────┘
   ┌─────────────────────────────────────────────┐
   │ ( ) One year, no auto-renewal        $9.99 + tax │
   │     Uncloud Plus ends after a year unless you renew. │
   └─────────────────────────────────────────────┘
   Pay with card, Apple Pay or Google Pay on Stripe’s secure checkout page. Tax is added at checkout.   .caption secondary
   ───────────────────────────────────────────────
   Already Subscribed? Refresh             [ Not Now ] [ Continue to Checkout ]
```

- Renewal rows: a custom two-row radio group (`RenewalOptionRow`), each a full-width button with `Radius.m` border
  (`Tokens` hairline; selected = accent border 1.5 pt + accent 0.06 fill), leading `circle`/`largecircle.fill.circle`
  in accent, title `.headline`, price trailing `.body.monospacedDigit()`, caption below. Arrow keys / Tab + Space select.
  Accessibility: `.accessibilityElement(children: .combine)`, `.isButton`, `.isSelected` trait on the chosen one; label
  "Renew automatically every year, $9.99 a year plus tax".
- Default selection: **Renew automatically** (owner Q1). The choice is remembered in `@AppStorage("uncloudPaywallRenewal")`.
- "Reminders" replaces "New Photos" in the paywall list and in `PaidFeature.newPhotos.title` for the paywall context
  (owner decision: the count is free, reminders are paid). `PaidFeature.newPhotos` keeps its raw value; add
  `paywallTitle` = "Reminders", summary "Lets you know when new photos are waiting to be backed up."
- Primary **Continue to Checkout** (`.borderedProminent`, `.defaultAction`) → `account.openCheckout(for:renewal:)`.
- States (from `AccountModel.checkout`): `opening` "Opening Checkout…" spinner; `waiting` → price/renewal block replaced
  by `arrow.up.forward.app` + "Finish checking out in your browser, then come back here." with **Not Now**,
  **Open Checkout Again** (bordered), **Check Again** (prominent, default); `waiting(processing: true)` adds
  "Payment is still processing. This can take a minute."; `active` → `checkmark.seal.fill` 44 pt success + "You’re all set"
  + one of: "Uncloud Plus is on and renews on October 18, 2027." / "Uncloud Plus is on until October 18, 2027." +
  **Continue**; `failed(e)` → inline banner with `e.message` above the footer.
- Refresh found no plan: "We couldn’t find a plan for name@example.com." under the link.

### 5.3 Checkout custom text (server constants, final copy)

- `RENEW_TEXT`: "Uncloud Plus renews every year at $9.99 plus tax. We’ll email you before it renews. Turn renewal off anytime in Uncloud › Settings › Account."
- `ONE_YEAR_TEXT`: "One year of Uncloud Plus. It won’t renew and you won’t be charged again unless you turn renewal on in Uncloud. Stripe keeps your card only for that."

(Checkout limits `custom_text.submit.message` to 1200 characters; both are well under.)

### 5.4 Settings › Account (`Uncloud/Views/Account/AccountSection.swift`), first section of `SettingsView`

| State | Rows |
|---|---|
| Signed out | "Not signed in" (secondary) · **Sign In…** |
| Free (never paid) | Email · Plan "Free" · **Get Uncloud Plus…** (bordered) · "Already Subscribed? Refresh" (link) |
| Free (plan ended) | Email · Plan "Free" · caption "Your Uncloud Plus plan ended on October 18, 2027." · **Get Uncloud Plus…** · Refresh |
| Plus, renewing | Email · Plan "Uncloud Plus" · `Toggle("Renew automatically", isOn:)` **on** · caption "Renews on October 18, 2027 for $9.99 plus tax." · **Manage Subscription…** |
| Plus, not renewing | Toggle **off** · caption "Uncloud Plus ends on October 18, 2027. Turn on renewal to keep it." · **Manage Subscription…** |
| Toggle in flight | Small `ProgressView` trailing the toggle, toggle disabled; on failure it springs back and the caption shows `error.message` in `Tokens.Status.danger` with `exclamationmark.triangle` |
| Grace (offline) | `wifi.slash` caption "Couldn’t check your plan. Uncloud Plus stays on until October 25 while you’re offline." · Refresh |
| Grace (past due) | `exclamationmark.triangle` (warning) "Your last payment didn’t go through. Update your card by October 25 to keep Uncloud Plus." · **Manage Subscription…** (toggle hidden) |
| Always, signed in | "Plan checked today at 9:41." · **Sign Out…** · footer links "Terms of Use · Privacy Policy" (`AccountLinks.terms/privacy`) |

- **Manage Subscription…** opens the portal (card, address, invoices/receipts, cancel/renew). After it, the app
  refreshes on `uncloud://account/refresh` **and** on the next `didBecomeActive` (`AccountModel.awaitingPortalReturn`).
- Turning renewal **off** needs no confirmation (reversible until the end date); turning **on** shows no dialog either:
  the caption states the date and price. Both call `account.setAutoRenew(_:)`.
- Sign Out as in the earlier plan F.6. Preview-mode Debug section gains **Turn Renewal Off/On** buttons (they just use the
  preview service).

### 5.5 Locks and gating (absorbs earlier chunk 3, with the owner decisions)

As `account-paywall-plan.md` §C.3/C.4, with these changes:
- **New Photos count, badge and hero line are free.** `.newPhotos` gates **reminder notifications only**:
  `AutoBackupController.checkForNewPhotos` checks it before posting; the Settings reminder toggle is locked. Drop
  `visibleNewPhotosStatus` gating of the badge/hero (keep the property returning the status unfiltered, or remove it).
- **Clean Up iCloud pane is unlocked** (no sidebar lock). Its **Recently Deleted** mode (and Recover) is free; the
  **Library** (delete) mode shows `LockedFeatureView(feature: .cleanUpICloud)` and opens the paywall when chosen; the
  segment shows a small `lock` symbol. Edit › Delete from iCloud… stays disabled when locked.
- Browse Backup: sidebar lock + locked view + paywall as before.
- Locked view description: "\(feature.summary) It’s part of Uncloud Plus, \(PlanCopy.yearlyPricePlusTax)."
- Never interrupt running work (unchanged).

---

## 6. The app: `LiveAccountService` and configuration

### 6.1 Protocol changes (`AccountService.swift`)

```swift
protocol AccountService: Sendable {
    func requestCode(email: String, intent: AuthIntent) async throws -> AuthChallenge
    func verify(challenge: AuthChallenge, code: String) async throws -> AuthSession
    func currentEntitlement(tokens: AccountTokens) async throws -> (Entitlement, AccountTokens)
    func refresh(tokens: AccountTokens) async throws -> AccountTokens
    func signOut(tokens: AccountTokens) async
    func checkoutURL(tokens: AccountTokens, renewal: Renewal) async throws -> URL          // + renewal
    func manageSubscriptionURL(tokens: AccountTokens) async throws -> URL
    func setAutoRenew(_ autoRenew: Bool, tokens: AccountTokens) async throws -> Entitlement // new
}
```

`AccountError` gains `.alreadySubscribed` ("You already have Uncloud Plus.") and `.noSubscription`
("There’s no plan to change. Get Uncloud Plus to start one."). `Entitlement` gains `signature: String?`
(optional, decodes missing as nil; preview leaves it nil). `PreviewAccountService` implements the new calls
(`oneYear` → `cancelAtPeriodEnd = true`; `setAutoRenew` flips it; error when no Plus).

### 6.2 Endpoints `LiveAccountService` calls

`actor LiveAccountService: AccountService`, `init(configuration: LiveConfiguration, session: URLSession = .uncloud, verifier: EntitlementVerifier, now: @Sendable () -> Date)`.
`URLSession.uncloud`: `.ephemeral` config, `timeoutIntervalForRequest = 15`, no cookies/cache, `waitsForConnectivity = false`,
header `User-Agent: Uncloud/<version> (macOS <ver>)`. Supabase calls send `apikey: <publishable key>`.

| Method | HTTP | Body / headers | Success → |
|---|---|---|---|
| `requestCode` | `POST {supabase}/auth/v1/otp` | `{"email": e, "create_user": true}` | `AuthChallenge(id: UUID, email: e, expiresAt: now+600, resendAfter: now+60)` |
| `verify` | `POST {supabase}/auth/v1/verify` | `{"type":"email","email": e,"token": code}` | session JSON → tokens (`access_token`, `refresh_token`, `expires_at` epoch s) + `user.id`/`user.email`; then `GET {api}/v1/me` for the entitlement (offline → `.free` with `checkedAt = .distantPast`, sign-in still succeeds). `isNewAccount` = `abs(user.email_confirmed_at − user.last_sign_in_at) < 60 s` (only drives the welcome announcement). |
| `refresh` | `POST {supabase}/auth/v1/token?grant_type=refresh_token` | `{"refresh_token": r}` | new tokens (rotated) |
| `signOut` | `POST {supabase}/auth/v1/logout?scope=local` | `Authorization: Bearer access` | ignore result |
| `currentEntitlement` | refresh first if `accessExpiresAt < now + 60`; `GET {api}/v1/me` | Bearer | `(verified entitlement, tokens)` |
| `checkoutURL` | `POST {api}/v1/checkout` | `{"renewal": "automatic"|"oneYear"}` | `url` (must be https on `checkout.stripe.com`) |
| `manageSubscriptionURL` | `POST {api}/v1/portal` | `{}` | `url` (https on `billing.stripe.com`) |
| `setAutoRenew` | `POST {api}/v1/subscription/renewal` | `{"autoRenew": b}` | verified entitlement |

Error mapping:

| Response | `AccountError` |
|---|---|
| `URLError` `.notConnectedToInternet`, `.networkConnectionLost`, `.timedOut`, `.cannotFindHost`, `.cannotConnectToHost`, `.dnsLookupFailed` | `.offline` |
| `URLError.cancelled` / `CancellationError` | rethrow `CancellationError` |
| Supabase `/otp` 429 (`over_email_send_rate_limit`) | `.rateLimited(retryAfter:)` (parse "after N seconds" in `msg`, else now+60) |
| Supabase `/otp` 400/422 `validation_failed` / `email_address_invalid` | `.invalidEmail` |
| Supabase `/verify` 401/403 `otp_expired` | `.codeExpired` if `now ≥ challenge.expiresAt`, else `.wrongCode`; a local per-challenge counter turns the 5th wrong code into `.tooManyAttempts` |
| Supabase `/verify` 429 | `.tooManyAttempts` |
| Supabase `/token` 400 `refresh_token_not_found` / `refresh_token_already_used` / `session_not_found`, or 401 | `.signedOut` |
| API error codes | §4.4 table |
| any other 5xx, undecodable JSON | `.server(message: nil)` |
| entitlement signature invalid | `.server(message: "Unverified plan")` (cache untouched) |

### 6.3 Token handling in `AccountModel`

- Refresh tokens rotate (single use, 10 s reuse window), so a refreshed pair must always be saved. `AccountModel`
  gains `private func authorized<T>(_ call: (AccountTokens) async throws -> T) async throws -> T`: proactively refreshes
  when `accessExpiresAt < now + 60` (single-flight: one shared `Task<AccountTokens, Error>` so concurrent calls don't
  burn the refresh token twice), saves to the store, calls; on `.signedOut` refreshes once and retries; a second
  `.signedOut` → `revokeSession()` (deferred while exporting, as today). `openCheckout`, `openManageSubscription`,
  `setAutoRenew` use it; `currentEntitlement` already returns tokens and keeps its path.
- `openCheckout(for:renewal:)`: `.alreadySubscribed` → force refresh → `settleCheckout()` (paywall shows active).
- `setAutoRenew(_:)`: `renewalChangeInFlight` flag for the toggle spinner; on success replace `entitlement` + cache; on
  error set `error` and keep the old entitlement (the toggle springs back since it binds to `!entitlement.cancelAtPeriodEnd`).
- While `checkout == .waiting(processing: true)`, poll `refreshEntitlement(force: true)` at 2, 5, 10, 20 and 40 s, then
  stop (the user can press Check Again). On `didBecomeActive` while `waiting`, one forced refresh (as planned in D.1).

**Keychain:** `KeychainAccountTokenStore` (already built) in `live`. Caveat stands: ad hoc signatures change every build,
so macOS may prompt or deny after an update → `load()` nil → the cached signed entitlement keeps working offline and
the user signs in again only when a server call needs a token. Tokens never go to logs, UserDefaults or Activity.

### 6.4 Signed entitlement in the app

`struct EntitlementVerifier: Sendable { let publicKey: Curve25519.Signing.PublicKey?; func isValid(_ e: Entitlement, accountID: String) -> Bool }`
(new file `Uncloud/Account/EntitlementVerifier.swift`; builds the §4.5 message with `ISO8601DateFormatter` `[.withInternetDateTime]`).
- `LiveAccountService` rejects unsigned/invalid entitlements from the server.
- `AccountModel.init` gains `verifyCachedEntitlement: (Entitlement, String) -> Bool` (default `{ _, _ in true }` for
  preview/off); in `live` an invalid cached entitlement loads as `.free` and a forced refresh is scheduled.
- `EntitlementPolicy` change: `active` with `cancelAtPeriodEnd == true` and `now ≥ currentPeriodEnd` → `.free`, **no grace**
  (a non-renewing plan simply ends). Renewing `active` past the end keeps the 7-day grace (offline over a renewal).

### 6.5 `AccountConfiguration` and links

```swift
struct AccountConfiguration {
    let mode: AccountMode
    let apiBaseURL: URL?                // UncloudAPIBaseURL — the one constant for the Vercel base
    let supabaseURL: URL?               // UncloudSupabaseURL
    let supabasePublishableKey: String? // UncloudSupabasePublishableKey (public)
    let entitlementPublicKey: String?   // UncloudEntitlementPublicKey, base64 of 32 raw bytes (public)
}
enum AccountLinks {   // derived from apiBaseURL; preview → the GitHub README
    static func terms(_ c: AccountConfiguration) -> URL    // {base}/terms
    static func privacy(_ c: AccountConfiguration) -> URL  // {base}/privacy
}
```
`resolve` for `live` requires all four, both URLs https with a host, and a 32-byte key; otherwise `off` (logged), never a
lockout. The convenience `AccountModel(configuration:)` builds `LiveAccountService` + `KeychainAccountTokenStore` for
`live`. Debug launch arguments accept `-UncloudAccountMode live` and `-UncloudAPIBaseURL https://…` (Debug only).
Debug-only `-UncloudClockOffsetDays N` shifts `AccountModel`'s clock for manual grace/expiry checks.

### 6.6 project.yml

```yaml
info.properties:
  UncloudAccountMode: $(UNCLOUD_ACCOUNT_MODE)
  UncloudAPIBaseURL: $(UNCLOUD_API_BASE_URL)
  UncloudSupabaseURL: $(UNCLOUD_SUPABASE_URL)
  UncloudSupabasePublishableKey: $(UNCLOUD_SUPABASE_PUBLISHABLE_KEY)
  UncloudEntitlementPublicKey: $(UNCLOUD_ENTITLEMENT_PUBLIC_KEY)
settings.base:
  UNCLOUD_API_BASE_URL: "https://uncloud-api.vercel.app"
  UNCLOUD_SUPABASE_URL: "https://nkcbuwuuatsbskqcqosc.supabase.co"
  UNCLOUD_SUPABASE_PUBLISHABLE_KEY: "sb_publishable_…"     # public by design
  UNCLOUD_ENTITLEMENT_PUBLIC_KEY: "<base64 32 bytes>"     # public half of ENTITLEMENT_SIGNING_KEY
configs:
  Debug:   { UNCLOUD_ACCOUNT_MODE: "preview" }            # -UncloudAccountMode live to hit the test server
  Release: { UNCLOUD_ACCOUNT_MODE: "off" }                # flip to "live" at go-live (§8.6), one line
```
These live in `project.yml` (written into the pbxproj), not an `.xcconfig`, where `//` in `https://` would start a comment.
The test host keeps `preview` and no URL types.

---

## 7. Test plan

### 7.1 Node (`server/uncloud-api/test`, `node --test`, no network)

- `entitlement.test.js`: §4.5 table row by row; basil vs legacy period-end shapes; foreign price ignored; read-time
  expiry rule; signature matches `fixtures/entitlement-vector.json`; whole-second ISO formatting.
- `auth.test.js`: missing header, malformed, wrong issuer/audience, expired, `role != authenticated` → 401; valid token
  (signed with a local ES256 key served by a fake JWKS fetcher) → user.
- `checkout.test.js`: creates the customer once (idempotency key), session params incl. `automatic_tax`,
  `customer_update`, metadata `renewal`, the right custom text per choice, success/cancel URLs; 409 when active;
  503 when the price lookup fails.
- `sync.test.js`: complete session → customers upsert + `apply_subscription`; `oneYear` → `subscriptions.update(cancel_at_period_end:true)` with key `one-year-<cs>`; incomplete session → no writes; bad id → 204, no Stripe call.
- `webhook.test.js` (signatures via `stripe.webhooks.generateTestHeaderString`): bad signature 400; each event type
  routes to the right action; the same event twice → applied once; out-of-order `updated` after `deleted` → final state
  from the re-fetch; livemode mismatch ignored; full refund → cancel; partial refund → no change; processing error → 500
  and no `stripe_events` row.
- `renewal.test.js`, `portal.test.js`, `me.test.js`: happy paths, 409s, RLS path uses the caller's JWT (asserted on
  the fake fetch headers), secret key never sent on `/v1/me`.
- `config.test.js`: missing env var → error naming the var, never printing any value.

### 7.2 Swift (`UncloudTests`)

- `LiveAccountServiceTests` with a `MockURLProtocol` (`URLSessionConfiguration.ephemeral`, `protocolClasses = [MockURLProtocol.self]`,
  handler keyed by method + path, records requests): every row of §6.2 (method, path, headers incl. `apikey`/Bearer,
  JSON body) and every error-mapping row; proactive refresh before `/v1/me`; signature verification with the shared
  vector; unsigned entitlement rejected; checkout URL host check.
- `AccountModelLiveTests` (with a fake service): `authorized` single-flight (two concurrent calls → one refresh) and
  save of rotated tokens; `.signedOut` → refresh → retry → success; second `.signedOut` → revoked (deferred while
  exporting); `setAutoRenew` success/failure toggling; `.alreadySubscribed` → active; polling schedule with an injected
  sleeper; portal return refresh on activation.
- `EntitlementVerifierTests`, `EntitlementPolicyTests` additions (non-renewing ends with no grace; renewing keeps grace).
- `AccountConfigurationTests`: `live` needs all four values; Debug overrides; Release ignores them.
- `KeychainAccountTokenStoreTests`: save/load/clear round trip with a unique service name per test, cleaned up.
- Snapshots: paywall (both renewal choices selected, waiting, processing, active renewing / one year), Settings ›
  Account (renewing, not renewing, in-flight, past due, ended), locked Clean Up Library mode; light and dark.

### 7.3 Stripe TEST mode, end to end (PageReady.ca test mode now, Uncloud test mode again before live)

Setup: production deploy on test keys; app Debug with `-UncloudAccountMode live`; sign in with the owner's email (built-in
SMTP only reaches team members).

1. **Local server loop (server dev only):** `cd server/uncloud-api && vercel dev --listen 3000` in one terminal;
   `export STRIPE_WEBHOOK_SECRET="$(stripe listen --print-secret)"` before `vercel dev` (put into `.env.local`, ignored),
   then `stripe listen --forward-to localhost:3000/v1/stripe/webhook --events checkout.session.completed,customer.subscription.updated,customer.subscription.deleted,invoice.paid,invoice.payment_failed,charge.refunded`.
   `stripe trigger checkout.session.completed` checks routing (its price isn't ours → ignored, which is itself a test).
2. **Buy, renewing:** paywall → Renew automatically → Continue to Checkout → card `4242 4242 4242 4242`, any future
   date/CVC, a US ZIP → success page syncs → app opens → "You’re all set" → Continue opens the feature. Check the row in
   `entitlements` (`status active, cancel_at_period_end false`), Settings shows "Renews on …".
3. **3DS:** `4000 0027 6000 3184` → complete the challenge → same result. Fail the challenge → back on Checkout, no row.
4. **Declined:** `4000 0000 0000 0002` → Checkout shows the decline; no subscription; app stays Free.
5. **One year, no renewal:** new test user → One year → pay → row has `cancel_at_period_end true`; Stripe dashboard shows
   "Cancels <date>"; Settings toggle off with "ends on".
6. **Toggle:** Settings toggle on → Stripe shows renewing; off → "Cancels"; same via **Manage Subscription…** (portal
   "Cancel plan" / "Renew plan") → return page → app refreshes and the toggle matches.
7. **Renewal with a test clock:** `stripe test_helpers test_clocks create --frozen-time $(date +%s) --name uncloud-renewal`;
   create a customer on it (`stripe customers create --email <owner email> --test-clock clock_… -d "metadata[user_id]=<uuid>"`)
   and insert its `customers` row for the test user (SQL in §8.5) **before** checkout, so Checkout reuses it. Pay, then
   `stripe test_helpers test_clocks advance clock_… --frozen-time <period_end − 30 days>` (upcoming invoice;
   reminder emails aren't sent in test mode, check the event), then `<period_end + 1 hour>` → `invoice.paid` →
   `current_period_end` +1 year. Repeat with a non-renewing subscription → `customer.subscription.deleted` → `expired`
   → app Free after refresh.
8. **Failed renewal:** on a test-clock customer, change the card in the portal to `4000 0000 0000 0341` (attaches,
   then fails) → advance past renewal → `invoice.payment_failed` → `pastDue` → Settings past-due caption; app keeps Plus
   for 7 days (`-UncloudClockOffsetDays 8` → Free); advance through Smart Retries → canceled → `expired`.
9. **Refund:** `stripe refunds create --charge ch_…` (full) → `charge.refunded` → subscription canceled → `expired`;
   partial `--amount 100` → no change.
10. **Offline grace:** turn Wi-Fi off; Plus features keep working; `-UncloudClockOffsetDays 400` (past the period end) →
    grace caption "stays on until …"; `-UncloudClockOffsetDays 410` → Free; Wi-Fi on + Refresh → server truth.
11. **Tamper:** edit the `uncloudEntitlement` default to `plus` with a later date → relaunch → reads Free (signature).
12. **Double buy:** open two checkouts in two tabs, pay both → one active subscription remains, the other is canceled and refunded (§4.6).

---

## 8. Runbook (exact commands; secrets via files/stdin/env, never echoed)

Conventions: `set -euo pipefail`; secrets read from `~/.uncloud-secrets/` (mode 700, files 600); `jq` for parsing;
nothing printed that contains `sk_`, `rk_`, `whsec_`, `sb_secret_` or a private key. Every Stripe command runs in **test
mode** (the Stripe CLI default; the scripts never pass `--live`) and the script aborts unless
`stripe get /v1/balance | jq -e '.livemode == false'`.

### 8.1 One-time keys

```bash
umask 077; mkdir -p ~/.uncloud-secrets
# Entitlement signing key pair
openssl genpkey -algorithm ed25519 -out ~/.uncloud-secrets/entitlement-ed25519.pem
openssl pkey -in ~/.uncloud-secrets/entitlement-ed25519.pem -pubout -outform DER | tail -c 32 | base64   # public → project.yml
# Stripe restricted test key: create in Dashboard › Developers › API keys › Create restricted key (permissions §4.2),
# then paste into the file without echo:
read -rs RK && printf '%s' "$RK" > ~/.uncloud-secrets/stripe-restricted-test-key && unset RK
```

### 8.2 `server/scripts/setup-stripe.sh` (re-runnable; run again on the Uncloud account before live)

```bash
stripe get /v1/balance | jq -e '.livemode == false' >/dev/null || { echo "Not in test mode" >&2; exit 1; }
BASE="${PUBLIC_BASE_URL:-https://uncloud-api.vercel.app}"

# Product (fixed id → idempotent)
stripe get /v1/products/uncloud_plus >/dev/null 2>&1 || stripe products create --id uncloud_plus \
  --name "Uncloud Plus" \
  --description "Automatic backups, reminders, Browse Backup, Find Duplicates, Verify Backup, Free Up Space and Clean Up iCloud for Uncloud on the Mac." \
  -d "tax_code=$TAX_CODE" >/dev/null          # TAX_CODE chosen from: stripe get /v1/tax_codes --limit 100

# Price (lookup key → idempotent)
PRICE=$(stripe prices list --lookup-keys uncloud_plus_yearly --active true | jq -r '.data[0].id // empty')
[ -n "$PRICE" ] || PRICE=$(stripe prices create --product uncloud_plus --currency usd --unit-amount 999 \
  -d "recurring[interval]=year" -d tax_behavior=exclusive -d lookup_key=uncloud_plus_yearly \
  -d "nickname=Uncloud Plus yearly" | jq -r .id)

# Portal configuration (metadata[app]=uncloud → idempotent; updated in place when it exists)
PORTAL=$(stripe get /v1/billing_portal/configurations --limit 100 | jq -r '.data[] | select(.metadata.app=="uncloud") | .id' | head -1)
PORTAL_ARGS=(-d "business_profile[headline]=Manage your Uncloud Plus plan"
  -d "business_profile[privacy_policy_url]=$BASE/privacy" -d "business_profile[terms_of_service_url]=$BASE/terms"
  -d "default_return_url=$BASE/account/return"
  -d "features[subscription_cancel][enabled]=true" -d "features[subscription_cancel][mode]=at_period_end"
  -d "features[subscription_cancel][proration_behavior]=none"
  -d "features[subscription_cancel][cancellation_reason][enabled]=true"
  -d "features[subscription_cancel][cancellation_reason][options][]=too_expensive"
  -d "features[subscription_cancel][cancellation_reason][options][]=unused"
  -d "features[subscription_cancel][cancellation_reason][options][]=missing_features"
  -d "features[subscription_cancel][cancellation_reason][options][]=other"
  -d "features[subscription_update][enabled]=false"
  -d "features[payment_method_update][enabled]=true" -d "features[invoice_history][enabled]=true"
  -d "features[customer_update][enabled]=true" -d "features[customer_update][allowed_updates][]=address"
  -d "metadata[app]=uncloud")
if [ -n "$PORTAL" ]; then stripe post "/v1/billing_portal/configurations/$PORTAL" "${PORTAL_ARGS[@]}" >/dev/null
else PORTAL=$(stripe post /v1/billing_portal/configurations "${PORTAL_ARGS[@]}" | jq -r .id); fi

# Webhook endpoint (URL → idempotent). The secret only exists in the create response: piped straight to Vercel.
API_VERSION=$(node -p "require('./server/uncloud-api/node_modules/stripe').API_VERSION")   # after npm ci
HOOK_URL="$BASE/v1/stripe/webhook"
HOOK=$(stripe get /v1/webhook_endpoints --limit 100 | jq -r --arg u "$HOOK_URL" '.data[] | select(.url==$u) | .id' | head -1)
EVENTS=(checkout.session.completed customer.subscription.updated customer.subscription.deleted invoice.paid invoice.payment_failed charge.refunded)
EV_ARGS=(); for e in "${EVENTS[@]}"; do EV_ARGS+=(-d "enabled_events[]=$e"); done
if [ -n "$HOOK" ]; then
  stripe post "/v1/webhook_endpoints/$HOOK" "${EV_ARGS[@]}" >/dev/null    # secret unchanged
else
  stripe post /v1/webhook_endpoints -d "url=$HOOK_URL" -d "api_version=$API_VERSION" "${EV_ARGS[@]}" \
    -d "description=Uncloud Plus entitlements" -d "metadata[app]=uncloud" \
    | jq -r .secret | (cd server/uncloud-api && vercel env rm STRIPE_WEBHOOK_SECRET production -y >/dev/null 2>&1; vercel env add STRIPE_WEBHOOK_SECRET production) >/dev/null
fi

echo "price=$PRICE portal=$PORTAL webhook=${HOOK:-created}"   # ids only, not secrets
printf '%s' "$PORTAL" | (cd server/uncloud-api && vercel env rm STRIPE_PORTAL_CONFIGURATION_ID production -y >/dev/null 2>&1; vercel env add STRIPE_PORTAL_CONFIGURATION_ID production) >/dev/null
```

Rotating the webhook secret (e.g. lost): `stripe post /v1/webhook_endpoints/$HOOK -d disabled=true`, delete it, re-run.
The chunk-3 engineer verifies each flag name with `stripe <resource> create --help` and keeps raw `stripe post` where a
resource command lacks a flag.

### 8.3 `server/scripts/setup-supabase.sh`

```bash
cd server
supabase link --project-ref nkcbuwuuatsbskqcqosc --password "$(cat ~/.uncloud-secrets/supabase-db-password)"
SUPABASE_DB_PASSWORD="$(cat ~/.uncloud-secrets/supabase-db-password)" supabase db push      # applies migrations/
supabase config push --project-ref nkcbuwuuatsbskqcqosc                                   # auth settings + templates
# Keys (publishable is public; secret goes to Vercel without echo):
supabase projects api-keys --project-ref nkcbuwuuatsbskqcqosc -o json \
  | jq -r '.[] | select(.type=="secret") | .api_key' | head -1 \
  | (cd uncloud-api && vercel env add SUPABASE_SECRET_KEY production) >/dev/null
supabase projects api-keys --project-ref nkcbuwuuatsbskqcqosc -o json | jq -r '.[] | select(.type=="publishable") | .api_key' | head -1
# → into project.yml UNCLOUD_SUPABASE_PUBLISHABLE_KEY and Vercel SUPABASE_PUBLISHABLE_KEY
```
Manual (dashboard, once): JWT Keys → asymmetric signing keys if still legacy; Auth › URL configuration check.
If the installed CLI lacks `config push` or the new key types, the engineer uses the Management API
(`PATCH https://api.supabase.com/v1/projects/{ref}/config/auth` with a personal access token from
`~/.uncloud-secrets/supabase-pat`, header from `$(cat …)`), same values as §3.1.

### 8.4 `server/scripts/setup-vercel.sh`

```bash
cd server/uncloud-api
npm ci
vercel link --yes --project uncloud-api          # creates .vercel/ (gitignored); team = bariscoach's personal scope
add() { vercel env rm "$1" production -y >/dev/null 2>&1 || true; vercel env add "$1" production >/dev/null; }
printf '%s' "https://uncloud-api.vercel.app"            | add PUBLIC_BASE_URL
printf '%s' "https://nkcbuwuuatsbskqcqosc.supabase.co"  | add SUPABASE_URL
printf '%s' "$SUPABASE_PUBLISHABLE_KEY"                 | add SUPABASE_PUBLISHABLE_KEY
printf '%s' "uncloud_plus_yearly"                       | add STRIPE_PRICE_LOOKUP_KEY
cat ~/.uncloud-secrets/stripe-restricted-test-key       | add STRIPE_SECRET_KEY
openssl pkey -in ~/.uncloud-secrets/entitlement-ed25519.pem -outform DER | base64 | tr -d '\n' | add ENTITLEMENT_SIGNING_KEY
vercel deploy --prod
curl -fsS https://uncloud-api.vercel.app/v1/health        # {"ok":true,"livemode":false}
```
Order: 8.1 → 8.4 (first deploy, so the URL exists) → 8.3 → 8.2 (webhook needs the URL; it writes its two env vars) →
`vercel deploy --prod` again. If `uncloud-api.vercel.app` is taken, Vercel assigns another name: update
`UNCLOUD_API_BASE_URL`, `PUBLIC_BASE_URL` and re-run 8.2 (portal URLs + webhook).
Vercel **Hobby is for non-commercial use**; selling Uncloud Plus needs **Pro** before live (owner Q3).

### 8.5 Test helpers (SQL, via `supabase db query` or the SQL editor)

```sql
-- link a test-clock customer to a test user before checkout
insert into public.customers (user_id, stripe_customer_id, livemode) values ('<uuid>', 'cus_…', false)
on conflict (user_id) do update set stripe_customer_id = excluded.stripe_customer_id;
-- inspect
select user_id, plan, status, current_period_end, cancel_at_period_end, synced_at from public.entitlements;
```

### 8.6 Go-live checklist (later, owner-run)

New Stripe account "Uncloud" → dashboard settings in §2.6 → Tax registrations + head office (§2.5) → re-run 8.2 in test
mode there, test §7.3 steps 2–9 → create `rk_live_…`, run 8.2 with live mode (the only time the script's test-mode
guard is consciously replaced by a `--live` variant reviewed by the owner) → `STRIPE_SECRET_KEY`/`STRIPE_WEBHOOK_SECRET`
updated → delete test rows (§3.2) → Resend + custom domain + Supabase SMTP → Supabase Pro, Vercel Pro → Terms/Privacy
final → `project.yml` Release `UNCLOUD_ACCOUNT_MODE: "live"` → bump version → `scripts/make-dmg.sh`.

---

## 9. Build chunks

Shared rules: as `account-paywall-plan.md` §H (Swift 6 strict concurrency, macOS 14, `xcodegen generate` after adding
files, no change to `Uncloud/Export/**`/`Uncloud/Helper/**`). No secrets in any file; `.env.example` holds names only.
Engineers don't call Stripe/Supabase/Vercel; the orchestrator runs §8.

Order: **Chunk A** (server) and **Chunk B** (service layer) can run in parallel; B starts only after the concurrent
Welcome/Sign-in chunk is merged (it touches `AccountModel.swift`, `AccountTypes.swift`, `UncloudApp.swift`).
**Chunk C** (UI + gating, designer agent) after B. **Chunk D** (scripts) after A. Orchestrator runs §8 after A + D,
then §7.3 after C.

### Chunk A — Server (Haiku)

Owns: everything under `server/` except `server/scripts/`: `server/README.md`, `server/supabase/{config.toml,templates/code.html,migrations/20261018120000_uncloud_plus.sql}`,
`server/uncloud-api/**` (package.json + package-lock.json, vercel.json, .env.example, api/, lib/, public/, test/),
`.gitignore` additions.

Acceptance:
- `cd server/uncloud-api && npm ci && npm test` passes with no network; tests in §7.1 exist and pass.
- `node -e "import('./api/v1/me.js')"` etc. import cleanly; only deps are `stripe` and `jose`.
- Routes, JSON shapes, error codes, mapping and webhook behaviour match §4 exactly; the signature vector fixture exists.
- Pages render in light and dark at 375 px and 1280 px wide, no horizontal scroll; CSP header present; no inline
  script/style; copy matches §4.7 verbatim.
- Migration applies on a local `supabase start` (if Docker is available; otherwise reviewed SQL) and RLS denies
  anon/authenticated writes (a SQL test file `server/supabase/tests/rls.sql` with `set role authenticated` checks).
- `git grep -nE 'sk_(test|live)_|rk_(test|live)_|whsec_|sb_secret_|BEGIN PRIVATE KEY'` is empty (fixtures use an
  obviously-test key labelled as such and only in `test/fixtures`).
- `xcodegen generate && git status` shows no pbxproj change from server files.

### Chunk B — App service layer (Haiku)

Owns: `Uncloud/Account/{AccountService,AccountTypes,AccountConfiguration,AccountModel,PreviewAccountService,EntitlementPolicy}.swift`
(changes in §5.1, §6.1, §6.3, §6.4, §6.5), **new** `Uncloud/Account/{LiveAccountService,EntitlementVerifier,AccountLinks}.swift`,
`project.yml` (§6.6 keys; values as placeholders until the orchestrator fills the publishable and public keys),
tests `LiveAccountServiceTests`, `AccountModelLiveTests`, `EntitlementVerifierTests`, `AccountConfigurationTests`,
`KeychainAccountTokenStoreTests`, additions to `EntitlementPolicyTests`/`PreviewAccountServiceTests`,
`UncloudTests/Support/MockURLProtocol.swift`, `UncloudTests/Fixtures/entitlement-vector.json`.

Acceptance:
- All new and existing tests pass; `MockURLProtocol` is the only network in tests.
- No third-party Swift dependency; CryptoKit + Foundation + Security only.
- Release with `off` behaves exactly as today; `live` with any of the four values missing resolves to `off`.
- `PreviewAccountService` supports both renewal choices and `setAutoRenew`; existing preview flows unchanged.
- No token, key or email in `os_log`/Activity (grep for `accessToken`, `refreshToken` in log calls is empty).

### Chunk C — Paywall, Settings › Account, locks and gating (designer agent; absorbs old chunk 3)

Owns: **new** `Uncloud/Views/Account/{PaywallSheet,RenewalOptionRow,LockedFeatureView,AccountSection}.swift`;
`Uncloud/Views/MainWindow.swift` (Browse Backup lock, locked view, paywall sheet), `Uncloud/Views/CleanupView.swift`
(Library mode lock; Recently Deleted free), `Uncloud/Views/BackupToolSheets.swift` (Tools lock symbols + `require`),
`Uncloud/App/ExportCommands.swift` (`require` on Backup menu tools, Sort disabled when locked),
`Uncloud/Views/SettingsView.swift` + `Uncloud/Views/NewPhotosViews.swift` (AccountSection; reminder + automatic backup
toggles locked), `Uncloud/Model/AutoBackupController.swift` (`isAllowed` at run start; reminders), 
`Uncloud/Model/BrowseBackup.swift` (`isEnabled`), `Uncloud/Views/MenuBarContent.swift` + `Uncloud/App/UncloudApp.swift`
(menu bar insertion ANDed with the entitlement; `didBecomeActive` refresh hook), `EntitlementGatingTests`,
`AccountSnapshotTests` (paywall, locked, Settings parts).

Acceptance:
- Everything in old chunk 3's acceptance list, adjusted for: New Photos count free / reminders paid; Clean Up iCloud
  Recently Deleted + Recover free, Library mode locked.
- Paywall shows both renewal rows with "$9.99/year + tax" / "$9.99 + tax", keyboard-selectable, VoiceOver reads the
  choice and its selected state; Continue to Checkout passes the chosen `Renewal`.
- Preview: choose One year → Settings shows the toggle off with "ends on"; toggle on → "Renews on"; Turn Renewal Off/On
  debug buttons work; past-due and grace captions render.
- Snapshots §7.2 light and dark at 460 pt (paywall) and the Settings width, no clipping.
- With `-UncloudAccountMode off` every lock, the Account section and the paywall are gone, and existing snapshots match.

### Chunk D — Setup scripts (Haiku)

Owns: `server/scripts/{setup-stripe,setup-supabase,setup-vercel}.sh` (from §8.1–8.4) and `server/scripts/README.md`
(the run order and the go-live checklist §8.6).

Acceptance:
- `bash -n` and `shellcheck` clean; `set -euo pipefail`; each script prints a one-line summary of IDs only.
- Running `setup-stripe.sh` twice creates nothing the second time (verified by reasoning + a dry-run mode
  `DRY_RUN=1` that prints the commands with secrets replaced by `<redacted>`).
- Aborts unless test mode; never passes `--live`; never `echo`s/`cat`s a secret to the terminal (secrets only flow
  file → pipe → `vercel env add`).
- Flags verified against the installed CLIs' `--help`; deviations from §8 noted in the PR.

---

## 10. Owner questions

1. **Renewal default**: preselect "Renew automatically" on the paywall (recommended, clearly labelled with the
   alternative right below), or no preselection?
2. **Tax scope**: register where required (US home state now; EU/UK/Canada etc. from the first sale) with Stripe Tax, or
   use a Merchant of Record (Stripe Managed Payments / Paddle) so tax is handled for you at a higher fee? Also: EU/UK
   consumer rules expect **tax-inclusive** displayed prices; "$9.99/year + tax" is US-style. OK to show "+ tax" everywhere?
3. **Hosting plans**: Vercel Pro (Hobby forbids commercial use) and Supabase Pro (free projects pause after a week idle)
   before launch — about $45/month together. OK?
4. **Refund policy** for the Terms (e.g. full refund within 14 days on request), and should a refund always end the plan
   immediately (as designed)?
5. **Seller details**: legal name, country and a support email for Terms, Privacy, Stripe public details and receipts.
6. **Checkout brand colour**: sky blue `#1E6FD9` for the background panel as asked, or white background with sky-blue
   buttons (calmer, closer to the app)?
7. **Custom domain** timing (for the API, the pages and Resend email); until then `uncloud-api.vercel.app` and Supabase
   built-in email (team-member addresses only).

---

## Orchestrator decisions for the test-mode build (2026-10-18; owner may revise before launch)

1. Paywall: "Renew automatically every year" is preselected, with the renewal terms stated plainly next to the button
   ("Renews at $9.99/year + tax on <date>. Turn off anytime in Settings."). The one-year option is one click away.
2. Tax: build with Stripe Tax `automatic_tax` + `tax_behavior: exclusive` and "+ tax" copy, but behind a server env flag
   `STRIPE_AUTOMATIC_TAX` (default off in test). Registrations / merchant-of-record are decided before going live.
3. Hosting tiers: stay on free tiers for testing; upgrading before launch is an owner decision.
4. Refund policy placeholder: "Full refund within 14 days of purchase — email support." Seller name/country/support
   email are placeholders in one config file (`server/uncloud-api/lib/config.js` or similar), clearly marked TODO.
5. Checkout appearance: white background with sky-blue (#1E6FD9) buttons/accents.
6. Custom domain and Resend: later. Base URL `https://uncloud-api.vercel.app` in one constant.
