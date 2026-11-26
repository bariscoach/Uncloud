import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { route } from '../lib/http.js';
import {
  featuresFor,
  parseLicenseKey,
  verifyLicenseKey,
  verifyLicenseRequest,
  describeWebhook,
  paymentWebhookRequest,
} from '../lib/licenses.js';

const verify = route('POST', verifyLicenseRequest);
const webhook = route('POST', paymentWebhookRequest);

async function post(handler, path, body, headers = {}) {
  const response = await handler(new Request(`https://uncloud-api.vercel.app${path}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...headers },
    body: JSON.stringify(body),
  }));
  return { status: response.status, body: await response.json() };
}

test('a well-formed key parses to its tier, seats, and grandfather flag', () => {
  assert.deepEqual(parseLicenseKey('  UC1.plus.1.g.EXISTING1\n'), {
    key: 'UC1.plus.1.g.EXISTING1',
    tier: 'plus',
    seats: 1,
    grandfathered: true,
  });
  assert.deepEqual(parseLicenseKey('UC1.pro.2.s.abcd1234'), {
    key: 'UC1.pro.2.s.abcd1234',
    tier: 'pro',
    seats: 2,
    grandfathered: false,
  });
  assert.equal(parseLicenseKey('UC1.family.5.s.FamilyKey1').seats, 5);
});

test('malformed keys are rejected', () => {
  for (const key of [
    '',
    'plus',
    'UC1.plus.1.s.short',
    'UC1.plus.2.s.abcd1234',
    'UC1.pro.1.s.abcd1234',
    'UC1.family.5.g.abcd1234',
    'UC1.pro.02.s.abcd1234',
    'UC1.free.1.s.abcd1234',
    'UC1.plus.1.x.abcd1234',
    'UC1.plus.1.s.abcd1234.extra',
  ]) {
    assert.equal(parseLicenseKey(key), null, key);
  }
  assert.equal(parseLicenseKey(1), null);
});

test('features follow the tier, and family includes Pro', () => {
  assert.deepEqual(featuresFor('plus'), [
    'unlimitedExport', 'automaticBackups', 'allLayouts', 'mapPlaceBrowse', 'xmpSidecars',
  ]);
  assert.ok(featuresFor('pro').includes('verifiedICloudCleanup'));
  assert.ok(featuresFor('pro').includes('verifyBackup'));
  assert.ok(featuresFor('pro').includes('secondDestination'));
  assert.ok(featuresFor('pro').includes('emailSupport'));
  assert.deepEqual(featuresFor('family'), featuresFor('pro'));
  assert.deepEqual(featuresFor('free'), []);
});

test('verify accepts a grandfather Plus key without an account', async () => {
  const { status, body } = await post(verify, '/v1/licenses/verify', { key: 'UC1.plus.1.g.EXISTING1' }, {
    authorization: 'Bearer not-an-account',
  });
  assert.equal(status, 200);
  assert.equal(body.valid, true);
  assert.equal(body.mode, 'stub');
  assert.equal(body.tier, 'plus');
  assert.equal(body.seats, 1);
  assert.equal(body.grandfathered, true);
  assert.equal(body.accountRequired, false);
  assert.ok(body.features.includes('automaticBackups'));
});

test('verify reports an unrecognized key without storing it', async () => {
  const { status, body } = await post(verify, '/v1/licenses/verify', { key: 'nope' });
  assert.equal(status, 200);
  assert.deepEqual(body, {
    valid: false,
    mode: 'stub',
    reason: 'unrecognized_key',
    accountRequired: false,
  });
  assert.equal(verifyLicenseKey('nope').valid, false);
});

test('verify rejects a body that is not an object', async () => {
  const response = await verify(new Request('https://uncloud-api.vercel.app/v1/licenses/verify', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: '[]',
  }));
  assert.equal(response.status, 400);
});

test('verify does not allow GET', async () => {
  const response = await verify(new Request('https://uncloud-api.vercel.app/v1/licenses/verify'));
  assert.equal(response.status, 405);
});

test('a Lemon Squeezy style order is acknowledged and not fulfilled', async () => {
  const payload = {
    meta: { event_name: 'order_created', custom_data: { user_id: 1 } },
    data: {
      type: 'orders',
      attributes: {
        user_email: 'buyer@example.com',
        first_order_item: { product_name: 'Uncloud Plus', variant_name: 'Plus' },
      },
    },
  };
  const { status, body } = await post(webhook, '/v1/webhooks/payments', payload);
  assert.equal(status, 200);
  assert.equal(body.received, true);
  assert.equal(body.fulfilled, false);
  assert.equal(body.mode, 'stub');
  assert.equal(body.provider, 'lemonsqueezy');
  assert.equal(body.event, 'order_created');
  assert.equal(body.tier, 'plus');
  assert.equal(body.signatureChecked, false);
  assert.equal(JSON.stringify(body).includes('buyer@example.com'), false);
  assert.equal(JSON.stringify(body).includes('user_id'), false);
});

test('a Paddle style transaction is acknowledged and not fulfilled', async () => {
  const described = describeWebhook({
    event_type: 'transaction.completed',
    data: {
      id: 'txn_123',
      customer_id: 'ctm_123',
      custom_data: { tier: 'family' },
      items: [{ price: { name: 'Uncloud Family', custom_data: { tier: 'family' } } }],
    },
  });
  assert.equal(described.provider, 'paddle');
  assert.equal(described.tier, 'family');
  const { body } = await post(webhook, '/v1/webhooks/payments', {
    event_type: 'transaction.completed',
    data: { custom_data: { tier: 'pro' }, items: [] },
  });
  assert.equal(body.provider, 'paddle');
  assert.equal(body.tier, 'pro');
  assert.equal(body.fulfilled, false);
});

test('an unknown webhook still returns the stub and stores nothing', async () => {
  const { status, body } = await post(webhook, '/v1/webhooks/payments', { hello: 'there' });
  assert.equal(status, 200);
  assert.equal(body.provider, 'unknown');
  assert.equal(body.tier, null);
  assert.equal(body.fulfilled, false);
  assert.match(body.reason, /stores nothing/);
});

test('the license routes are real files, not the removed Stripe paths', () => {
  const verifySource = readFileSync(new URL('../api/v1/licenses/verify.js', import.meta.url), 'utf8');
  const webhookSource = readFileSync(new URL('../api/v1/webhooks/payments.js', import.meta.url), 'utf8');
  assert.match(verifySource, /verifyLicenseRequest/);
  assert.match(webhookSource, /paymentWebhookRequest/);
  assert.doesNotMatch(verifySource + webhookSource, /sk_live|whsec_|STRIPE_SECRET|api_key/i);
});
