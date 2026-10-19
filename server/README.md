# Uncloud server

Account, checkout and entitlement service for Uncloud Plus. Not part of the Mac app build: nothing
here is read by XcodeGen (`project.yml`) or `scripts/make-dmg.sh`.

- `uncloud-api/`: Vercel functions (`api/v1/*`), shared logic (`lib/`), hosted pages (`public/`) and
  `node --test` tests (`cd uncloud-api && npm ci && npm test`, no network).
- `supabase/`: CLI workdir. `config.toml` (auth settings), `templates/code.html` (sign-in code email),
  `migrations/` (schema, RLS, `apply_subscription`) and `tests/rls.sql` (run after the migration).
- `scripts/`: setup scripts (Stripe, Supabase, Vercel) and their README.

The full design, runbook and go-live checklist are in `.claude/design/stripe-payments-plan.md`.

Secrets never go in this directory. Values come from Vercel environment variables and
`~/.uncloud-secrets/`. `uncloud-api/.env.example` lists the names only.
