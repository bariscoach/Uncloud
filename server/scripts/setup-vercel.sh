#!/usr/bin/env bash
# Uncloud Plus: Vercel project, production environment variables, first deploy (plan section 8.4).
#
# Usage:  server/scripts/setup-vercel.sh [--dry-run]     (DRY_RUN=1 works too)
#
# Secrets only flow file -> pipe -> `vercel env add`. Nothing secret is printed.
# Run order: setup-vercel.sh -> setup-supabase.sh -> setup-stripe.sh -> setup-vercel.sh (redeploy).
set -euo pipefail

DRY_RUN="${DRY_RUN:-0}"
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
API_DIR="$REPO/server/uncloud-api"
SECRETS="$HOME/.uncloud-secrets"
PROJECT="uncloud-api"
SUPABASE_REF="nkcbuwuuatsbskqcqosc"
SUPABASE_URL="https://$SUPABASE_REF.supabase.co"
BASE_URL="${UNCLOUD_API_BASE_URL:-https://uncloud-api.vercel.app}"

step() { printf '\n==> %s\n' "$*"; }
plan() { printf '    [dry-run] %s\n' "$*"; }
ok()   { printf '    ok: %s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || fail "missing command: $c"
  done
}

# Refuses anything that is not a regular file with owner-only permissions. Never reads it.
secret_file() {
  local f="$1" mode
  [ -f "$f" ] || fail "missing secret file ~/.uncloud-secrets/$(basename "$f")"
  mode="$(stat -f %Lp "$f")"
  case "$mode" in
    600|400) ;;
    *) fail "~/.uncloud-secrets/$(basename "$f") has mode $mode; expected 600" ;;
  esac
}

# put_env NAME KIND SOURCE REGEX COMMAND...
# COMMAND writes the value to stdout. The value is checked against REGEX (if non-empty) and then
# stored for Vercel production with `vercel env add --force`. It is never printed. KIND is
# "secret" (sensitive) or "plain". In dry-run, COMMAND is not executed.
put_env() {
  local name="$1" kind="$2" source="$3" regex="$4" value flag
  shift 4
  if [ "$kind" = secret ]; then flag=--sensitive; else flag=--no-sensitive; fi
  if [ "$DRY_RUN" = 1 ]; then
    plan "vercel env add $name production $flag --force   (value from $source, not shown)"
    return 0
  fi
  value="$("$@")" || fail "could not read the value for $name ($source)"
  [ -n "$value" ] || fail "empty value for $name ($source)"
  if [ -n "$regex" ] && ! [[ $value =~ $regex ]]; then
    fail "value for $name ($source) has an unexpected format; nothing was sent"
  fi
  printf '%s' "$value" | (cd "$API_DIR" && vercel env add "$name" production "$flag" --force --yes) >/dev/null
  unset value
  ok "vercel env $name set ($kind)"
}

# Supabase API key by type (publishable|secret). Prints the key on stdout only for put_env to capture.
supabase_api_key() {
  supabase projects api-keys --project-ref "$SUPABASE_REF" --reveal -o json \
    | jq -r --arg t "$1" 'map(select(.type == $t)) | first | .api_key // empty'
}

# Entitlement signing key: PKCS#8 DER, base64 on one line (plan section 4.2).
pem_der_b64() {
  openssl pkey -in "$1" -outform DER | base64 | tr -d '\n'
}

require_cmd jq openssl base64 curl npm vercel supabase
if [ ! -d "$API_DIR" ]; then
  [ "$DRY_RUN" = 1 ] || fail "missing $API_DIR (chunk A: server/uncloud-api/)"
  echo "note: $API_DIR does not exist yet (chunk A); dry-run continues" >&2
fi

# Preflight for the two secret sources. Checked before anything is sent anywhere, so a bad file fails early.
if [ "$DRY_RUN" != 1 ]; then
  secret_file "$SECRETS/stripe-restricted-test-key"
  secret_file "$SECRETS/entitlement-ed25519.pem"
  RESTRICTED_KEY="$(<"$SECRETS/stripe-restricted-test-key")"
  [[ $RESTRICTED_KEY =~ ^rk_test_[A-Za-z0-9]+$ ]] \
    || fail "stripe-restricted-test-key must be a test-mode restricted key (rk_test_...); nothing was sent"
  unset RESTRICTED_KEY
  openssl pkey -in "$SECRETS/entitlement-ed25519.pem" -noout 2>/dev/null \
    || fail "entitlement-ed25519.pem is not a readable private key (use Homebrew openssl; see RUNBOOK); nothing was sent"
  ok "secret files checked (contents not shown)"
fi

step "Vercel project and dependencies"
if [ "$DRY_RUN" = 1 ]; then
  plan "(cd server/uncloud-api && npm ci)"
  plan "(cd server/uncloud-api && vercel link --yes --project $PROJECT)   (creates .vercel/, gitignored)"
else
  (cd "$API_DIR" && npm ci --no-audit --no-fund >/dev/null)
  (cd "$API_DIR" && vercel link --yes --project "$PROJECT" >/dev/null)
  ok "linked to Vercel project $PROJECT"
fi

step "Production environment variables (names only are printed)"
put_env PUBLIC_BASE_URL plain "UNCLOUD_API_BASE_URL" "" printf '%s' "$BASE_URL"
put_env SUPABASE_URL plain "constant" "" printf '%s' "$SUPABASE_URL"
put_env SUPABASE_PUBLISHABLE_KEY plain "supabase projects api-keys (publishable)" '^sb_publishable_[A-Za-z0-9_-]+$' \
  supabase_api_key publishable
put_env STRIPE_PRICE_LOOKUP_KEY plain "constant" "" printf '%s' "uncloud_plus_yearly"
put_env STRIPE_AUTOMATIC_TAX plain "constant (test default off, orchestrator decision 2)" "" printf '%s' "false"
put_env STRIPE_SECRET_KEY secret "~/.uncloud-secrets/stripe-restricted-test-key" '^rk_test_[A-Za-z0-9]+$' \
  bash -c 'cat "$1"' _ "$SECRETS/stripe-restricted-test-key"
put_env ENTITLEMENT_SIGNING_KEY secret "~/.uncloud-secrets/entitlement-ed25519.pem" '^[A-Za-z0-9+/]+=*$' \
  pem_der_b64 "$SECRETS/entitlement-ed25519.pem"

step "Production deploy"
if [ "$DRY_RUN" = 1 ]; then
  plan "(cd server/uncloud-api && vercel deploy --prod --yes)"
  plan "curl -fsS $BASE_URL/v1/health  -> expect ok=true, livemode=false"
  echo
  echo "dry-run complete: nothing was sent to Vercel, Supabase or Stripe."
  exit 0
fi

(cd "$API_DIR" && vercel deploy --prod --yes >/dev/null)
ok "deployed to production"

HEALTH="$(curl -fsS --max-time 30 "$BASE_URL/v1/health")" || fail "health check failed at $BASE_URL/v1/health (if the name is taken, set UNCLOUD_API_BASE_URL and see RUNBOOK.md)"
printf '%s' "$HEALTH" | jq -e '.ok == true and .livemode == false' >/dev/null \
  || fail "health check at $BASE_URL/v1/health did not report ok=true, livemode=false"
ok "health: $BASE_URL/v1/health ok, test mode"
echo "vercel: project=$PROJECT url=$BASE_URL"
