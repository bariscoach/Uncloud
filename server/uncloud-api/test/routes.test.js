import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createPublicKey, verify } from 'node:crypto';
import { me, health } from '../lib/handlers.js';
import { signedMessage } from '../lib/entitlement.js';
import { FAKE_RESTRICTED_TEST_KEY, FAKE_RESTRICTED_LIVE_KEY } from './fixtures/keys.js';
import { makeDeps, invoke, json, fakeDb, USER_A, USER_B, TEST_SIGNING_KEY } from './helpers.js';

const meRequest = (user) => new Request('https://uncloud-api.vercel.app/v1/me', { headers: { authorization: `Bearer ${user}` } });

// ---- GET /v1/me ----------------------------------------------------------

test('me without a token is 401 unauthorized', async () => {
  const response = await invoke('GET', me, new Request('https://uncloud-api.vercel.app/v1/me'), makeDeps());
  assert.equal(response.status, 401);
  assert.equal((await response.json()).error.code, 'unauthorized');
});

test('me returns the account and an always-active plus entitlement with the documented keys', async () => {
  const { status, body } = await json(await invoke('GET', me, meRequest(USER_A), makeDeps()));
  assert.equal(status, 200);
  assert.deepEqual(body.account, { id: USER_A, email: 'name@example.com' });
  assert.deepEqual(Object.keys(body.entitlement).sort(), [
    'cancelAtPeriodEnd', 'checkedAt', 'currentPeriodEnd', 'plan', 'signature', 'status',
  ]);
  assert.equal(body.entitlement.plan, 'plus');
  assert.equal(body.entitlement.status, 'active');
  assert.equal(body.entitlement.currentPeriodEnd, '2100-01-01T00:00:00Z');
  assert.equal(body.entitlement.cancelAtPeriodEnd, false);
  assert.equal(body.entitlement.checkedAt, '2026-10-18T09:41:07Z');
});

test('me signs the entitlement so the app can verify it', async () => {
  const { body } = await json(await invoke('GET', me, meRequest(USER_A), makeDeps()));
  const { signature, ...entitlement } = body.entitlement;
  const message = signedMessage({ accountId: USER_A, entitlement });
  const ok = verify(null, Buffer.from(message, 'utf8'), createPublicKey(TEST_SIGNING_KEY), Buffer.from(signature, 'base64'));
  assert.equal(ok, true);
});

test('me gives every account the same plan and never reads the database', async () => {
  const db = fakeDb();
  for (const user of [USER_A, USER_B]) {
    const { body } = await json(await invoke('GET', me, meRequest(user), makeDeps({ db })));
    assert.equal(body.entitlement.plan, 'plus');
    assert.equal(body.entitlement.status, 'active');
  }
  assert.equal(db.calls.length, 0, 'no database call on /v1/me');
});

// ---- GET /v1/health ------------------------------------------------------

test('health is unauthenticated and reports livemode from the key prefix', async () => {
  const test = await json(health({ STRIPE_SECRET_KEY: FAKE_RESTRICTED_TEST_KEY }));
  assert.deepEqual(test.body, { ok: true, livemode: false });
  const none = await json(health({}));
  assert.deepEqual(none.body, { ok: true, livemode: false });
  const live = await json(health({ STRIPE_SECRET_KEY: FAKE_RESTRICTED_LIVE_KEY }));
  assert.deepEqual(live.body, { ok: true, livemode: true });
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

test('the removed payment endpoints are no longer routes', async () => {
  const { GET, POST } = await import('../api/v1/[...path].js');
  for (const path of ['checkout', 'checkout/sync', 'portal', 'subscription/renewal', 'stripe/webhook']) {
    const response = await POST(new Request(`https://uncloud-api.vercel.app/v1/${path}`, { method: 'POST' }));
    assert.equal(response.status, 404, path);
  }
  assert.equal(typeof GET, 'function');
});
