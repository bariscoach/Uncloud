import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createPublicKey, verify } from 'node:crypto';
import { me, portal, renewal, health } from '../lib/handlers.js';
import { signedMessage } from '../lib/entitlement.js';
import {
  fakeStripe, fakeDb, makeDeps, invoke, json, subscription, authed, USER_A, USER_B, TEST_SIGNING_KEY,
} from './helpers.js';

const activeRow = (overrides = {}) => ({
  user_id: USER_A, plan: 'plus', status: 'active', current_period_end: '2027-10-18T09:41:00Z',
  cancel_at_period_end: false, stripe_subscription_id: 'sub_test_1', livemode: false, ...overrides,
});

// ---- GET /v1/me ----------------------------------------------------------

test('me without a token is 401 unauthorized', async () => {
  const response = await invoke('GET', me, new Request('https://uncloud-api.vercel.app/v1/me'), makeDeps());
  assert.equal(response.status, 401);
  assert.equal((await response.json()).error.code, 'unauthorized');
});

test('me returns the account and a signed entitlement that verifies', async () => {
  const db = fakeDb({ entitlements: [activeRow()] });
  const deps = makeDeps({ db });
  const req = new Request('https://uncloud-api.vercel.app/v1/me', { headers: { authorization: `Bearer ${USER_A}` } });
  const { status, body } = await json(await invoke('GET', me, req, deps));
  assert.equal(status, 200);
  assert.deepEqual(body.account, { id: USER_A, email: 'name@example.com' });
  assert.equal(body.entitlement.plan, 'plus');
  assert.equal(body.entitlement.status, 'active');
  assert.equal(body.entitlement.currentPeriodEnd, '2027-10-18T09:41:00Z');
  assert.equal(body.entitlement.checkedAt, '2026-10-18T09:41:07Z');

  const { signature, ...entitlement } = body.entitlement;
  const message = signedMessage({ accountId: USER_A, entitlement });
  const ok = verify(null, Buffer.from(message, 'utf8'), createPublicKey(TEST_SIGNING_KEY), Buffer.from(signature, 'base64'));
  assert.equal(ok, true);
});

test('me reads the entitlement with the caller JWT and never uses the secret key', async () => {
  const db = fakeDb({ entitlements: [activeRow()] });
  const { stripe, calls } = fakeStripe({});
  const req = new Request('https://uncloud-api.vercel.app/v1/me', { headers: { authorization: `Bearer ${USER_A}` } });
  await invoke('GET', me, req, makeDeps({ db, stripe }));
  const rpc = db.calls.find((c) => c.op === 'rpc');
  assert.equal(rpc.name, 'my_entitlement');
  assert.deepEqual(rpc.mode, { jwt: USER_A });
  assert.ok(db.calls.every((c) => !c.mode?.service), 'no service-key call on /v1/me');
  assert.equal(calls.length, 0, 'no Stripe call');
});

test('me for a user with no row is free / none', async () => {
  const req = new Request('https://uncloud-api.vercel.app/v1/me', { headers: { authorization: `Bearer ${USER_B}` } });
  const { body } = await json(await invoke('GET', me, req, makeDeps()));
  assert.equal(body.entitlement.plan, 'free');
  assert.equal(body.entitlement.status, 'none');
  assert.equal(body.entitlement.currentPeriodEnd, null);
});

test('me applies the read-time expiry for a non-renewing plan past its end', async () => {
  const db = fakeDb({ entitlements: [activeRow({ cancel_at_period_end: true, current_period_end: '2026-10-01T00:00:00Z' })] });
  const req = new Request('https://uncloud-api.vercel.app/v1/me', { headers: { authorization: `Bearer ${USER_A}` } });
  const { body } = await json(await invoke('GET', me, req, makeDeps({ db })));
  assert.equal(body.entitlement.status, 'expired');
  assert.equal(body.entitlement.plan, 'free');
});

test('health is unauthenticated and reports livemode from the key prefix', async () => {
  const test = await json(health({ STRIPE_SECRET_KEY: 'rk_test_FAKE_NOT_A_REAL_KEY_0000000000' }));
  assert.deepEqual(test.body, { ok: true, livemode: false });
  const none = await json(health({}));
  assert.deepEqual(none.body, { ok: true, livemode: false });
  const live = await json(health({ STRIPE_SECRET_KEY: 'rk_live_FAKE_NOT_A_REAL_KEY_0000000000' }));
  assert.deepEqual(live.body, { ok: true, livemode: true });
});

// ---- POST /v1/portal -----------------------------------------------------

test('portal without a customer row is 409 no_subscription', async () => {
  const { stripe, calls } = fakeStripe({});
  const { status, body } = await json(await invoke('POST', portal, authed('/v1/portal', { body: {} }), makeDeps({ stripe })));
  assert.equal(status, 409);
  assert.equal(body.error.code, 'no_subscription');
  assert.equal(calls.length, 0);
});

test('portal opens the configured portal for the stored customer', async () => {
  const { stripe, calls } = fakeStripe({
    'POST /v1/billing_portal/sessions': () => ({ id: 'bps_1', url: 'https://billing.stripe.com/p/session/bps_1' }),
  });
  const db = fakeDb({ customers: [{ user_id: USER_A, stripe_customer_id: 'cus_test_1', livemode: false }] });
  const { status, body } = await json(await invoke('POST', portal, authed('/v1/portal', { body: {} }), makeDeps({ stripe, db })));
  assert.equal(status, 200);
  assert.deepEqual(body, { url: 'https://billing.stripe.com/p/session/bps_1' });
  const create = calls.find((c) => c.path === '/v1/billing_portal/sessions');
  assert.equal(create.body.get('customer'), 'cus_test_1');
  assert.equal(create.body.get('configuration'), 'bpc_FAKE_TEST');
  assert.equal(create.body.get('return_url'), 'https://uncloud-api.vercel.app/account/return');
});

// ---- POST /v1/subscription/renewal ---------------------------------------

test('renewal without a live subscription is 409 no_subscription', async () => {
  const { stripe, calls } = fakeStripe({});
  const db = fakeDb({ entitlements: [activeRow({ status: 'expired', stripe_subscription_id: null })] });
  const { status, body } = await json(await invoke('POST', renewal, authed('/v1/subscription/renewal', { body: { autoRenew: false } }), makeDeps({ stripe, db })));
  assert.equal(status, 409);
  assert.equal(body.error.code, 'no_subscription');
  assert.equal(calls.length, 0);
});

test('renewal with a period that has ended is 409', async () => {
  const { stripe } = fakeStripe({});
  const db = fakeDb({ entitlements: [activeRow({ current_period_end: '2026-01-01T00:00:00Z' })] });
  const { status } = await json(await invoke('POST', renewal, authed('/v1/subscription/renewal', { body: { autoRenew: true } }), makeDeps({ stripe, db })));
  assert.equal(status, 409);
});

test('renewal must be a boolean', async () => {
  const { stripe } = fakeStripe({});
  const db = fakeDb({ entitlements: [activeRow()] });
  for (const bad of ['true', 1, null]) {
    const { status, body } = await json(await invoke('POST', renewal, authed('/v1/subscription/renewal', { body: { autoRenew: bad } }), makeDeps({ stripe, db })));
    assert.equal(status, 400, String(bad));
    assert.equal(body.error.code, 'bad_request');
  }
});

test('turning renewal off sets cancel_at_period_end, syncs, and returns a signed entitlement', async () => {
  const sub = subscription({ id: 'sub_test_1', cancel: true });
  const { stripe, calls } = fakeStripe({
    'POST /v1/subscriptions/sub_test_1': () => sub,
    'GET /v1/subscriptions/sub_test_1': () => sub,
  });
  const db = fakeDb({ entitlements: [activeRow()] });
  const { status, body } = await json(await invoke('POST', renewal, authed('/v1/subscription/renewal', { body: { autoRenew: false } }), makeDeps({ stripe, db })));
  assert.equal(status, 200);
  const update = calls.find((c) => c.method === 'POST' && c.path === '/v1/subscriptions/sub_test_1');
  assert.equal(update.body.get('cancel_at_period_end'), 'true');
  assert.equal(body.entitlement.cancelAtPeriodEnd, true);
  assert.equal(typeof body.entitlement.signature, 'string');
  assert.equal(db.tables.entitlements[0].cancel_at_period_end, true);
});

test('turning renewal on sends cancel_at_period_end=false', async () => {
  const sub = subscription({ id: 'sub_test_1', cancel: false });
  const { stripe, calls } = fakeStripe({
    'POST /v1/subscriptions/sub_test_1': () => sub,
    'GET /v1/subscriptions/sub_test_1': () => sub,
  });
  const db = fakeDb({ entitlements: [activeRow({ cancel_at_period_end: true })] });
  const { status, body } = await json(await invoke('POST', renewal, authed('/v1/subscription/renewal', { body: { autoRenew: true } }), makeDeps({ stripe, db })));
  assert.equal(status, 200);
  assert.equal(calls.find((c) => c.method === 'POST').body.get('cancel_at_period_end'), 'false');
  assert.equal(body.entitlement.cancelAtPeriodEnd, false);
});

test('the route refuses another method with a JSON 405', async () => {
  const response = await invoke('POST', renewal, new Request('https://uncloud-api.vercel.app/v1/subscription/renewal', { method: 'GET' }), makeDeps());
  assert.equal(response.status, 405);
  assert.equal((await response.json()).error.code, 'method_not_allowed');
});


// ---- unknown /v1 paths (review L5) -----------------------------------------

test('an unknown /v1 path gets the JSON error envelope, not the HTML 404 page', async () => {
  const { GET, POST } = await import('../api/v1/[...path].js');
  for (const handler of [GET, POST]) {
    const response = await handler(new Request('https://uncloud-api.vercel.app/v1/nope'));
    assert.equal(response.status, 404);
    assert.match(response.headers.get('content-type'), /application\/json/);
    assert.equal((await response.json()).error.code, 'not_found');
  }
});
