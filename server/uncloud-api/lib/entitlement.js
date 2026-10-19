// Stripe subscription -> entitlement row (pure), read-time expiry, and the Ed25519 signature
// the app verifies. The message format is shared with the Swift verifier; see
// test/fixtures/entitlement-vector.json.

import { createPrivateKey, sign } from 'node:crypto';
import { idOf, firstItem, periodEnd } from './stripe-shapes.js';
import { PRODUCT_ID } from './config.js';

export const SIGNATURE_PREFIX = 'uncloud-entitlement-v1';

// Whole-second ISO 8601 UTC, e.g. 2027-10-18T09:41:00Z.
export function isoSeconds(date) {
  return new Date(Math.floor(date.getTime() / 1000) * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
}

const STATUS_MAP = {
  active: { plan: 'plus', status: 'active' },
  trialing: { plan: 'plus', status: 'trialing' },
  past_due: { plan: 'plus', status: 'pastDue' },
  unpaid: { plan: 'free', status: 'expired' },
  paused: { plan: 'free', status: 'expired' },
  canceled: { plan: 'free', status: 'expired' },
  incomplete: { plan: 'free', status: 'none' },
  incomplete_expired: { plan: 'free', status: 'none' },
};

// True when the subscription is one of ours: the Uncloud price lookup key, or any price on the
// Uncloud product (so an old price keeps working after a lookup key moves to a new price).
export function isOurSubscription(subscription, { priceLookupKey, productId = PRODUCT_ID }) {
  const price = firstItem(subscription)?.price;
  if (!price) return false;
  return price.lookup_key === priceLookupKey || idOf(price.product) === productId;
}

// Maps a Stripe subscription to the entitlements row shape (snake_case, as the table and
// apply_subscription use it). Returns null for a subscription that is not ours.
export function mapSubscription(subscription, { now, priceLookupKey, livemode }) {
  if (!isOurSubscription(subscription, { priceLookupKey })) return null;
  const mapped = STATUS_MAP[subscription.status] ?? { plan: 'free', status: 'none' };
  const end = periodEnd(subscription);
  return {
    plan: mapped.plan,
    status: mapped.status,
    current_period_end: end ? isoSeconds(end) : null,
    cancel_at_period_end: subscription.cancel_at_period_end === true,
    stripe_subscription_id: subscription.id,
    stripe_price_id: idOf(firstItem(subscription)?.price) ?? null,
    livemode: livemode ?? subscription.livemode === true,
  };
}

// Entitlement as the app receives it (camelCase), with the read-time rule applied:
// an active, non-renewing plan whose period has ended is expired (covers a late deletion event).
export function toWire(row, now) {
  const source = row ?? {};
  let plan = source.plan ?? 'free';
  let status = source.status ?? 'none';
  const end = source.current_period_end ? new Date(source.current_period_end) : null;
  const cancelAtPeriodEnd = source.cancel_at_period_end === true;
  if (status === 'active' && cancelAtPeriodEnd && end && end.getTime() <= now.getTime()) {
    status = 'expired';
    plan = 'free';
  }
  return {
    plan,
    status,
    currentPeriodEnd: end ? isoSeconds(end) : null,
    cancelAtPeriodEnd,
    checkedAt: isoSeconds(now),
  };
}

// The exact bytes that are signed (UTF-8). Keep in sync with Uncloud/Account/EntitlementVerifier.swift.
export function signedMessage({ accountId, entitlement }) {
  return [
    SIGNATURE_PREFIX,
    accountId,
    entitlement.plan,
    entitlement.status,
    entitlement.currentPeriodEnd ?? '',
    entitlement.cancelAtPeriodEnd ? 'true' : 'false',
    entitlement.checkedAt,
  ].join('\n');
}

// privateKeyBase64: Ed25519 private key, PKCS#8 DER, base64 (ENTITLEMENT_SIGNING_KEY).
export function loadSigningKey(privateKeyBase64) {
  return createPrivateKey({
    key: Buffer.from(privateKeyBase64, 'base64'),
    format: 'der',
    type: 'pkcs8',
  });
}

export function signEntitlement(privateKey, { accountId, entitlement }) {
  const message = Buffer.from(signedMessage({ accountId, entitlement }), 'utf8');
  return sign(null, message, privateKey).toString('base64');
}
