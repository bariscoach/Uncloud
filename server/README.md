# Uncloud server

API and hosted legal pages for Uncloud. Not part of the Mac app build: nothing
here is read by XcodeGen (`project.yml`) or `scripts/make-dmg.sh`.

Accounts are optional. Export and license keys do not require one. `POST /v1/licenses/verify` checks
an Ed25519 signature and the revocation list. `POST /v1/webhooks/payments` verifies
`Stripe-Signature`, mints one key per Checkout session, emails it with Resend, and revokes it on
`charge.refunded`. Names are in `uncloud-api/.env.example`. The test keypair in
`uncloud-api/test/fixtures/license-key.js` is for tests only. The app verifies with the production
public key in `UncloudLicensePublicKey`.

License rows are in the separate Supabase project **uncloud-licenses**
(`https://zkdykcghctegpeanslyz.supabase.co`). `lib/license-ledger.js` reads
`LICENSE_SUPABASE_URL`, `LICENSE_SUPABASE_SECRET_KEY`, and `LICENSE_SUPABASE_PUBLISHABLE_KEY`,
and falls back to `SUPABASE_URL`, `SUPABASE_SECRET_KEY`, and `SUPABASE_PUBLISHABLE_KEY` when one
of those is empty. The license migration is already applied on uncloud-licenses.

On the Vercel project **uncloud-api**, production `LICENSE_SIGNING_PRIVATE_KEY` and `STRIPE_PRICE_*`
are already set. The Stripe test webhook `we_1UfsKpFQA2wOQUo5vXY1tV0Y` points at
`https://uncloud-api.vercel.app/v1/webhooks/payments`. The payment links redirect to
`https://www.tryuncloud.com/license`.

Checkout URLs are `UNCLOUD_CHECKOUT_PLUS_URL`, `UNCLOUD_CHECKOUT_PRO_URL`, and
`UNCLOUD_CHECKOUT_FAMILY_URL` on the website project (`site/`, Vercel project `uncloud`,
https://www.tryuncloud.com), or `site/checkout.config.json`.

`server/scripts/RUNBOOK.md` is the earlier account and Stripe setup. It is not required for the
license stub. The marketing site is not this service.

- `uncloud-api/`: Vercel functions (`api/v1/*`; `POST /v1/account/delete` removes the account and its Stripe billing), shared logic (`lib/`), hosted pages (`public/`) and
  `node --test` tests (`cd uncloud-api && npm ci && npm test`, no network).
- `supabase/`: CLI workdir. `config.toml` (auth settings), `templates/code.html` (sign-in code email),
  `migrations/` (schema, RLS, `apply_subscription`) and `tests/rls.sql` (run after the migration).
- `scripts/`: setup scripts (Stripe, Supabase, Vercel) and their README.

`.claude/design/stripe-payments-plan.md` is an earlier subscription design. It is not the current one-time license plan.

Secrets never go in this directory. Values come from Vercel environment variables and
`~/.uncloud-secrets/`. `uncloud-api/.env.example` lists the names only.
