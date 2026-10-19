#!/usr/bin/env bash
# Uncloud Plus: Supabase link, migrations, auth config, and the secret key for Vercel (plan section 8.3).
#
# Usage:  server/scripts/setup-supabase.sh [--dry-run]     (DRY_RUN=1 works too)
#
# The DB password is read from ~/.uncloud-secrets/supabase-db-password into the environment only
# (SUPABASE_DB_PASSWORD), never onto a command line or into the terminal. The secret API key goes
# straight from the CLI into `vercel env add` through a pipe.
set -euo pipefail

DRY_RUN="${DRY_RUN:-0}"
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SERVER_DIR="$REPO/server"
API_DIR="$REPO/server/uncloud-api"
SECRETS="$HOME/.uncloud-secrets"
SUPABASE_REF="nkcbuwuuatsbskqcqosc"

step() { printf '\n==> %s\n' "$*"; }
plan() { printf '    [dry-run] %s\n' "$*"; }
ok()   { printf '    ok: %s\n' "$*"; }
warn() { printf '    warning: %s\n' "$*" >&2; }
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

require_cmd jq stat supabase vercel

if [ ! -f "$SERVER_DIR/supabase/config.toml" ]; then
  [ "$DRY_RUN" = 1 ] || fail "missing server/supabase/config.toml (chunk A)"
  echo "note: server/supabase/config.toml does not exist yet (chunk A); dry-run continues" >&2
fi

step "Preconditions"
if [ "$DRY_RUN" = 1 ]; then
  plan "check ~/.uncloud-secrets/supabase-db-password exists with mode 600 (contents not read)"
else
  secret_file "$SECRETS/supabase-db-password"
  # Read into the environment only. $(< file) strips the trailing newline and nothing is echoed.
  SUPABASE_DB_PASSWORD="$(<"$SECRETS/supabase-db-password")"
  [ -n "$SUPABASE_DB_PASSWORD" ] || fail "supabase-db-password is empty"
  export SUPABASE_DB_PASSWORD
  ok "database password loaded from file (not shown)"
fi

step "Link project $SUPABASE_REF"
if [ "$DRY_RUN" = 1 ]; then
  plan "(cd server && supabase link --project-ref $SUPABASE_REF)   password via SUPABASE_DB_PASSWORD"
else
  # </dev/null: if the CLI wants an interactive answer it fails now instead of hanging.
  (cd "$SERVER_DIR" && supabase link --project-ref "$SUPABASE_REF" </dev/null >/dev/null)
  ok "linked"
fi

step "Apply migrations (server/supabase/migrations/)"
if [ "$DRY_RUN" = 1 ]; then
  plan "(cd server && supabase db push --linked --yes)"
else
  (cd "$SERVER_DIR" && supabase db push --linked --yes)
  ok "migrations applied"
fi

step "Push auth settings and email templates (server/supabase/config.toml)"
if [ "$DRY_RUN" = 1 ]; then
  plan "(cd server && supabase config diff)   # review before the push"
  plan "(cd server && supabase config push --project-ref $SUPABASE_REF --yes)"
else
  (cd "$SERVER_DIR" && supabase config diff --project-ref "$SUPABASE_REF") \
    || warn "supabase config diff failed; the push below will still run"
  # config.toml reads the SMTP password from RESEND_API_KEY; it is passed through the environment only.
  [[ -s "$SECRETS/resend-api-key" ]] || fail "~/.uncloud-secrets/resend-api-key is missing (needed for the Resend SMTP settings)"
  (cd "$SERVER_DIR" && RESEND_API_KEY="$(cat "$SECRETS/resend-api-key")" supabase config push --project-ref "$SUPABASE_REF" --yes)
  ok "auth config pushed"
fi

step "Secret API key to Vercel production (never printed)"
put_env SUPABASE_SECRET_KEY secret "supabase projects api-keys (secret)" '^sb_secret_[A-Za-z0-9_-]+$' \
  supabase_api_key secret

step "Publishable key (public by design; goes into project.yml)"
if [ "$DRY_RUN" = 1 ]; then
  plan "print the publishable key (public) for UNCLOUD_SUPABASE_PUBLISHABLE_KEY in project.yml"
else
  PUBLISHABLE="$(supabase_api_key publishable)"
  [[ $PUBLISHABLE =~ ^sb_publishable_[A-Za-z0-9_-]+$ ]] \
    || fail "no publishable key found in the supabase projects api-keys output (check the JSON shape)"
  echo "publishable key for project.yml UNCLOUD_SUPABASE_PUBLISHABLE_KEY: $PUBLISHABLE"
  unset PUBLISHABLE
fi

step "Manual check (dashboard, once)"
echo "    Project Settings > JWT Keys: asymmetric signing keys (ES256/RS256) must be active."
echo "    Authentication > URL Configuration: site URL = https://uncloud-api.vercel.app."

if [ "$DRY_RUN" = 1 ]; then
  echo
  echo "dry-run complete: nothing was sent to Supabase or Vercel."
  exit 0
fi

echo
echo "supabase: ref=$SUPABASE_REF migrations=applied auth-config=pushed secret-key=vercel"
