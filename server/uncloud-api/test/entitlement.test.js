import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createPublicKey, verify } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { signedMessage, permanentEntitlement, isoSeconds, PERMANENT_PERIOD_END } from '../lib/entitlement.js';
import { NOW } from './helpers.js';

test('the permanent entitlement is plus, active, never cancelling, with a far-future period end', () => {
  const entitlement = permanentEntitlement(NOW);
  assert.deepEqual(entitlement, {
    plan: 'plus',
    status: 'active',
    currentPeriodEnd: PERMANENT_PERIOD_END,
    cancelAtPeriodEnd: false,
    checkedAt: '2026-10-18T09:41:07Z',
  });
  assert.ok(new Date(PERMANENT_PERIOD_END).getTime() > NOW.getTime() + 50 * 365 * 24 * 60 * 60 * 1000);
});

test('whole-second ISO formatting drops milliseconds', () => {
  assert.equal(isoSeconds(new Date('2027-10-18T09:41:00.999Z')), '2027-10-18T09:41:00Z');
});

test('signed message layout matches the documented bytes', () => {
  const message = signedMessage({
    accountId: 'acc',
    entitlement: { plan: 'plus', status: 'active', currentPeriodEnd: '2027-10-18T09:41:00Z', cancelAtPeriodEnd: false, checkedAt: '2026-10-18T09:41:07Z' },
  });
  assert.equal(
    message,
    'uncloud-entitlement-v1\nacc\nplus\nactive\n2027-10-18T09:41:00Z\nfalse\n2026-10-18T09:41:07Z',
  );
});

test('signatures match the shared vector fixture (same bytes as the app verifier)', () => {
  const path = fileURLToPath(new URL('./fixtures/entitlement-vector.json', import.meta.url));
  const v = JSON.parse(readFileSync(path, 'utf8'));
  const publicKey = createPublicKey({
    key: { kty: 'OKP', crv: 'Ed25519', x: Buffer.from(v.publicKey, 'base64').toString('base64url') },
    format: 'jwk',
  });
  const entitlement = {
    plan: v.plan,
    status: v.status,
    currentPeriodEnd: v.currentPeriodEnd,
    cancelAtPeriodEnd: v.cancelAtPeriodEnd,
    checkedAt: v.checkedAt,
  };
  const message = signedMessage({ accountId: v.accountId, entitlement });
  assert.equal(message, v.message);
  assert.equal(verify(null, Buffer.from(v.message, 'utf8'), publicKey, Buffer.from(v.signature, 'base64')), true);
});
