// The entitlement the app verifies. Every signed-in account is on Uncloud Plus for good: there is no plan
// lookup. The shape and the signed bytes are fixed by the shipped app (Uncloud/Account/LiveAccountService.swift
// and Uncloud/Account/EntitlementVerifier.swift), so older builds keep unlocking. Keep them in sync.
// The signature message is pinned by test/fixtures/entitlement-vector.json.

import { createPrivateKey, sign } from 'node:crypto';

export const SIGNATURE_PREFIX = 'uncloud-entitlement-v1';

// The period end sent to the app. An active plan with no future period end counts as free in the app, so this
// must always be in the future. Far away on purpose: the plan never lapses.
export const PERMANENT_PERIOD_END = '2100-01-01T00:00:00Z';

// Whole-second ISO 8601 UTC, e.g. 2027-10-18T09:41:00Z.
export function isoSeconds(date) {
  return new Date(Math.floor(date.getTime() / 1000) * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
}

// The entitlement as the app receives it (camelCase, before the signature is added).
export function permanentEntitlement(now) {
  return {
    plan: 'plus',
    status: 'active',
    currentPeriodEnd: PERMANENT_PERIOD_END,
    cancelAtPeriodEnd: false,
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
