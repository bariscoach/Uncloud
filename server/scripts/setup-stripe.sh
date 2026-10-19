#!/usr/bin/env bash
# Uncloud Plus: Stripe product, price, customer portal configuration and webhook endpoint (plan section 8.2).
#
# Usage:  server/scripts/setup-stripe.sh [--dry-run]     (DRY_RUN=1 works too)
#         TAX_CODE=txcd_... server/scripts/setup-stripe.sh   (optional: skip the tax code lookup)
#
# Test mode only: aborts unless the Stripe CLI reports livemode=false. Never passes --live.
# Re-runnable: every object is found by a fixed id, lookup key, metadata or URL before anything is created.
# The webhook signing secret exists only in the create response; it goes straight to `vercel env add`.
#
# Needs npm ci in server/uncloud-api first (setup-vercel.sh does it) to read the SDK's pinned API version.
set -euo pipefail

DRY_RUN="${DRY_RUN:-0}"
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
API_DIR="$REPO/server/uncloud-api"
BASE_URL="${UNCLOUD_API_BASE_URL:-https://uncloud-api.vercel.app}"
HOOK_URL="$BASE_URL/v1/stripe/webhook"
PRODUCT_ID="uncloud_plus"
PRICE_LOOKUP="uncloud_plus_yearly"
PRODUCT_NAME="Uncloud Plus"
PRODUCT_DESC="Automatic backups, reminders, Browse Backup, Find Duplicates, Verify Backup, Free Up Space and Clean Up iCloud for Uncloud on the Mac."
EVENTS="checkout.session.completed customer.subscription.updated customer.subscription.deleted invoice.paid invoice.payment_failed charge.refunded"

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

require_cmd jq stripe node
if [ ! -d "$API_DIR" ]; then
  [ "$DRY_RUN" = 1 ] || fail "missing $API_DIR (chunk A: server/uncloud-api/)"
  echo "note: $API_DIR does not exist yet (chunk A); dry-run continues" >&2
fi

# Event list and portal arguments are built here (local only) so dry-run can print them.
EV_ARGS=()
for e in $EVENTS; do EV_ARGS+=("-d" "enabled_events[]=$e"); done

PORTAL_ARGS=(
  -d "business_profile[headline]=Manage your Uncloud Plus plan"
  -d "business_profile[privacy_policy_url]=$BASE_URL/privacy"
  -d "business_profile[terms_of_service_url]=$BASE_URL/terms"
  -d "default_return_url=$BASE_URL/account/return"
  -d "features[subscription_cancel][enabled]=true"
  -d "features[subscription_cancel][mode]=at_period_end"
  -d "features[subscription_cancel][proration_behavior]=none"
  -d "features[subscription_cancel][cancellation_reason][enabled]=true"
  -d "features[subscription_cancel][cancellation_reason][options][]=too_expensive"
  -d "features[subscription_cancel][cancellation_reason][options][]=unused"
  -d "features[subscription_cancel][cancellation_reason][options][]=missing_features"
  -d "features[subscription_cancel][cancellation_reason][options][]=other"
  -d "features[subscription_update][enabled]=false"
  -d "features[payment_method_update][enabled]=true"
  -d "features[invoice_history][enabled]=true"
  -d "features[customer_update][enabled]=true"
  -d "features[customer_update][allowed_updates][]=address"
  -d "metadata[app]=uncloud"
)

step "Test-mode guard"
if [ "$DRY_RUN" = 1 ]; then
  plan "stripe get /v1/balance must report livemode=false, otherwise abort"
else
  stripe get /v1/balance | jq -e '.livemode == false' >/dev/null \
    || fail "the Stripe CLI is not in test mode (or not logged in); aborting, nothing changed"
  ok "test mode confirmed"
fi

step "SDK pinned API version (for the webhook endpoint)"
if [ "$DRY_RUN" = 1 ]; then
  plan "node -p \"require('stripe').API_VERSION\" in server/uncloud-api (after npm ci)"
  API_VERSION="<SDK API_VERSION>"
else
  [ -d "$API_DIR/node_modules/stripe" ] || fail "run setup-vercel.sh first (npm ci in server/uncloud-api)"
  API_VERSION="$(cd "$API_DIR" && node -p "require('stripe').API_VERSION")"
  [ -n "$API_VERSION" ] || fail "could not read API_VERSION from the stripe SDK"
  ok "$API_VERSION"
fi

step "Product $PRODUCT_ID"
if [ "$DRY_RUN" = 1 ]; then
  plan "stripe get /v1/products/$PRODUCT_ID; if missing:"
  plan "  tax code: TAX_CODE if set, else the single 'Software as a service ... personal use' code from stripe get /v1/tax_codes"
  plan "  stripe products create --id $PRODUCT_ID --name \"$PRODUCT_NAME\" --description \"...\" --tax-code <tax code>"
  PRODUCT_NOTE="created if missing"
else
  if PRODUCT_JSON="$(stripe get "/v1/products/$PRODUCT_ID" 2>/dev/null)"; then
    [ "$(jq -r '.active' <<<"$PRODUCT_JSON")" = "true" ] || warn "product $PRODUCT_ID is archived; reactivate it in the dashboard"
    ok "exists"
  else
    TAX_CODE="${TAX_CODE:-}"
    if [ -z "$TAX_CODE" ]; then
      TAX_LIST="$(stripe get /v1/tax_codes --limit 100)"
      jq -e '.has_more == false' <<<"$TAX_LIST" >/dev/null \
        || fail "more than 100 tax codes; set TAX_CODE explicitly (see RUNBOOK)"
      CANDIDATES="$(jq -r '[.data[] | select((.name | test("software as a service"; "i")) and (.name | test("personal"; "i"))) | .id] | join(" ")' <<<"$TAX_LIST")"
      case "$CANDIDATES" in
        "") fail "no 'Software as a service ... personal use' tax code found; set TAX_CODE explicitly" ;;
        *" "*) fail "several matching tax codes ($CANDIDATES); set TAX_CODE explicitly" ;;
        *) TAX_CODE="$CANDIDATES" ;;
      esac
    fi
    stripe products create --id "$PRODUCT_ID" --name "$PRODUCT_NAME" --description "$PRODUCT_DESC" \
      --tax-code "$TAX_CODE" >/dev/null
    ok "created with tax code $TAX_CODE"
  fi
  PRODUCT_NOTE="ok"
fi

step "Price $PRICE_LOOKUP (USD 9.99 per year, tax exclusive)"
if [ "$DRY_RUN" = 1 ]; then
  plan "stripe prices list --lookup-keys $PRICE_LOOKUP --active=true"
  plan "if none: stripe post /v1/prices -d product=$PRODUCT_ID -d currency=usd -d unit_amount=999 -d recurring[interval]=year -d tax_behavior=exclusive -d lookup_key=$PRICE_LOOKUP -d 'nickname=Uncloud Plus yearly'"
  PRICE_ID="<price id>"
else
  PRICES="$(stripe prices list --lookup-keys "$PRICE_LOOKUP" --active=true)"
  PRICE_ID="$(jq -r '.data[0].id // empty' <<<"$PRICES")"
  if [ -n "$PRICE_ID" ]; then
    MATCH="$(jq -r '.data[0] | select(.unit_amount == 999 and .currency == "usd" and .recurring.interval == "year" and .tax_behavior == "exclusive" and .product == "uncloud_plus") | .id' <<<"$PRICES")"
    [ -n "$MATCH" ] || fail "price with lookup key $PRICE_LOOKUP exists with other settings; do not edit it, see RUNBOOK (price change)"
    ok "exists: $PRICE_ID"
  else
    PRICE_JSON="$(stripe post /v1/prices -d "product=$PRODUCT_ID" -d currency=usd -d unit_amount=999 \
      -d "recurring[interval]=year" -d tax_behavior=exclusive -d "lookup_key=$PRICE_LOOKUP" \
      -d "nickname=Uncloud Plus yearly")"
    PRICE_ID="$(jq -r '.id' <<<"$PRICE_JSON")"
    ok "created: $PRICE_ID"
  fi
fi

step "Customer portal configuration (metadata app=uncloud)"
if [ "$DRY_RUN" = 1 ]; then
  plan "stripe get /v1/billing_portal/configurations --limit 100; pick metadata.app == uncloud"
  plan "if found: stripe post /v1/billing_portal/configurations/<id> with:"
  printf '         %s\n' "${PORTAL_ARGS[*]}"
  plan "if none: stripe post /v1/billing_portal/configurations with the same arguments"
  PORTAL_ID="<portal configuration id>"
else
  PORTALS="$(stripe get /v1/billing_portal/configurations --limit 100)"
  jq -e '.has_more == false' <<<"$PORTALS" >/dev/null \
    || fail "more than 100 portal configurations on this account; see RUNBOOK"
  PORTAL_ID="$(jq -r '[.data[] | select(.metadata.app == "uncloud")][0].id // empty' <<<"$PORTALS")"
  if [ -n "$PORTAL_ID" ]; then
    stripe post "/v1/billing_portal/configurations/$PORTAL_ID" "${PORTAL_ARGS[@]}" >/dev/null
    ok "updated: $PORTAL_ID"
  else
    PORTAL_JSON="$(stripe post /v1/billing_portal/configurations "${PORTAL_ARGS[@]}")"
    PORTAL_ID="$(jq -r '.id' <<<"$PORTAL_JSON")"
    ok "created: $PORTAL_ID"
  fi
fi

step "Webhook endpoint $HOOK_URL"
if [ "$DRY_RUN" = 1 ]; then
  plan "stripe get /v1/webhook_endpoints --limit 100; pick url == $HOOK_URL"
  plan "if found: stripe post /v1/webhook_endpoints/<id> with the six enabled_events (secret unchanged)"
  plan "if none: stripe post /v1/webhook_endpoints -d url=$HOOK_URL -d api_version=$API_VERSION <six enabled_events> -d description=... -d metadata[app]=uncloud"
  plan "  the returned secret goes straight to vercel env add STRIPE_WEBHOOK_SECRET (not shown)"
  HOOK_ID="<webhook endpoint id>"
else
  HOOKS="$(stripe get /v1/webhook_endpoints --limit 100)"
  jq -e '.has_more == false' <<<"$HOOKS" >/dev/null \
    || fail "more than 100 webhook endpoints on this account; see RUNBOOK"
  HOOK_ID="$(jq -r --arg u "$HOOK_URL" '[.data[] | select(.url == $u)][0].id // empty' <<<"$HOOKS")"
  if [ -n "$HOOK_ID" ]; then
    HOOK_API="$(jq -r --arg u "$HOOK_URL" '[.data[] | select(.url == $u)][0].api_version // empty' <<<"$HOOKS")"
    [ "$HOOK_API" = "$API_VERSION" ] || warn "endpoint api_version is $HOOK_API but the SDK pins $API_VERSION; api_version cannot be changed on an existing endpoint (see RUNBOOK)"
    stripe post "/v1/webhook_endpoints/$HOOK_ID" "${EV_ARGS[@]}" >/dev/null
    ok "exists: $HOOK_ID (events updated, secret unchanged)"
    VERCEL_ENVS="$(cd "$API_DIR" && vercel env ls production 2>/dev/null || true)"
    if [[ $VERCEL_ENVS != *STRIPE_WEBHOOK_SECRET* ]]; then
      warn "STRIPE_WEBHOOK_SECRET is not set on Vercel; the endpoint's secret is only shown at creation, so roll it (RUNBOOK, lost webhook secret)"
    fi
  else
    HOOK_JSON="$(stripe post /v1/webhook_endpoints -d "url=$HOOK_URL" -d "api_version=$API_VERSION" \
      "${EV_ARGS[@]}" -d "description=Uncloud Plus entitlements" -d "metadata[app]=uncloud")"
    HOOK_ID="$(jq -r '.id' <<<"$HOOK_JSON")"
    SECRET="$(jq -r '.secret // empty' <<<"$HOOK_JSON")"
    unset HOOK_JSON
    [[ $SECRET =~ ^whsec_[A-Za-z0-9]+$ ]] \
      || fail "endpoint $HOOK_ID was created but no secret came back; delete it in the dashboard and re-run"
    put_env STRIPE_WEBHOOK_SECRET secret "webhook endpoint create response (in memory)" '^whsec_[A-Za-z0-9]+$' \
      printf '%s' "$SECRET"
    unset SECRET
    ok "created: $HOOK_ID"
  fi
fi

step "Vercel variable for the portal configuration"
put_env STRIPE_PORTAL_CONFIGURATION_ID plain "billing portal configuration id" '^bpc_[A-Za-z0-9]+$' \
  printf '%s' "$PORTAL_ID"

if [ "$DRY_RUN" = 1 ]; then
  echo
  echo "dry-run complete: nothing was sent to Stripe or Vercel. Redeploy after the real run (vercel deploy --prod)."
  exit 0
fi

echo
echo "stripe: product=$PRODUCT_ID ($PRODUCT_NOTE) price=$PRICE_ID portal=$PORTAL_ID webhook=$HOOK_ID"
echo "next: cd server/uncloud-api && vercel deploy --prod   (picks up the new Vercel variables)"
