# Uncloud Plus setup runbook

The scripts in this folder create the Stripe, Supabase and Vercel setup for Uncloud Plus (plan:
`.claude/design/stripe-payments-plan.md` sections 8.1 to 8.6). Everything here is **test mode** until the
go-live checklist at the bottom is done.

| Script | Does |
|---|---|
| `setup-vercel.sh` | `npm ci`, links the `uncloud-api` Vercel project, sets production env vars, deploys, checks `/v1/health` |
| `setup-supabase.sh` | links project `nkcbuwuuatsbskqcqosc`, applies migrations, pushes auth config, sets `SUPABASE_SECRET_KEY` on Vercel |
| `setup-stripe.sh` | product, price (lookup key), customer portal configuration, webhook endpoint; sets `STRIPE_WEBHOOK_SECRET` and `STRIPE_PORTAL_CONFIGURATION_ID` on Vercel |

All three are re-runnable. Each one finds existing objects first and only creates what is missing. Each
accepts `--dry-run` (or `DRY_RUN=1`), which prints the planned actions and calls no service.

## Prerequisites

- CLIs: `stripe` (logged in to the PageReady.ca account), `supabase`, `vercel` (logged in to the owner's personal Vercel account),
  `jq`, `node` 22, `npm`, and **Homebrew `openssl`** first on `PATH` (macOS's LibreSSL cannot read the
  Ed25519 PEM).
- `npm ci` in `server/uncloud-api` is needed before `setup-stripe.sh` (it reads the SDK's pinned API version).
  `setup-vercel.sh` does this.
- Secret files in `~/.uncloud-secrets/` (folder mode 700, files mode 600). Nothing secret is ever printed
  or passed on a command line.

| File | Content | Made in |
|---|---|---|
| `entitlement-ed25519.pem` | Ed25519 private key (PKCS#8 PEM) | step 1 below |
| `stripe-restricted-test-key` | `rk_test_…` restricted key | step 2 below |
| `supabase-db-password` | database password | Supabase dashboard |

## One-time key setup (plan 8.1)

```bash
umask 077; mkdir -p ~/.uncloud-secrets
# 1. Entitlement signing key pair (the public half goes into project.yml, never the private half)
openssl genpkey -algorithm ed25519 -out ~/.uncloud-secrets/entitlement-ed25519.pem
openssl pkey -in ~/.uncloud-secrets/entitlement-ed25519.pem -pubout -outform DER | tail -c 32 | base64
# 2. Restricted test key: Dashboard > Developers > API keys > Create restricted key (test mode),
#    permissions per the table below. Paste it without echo:
read -rs RK && printf '%s' "$RK" > ~/.uncloud-secrets/stripe-restricted-test-key && unset RK
chmod 600 ~/.uncloud-secrets/stripe-restricted-test-key
```

Permissions for the restricted key (set each one to Read, Write, or None as shown). These cover every Stripe
call the server makes; `server/uncloud-api/test/permissions.test.js` fails if a call is added without being listed here:

| Dashboard resource | Access | Used by |
|---|---|---|
| Checkout Sessions | Read and Write | create a session; read it on the success page |
| Customers | Write | create the customer for a user |
| Customer portal | Write | portal sessions |
| Prices | Read | find the price by lookup key |
| Subscriptions | Read and Write | read, update renewal and one-year flag, cancel duplicates and refunds |
| Invoices | Read | read the invoice of a duplicate or refunded payment |
| Invoice Payments | Read | find the PaymentIntent behind an invoice (if the key form lists it separately) |
| Refunds | Read and Write | list refunds on a charge; refund a duplicate's payment |

Not needed (remove if set): Products, Charges. The webhook payloads carry the charge, so the server does not call
the Charges API.

## Run order

Run each script with `--dry-run` first and read the plan.

```bash
cd <repo root>
server/scripts/setup-vercel.sh --dry-run
server/scripts/setup-vercel.sh          # first deploy: creates the URL the rest depends on
server/scripts/setup-supabase.sh --dry-run
server/scripts/setup-supabase.sh
server/scripts/setup-stripe.sh --dry-run
server/scripts/setup-stripe.sh          # writes STRIPE_WEBHOOK_SECRET and STRIPE_PORTAL_CONFIGURATION_ID to Vercel
(cd server/uncloud-api && vercel deploy --prod)   # picks up the variables added by setup-stripe.sh
```

Then:

1. Copy the publishable key printed by `setup-supabase.sh` into `project.yml`
   (`UNCLOUD_SUPABASE_PUBLISHABLE_KEY`) and the entitlement public key (base64 of the 32 raw bytes, from
   step 1) into `UNCLOUD_ENTITLEMENT_PUBLIC_KEY`.
2. Manual, once, in the Supabase dashboard: Project Settings > JWT Keys must use asymmetric signing keys
   (ES256/RS256). Authentication > URL Configuration: site URL `https://uncloud-api.vercel.app`.
3. Check the health endpoint: `curl -fsS https://uncloud-api.vercel.app/v1/health` must print
   `{"ok":true,"livemode":false}`.
4. Test with `stripe listen` and the checklist in plan section 7.3.

A `setup-stripe.sh` run prints one summary line with IDs only, for example
`stripe: product=uncloud_plus (ok) price=price_… portal=bpc_… webhook=we_…`.

## What each run checks

- **Test mode:** `setup-stripe.sh` aborts unless `stripe get /v1/balance` reports `livemode=false`. No script
  passes `--live`.
- **Keys:** the restricted key must match `rk_test_…`. `setup-vercel.sh` refuses anything else before it
  sends any variable. Secret values are checked against their expected prefix and sent only through a pipe
  to `vercel env add --sensitive`.
- **Price:** if a price with lookup key `uncloud_plus_yearly` exists with other settings (amount, currency,
  interval, tax behavior, product), the script stops and changes nothing (see "Price change" below).
- **Tax code:** the product's tax code is the single "Software as a service … personal use" code. If there is
  more than one match or none, set `TAX_CODE=txcd_…` and re-run.

## Operations

**Price change.** Do not edit the price. Create a new price with the same lookup key and
`transfer_lookup_key=true` (plan 2.1), in the dashboard or with `stripe post /v1/prices`, then re-run
`setup-stripe.sh`. The server finds the price by lookup key, so no deploy is needed.

**Webhook endpoint: `api_version` warning.** The endpoint's API version is set at creation and cannot be
changed. If the script warns that it differs from the SDK, create a new endpoint for the URL (disable and
delete the old one in the dashboard first, so only one endpoint remains) and re-run `setup-stripe.sh`.

**Lost webhook secret.** The secret is shown only once, at creation. If `setup-stripe.sh` warns that
`STRIPE_WEBHOOK_SECRET` is missing from Vercel, roll it:

```bash
stripe get /v1/webhook_endpoints --limit 100 | jq -r '.data[] | select(.url=="https://uncloud-api.vercel.app/v1/stripe/webhook") | .id'
stripe post /v1/webhook_endpoints/<we_id> -d disabled=true
stripe delete /v1/webhook_endpoints/<we_id>
server/scripts/setup-stripe.sh                   # creates a fresh endpoint and stores its secret
(cd server/uncloud-api && vercel deploy --prod)
```

**Base URL taken.** If Vercel gives the project another hostname, set `UNCLOUD_API_BASE_URL` to it and
re-run `setup-vercel.sh` and `setup-stripe.sh` (portal URLs and the webhook URL depend on it). The app's
`UNCLOUD_API_BASE_URL` in `project.yml` must match.

**Rotating the restricted key.** Create the new key, replace the file in `~/.uncloud-secrets` (mode 600),
re-run `setup-vercel.sh`, then delete the old key in the dashboard.

**Rotating the entitlement signing key.** Avoid this after launch. The app verifies signatures with the public
key compiled into `project.yml`, so a new key needs a new app build, and installed apps keep failing
verification until they update. If it is unavoidable, ship the app with both public keys first, then rotate.

**Re-running the Stripe setup on a different account** (Uncloud, before go-live): see the checklist below.
Run it with the Stripe CLI logged in to that account. The script keeps its test-mode guard.

## Go-live checklist (owner-run; plan 8.6)

1. New Stripe account "Uncloud". Set the account-level settings in plan 2.6 (public name, descriptor,
   support and legal URLs, branding, customer emails, revenue recovery).
2. Tax: head-office address, default tax behavior exclusive, and a registration for each jurisdiction where
   the owner must collect (plan 2.5). Set `STRIPE_AUTOMATIC_TAX=true` only then.
3. Re-run `setup-stripe.sh` in test mode on that account, then test plan 7.3 steps 2 to 9.
4. Create `rk_live_…`, store it as `~/.uncloud-secrets/stripe-restricted-live-key`, and run a reviewed
   live variant of `setup-stripe.sh` (this script never passes `--live`). Update `STRIPE_SECRET_KEY` and
   `STRIPE_WEBHOOK_SECRET`.
5. Delete the test rows (plan 3.2): `delete from customers where not livemode; delete from entitlements where not livemode; delete from stripe_events where not livemode;`
6. Resend and a custom domain for Supabase SMTP. Upgrade Supabase to Pro and Vercel to Pro (owner decision).
7. Final Terms and Privacy text. `project.yml` Release: `UNCLOUD_ACCOUNT_MODE: "live"`. Bump the version.
   Run `scripts/make-dmg.sh`.

## Deviations from plan section 8

- This file is `RUNBOOK.md`, as requested. Plan 4.1 names it `README.md`.
- `setup-supabase.sh` passes the DB password through `SUPABASE_DB_PASSWORD` in the environment, not on the
  command line (plan 8.3 used `--password "$(cat …)"`, which is visible in `ps`).
- `setup-vercel.sh` sets `STRIPE_AUTOMATIC_TAX=false` (orchestrator decision 2). It also checks the key files
  before sending anything.
- Vercel variables are written with `vercel env add --force` (overwrite in place), not `rm` then `add`, so a
  re-run never leaves a variable missing.
- The Stripe script finds the tax code itself and verifies an existing price's settings instead of trusting
  the lookup key alone. It also warns if an existing webhook endpoint has no secret on Vercel.
- `stripe prices list --active=true` (the CLI's flag takes `=`; `--active true` would be read as an argument).
  `stripe prices create` has no lookup-key flag, so the price is created with `stripe post`.
- `supabase config diff` runs before `config push`, and the push uses `--yes` so it is non-interactive.

## Not yet verified against live services

Dry-runs and stub-based tests passed. These steps still need a first live run, and the orchestrator should
watch for them:

- `supabase link` taking the DB password from `SUPABASE_DB_PASSWORD`.
- The JSON shape of `supabase projects api-keys --reveal -o json` (the scripts read `.type` and `.api_key`;
  they stop with an error and send nothing if the shape differs).
- `supabase config push --yes` against the planned `config.toml` (chunk A).
- The portal configuration parameters on the pinned Stripe API version.
