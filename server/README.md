# Uncloud server

API and hosted legal pages for Uncloud. Not part of the Mac app build: nothing
here is read by XcodeGen (`project.yml`) or `scripts/make-dmg.sh`.

Accounts are optional. Export and license keys do not require one. `POST /v1/licenses/verify` and
`POST /v1/webhooks/payments` are stubs in `uncloud-api/lib/licenses.js`: no payment-provider secret,
and nothing is stored. Checkout URLs are not set here. They are `UNCLOUD_CHECKOUT_PLUS_URL`,
`UNCLOUD_CHECKOUT_PRO_URL`, and `UNCLOUD_CHECKOUT_FAMILY_URL` on the website project (`site/`,
Vercel project `uncloud`, https://www.tryuncloud.com), or `site/checkout.config.json`.

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
