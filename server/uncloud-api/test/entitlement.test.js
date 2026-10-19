import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createPublicKey, verify } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import {
  mapSubscription,
  toWire,
  isoSeconds,
  signedMessage,
  isOurSubscription,
} from '../lib/entitlement.js';
import { subscription, NOW, DAY, NOW_SECONDS } from './helpers.js';

const opts = { now: NOW, priceLookupKey: 'uncloud_plus_yearly', livemode: false };

test('mapping table (plan 4.5), row by row', () => {
  const cases = [
    ['active', 'plus', 'active'],
    ['trialing', 'plus', 'trialing'],
    ['past_due', 'plus', 'pastDue'],
    ['unpaid', 'free', 'expired'],
    ['paused', 'free', 'expired'],
    ['canceled', 'free', 'expired'],
    ['incomplete', 'free', 'none'],
    ['incomplete_expired', 'free', 'none'],
  ];
  for (const [stripeStatus, plan, status] of cases) {
    const row = mapSubscription(subscription({ status: stripeStatus }), opts);
    assert.equal(row.plan, plan, stripeStatus);
    assert.equal(row.status, status, stripeStatus);
  }
});

test('cancel_at_period_end is carried through', () => {
  assert.equal(mapSubscription(subscription({ cancel: true }), opts).cancel_at_period_end, true);
  assert.equal(mapSubscription(subscription({ cancel: false }), opts).cancel_at_period_end, false);
});

test('period end is read from the item (basil) and from the subscription (older API)', () => {
  const end = NOW_SECONDS + 365 * DAY;
  const basil = mapSubscription(subscription({ periodEnd: end, basil: true }), opts);
  const legacy = mapSubscription(subscription({ periodEnd: end, basil: false }), opts);
  assert.equal(basil.current_period_end, isoSeconds(new Date(end * 1000)));
  assert.equal(legacy.current_period_end, basil.current_period_end);
  assert.match(basil.current_period_end, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
});

test('a foreign price is ignored (null), by lookup key or by product', () => {
  assert.equal(mapSubscription(subscription({ lookupKey: 'pageready_other', product: 'prod_other' }), opts), null);
  assert.equal(mapSubscription(subscription({ lookupKey: null, product: 'uncloud_plus' }), opts) !== null, true);
  assert.equal(isOurSubscription(subscription({ lookupKey: 'pageready_other', product: 'prod_other' }), { priceLookupKey: 'uncloud_plus_yearly' }), false);
});

test('an old price on the Uncloud product still counts after its lookup key moved', () => {
  const sub = subscription({ lookupKey: null, product: 'uncloud_plus', priceId: 'price_old' });
  assert.equal(mapSubscription(sub, opts).stripe_price_id, 'price_old');
});

test('whole-second ISO formatting drops milliseconds', () => {
  assert.equal(isoSeconds(new Date('2027-10-18T09:41:00.999Z')), '2027-10-18T09:41:00Z');
});

test('read-time rule: active, non-renewing and past its end becomes expired (and free)', () => {
  const past = { plan: 'plus', status: 'active', current_period_end: '2026-10-17T00:00:00Z', cancel_at_period_end: true };
  const wire = toWire(past, NOW);
  assert.equal(wire.status, 'expired');
  assert.equal(wire.plan, 'free');
  assert.equal(wire.currentPeriodEnd, '2026-10-17T00:00:00Z');
});

test('read-time rule does not expire a renewing plan or one still inside its period', () => {
  const renewing = { plan: 'plus', status: 'active', current_period_end: '2026-10-17T00:00:00Z', cancel_at_period_end: false };
  assert.equal(toWire(renewing, NOW).status, 'active');
  const inside = { plan: 'plus', status: 'active', current_period_end: '2027-10-18T00:00:00Z', cancel_at_period_end: true };
  assert.equal(toWire(inside, NOW).status, 'active');
});

test('no row means free / none', () => {
  assert.deepEqual(toWire(null, NOW), {
    plan: 'free',
    status: 'none',
    currentPeriodEnd: null,
    cancelAtPeriodEnd: false,
    checkedAt: '2026-10-18T09:41:07Z',
  });
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
