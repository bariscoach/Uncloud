import { test } from 'node:test';
import assert from 'node:assert/strict';
import { checkoutSync } from '../lib/handlers.js';
import { applySubscription, syncCheckoutSession } from '../lib/sync.js';
import {
  fakeStripe, fakeDb, makeDeps, invoke, json, subscription, checkoutSession, USER_A, NOW_SECONDS, DAY, testConfig,
} from './helpers.js';

const SESSION_ID = 'cs_test_a1b2c3d4e5f6';

const sessionRequest = (sessionId) =>
  new Request('https://uncloud-api.vercel.app/v1/checkout/sync', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ sessionId }),
  });

const writes = (db) => db.calls.filter((c) => c.op === 'upsert' || (c.op === 'rpc' && c.name === 'apply_subscription'));
const stripeCalls = (calls, method, path) => calls.filter((c) => c.method === method && c.path === path);

function sessionRoutes(sub, session = checkoutSession({ id: SESSION_ID })) {
  return {
    [`GET /v1/checkout/sessions/${session.id}`]: () => session,
    [`GET /v1/subscriptions/${sub.id}`]: () => sub,
    [`POST /v1/subscriptions/${sub.id}`]: () => ({ ...sub, cancel_at_period_end: true }),
  };
}

// ---- POST /v1/checkout/sync ------------------------------------------------

test('a malformed session id is 204 and makes no Stripe call', async () => {
  const { stripe, calls } = fakeStripe({});
  const deps = makeDeps({ stripe });
  for (const bad of ['', 'cs_live_short', 'cs_test_has spaces!!', 'pi_test_abcdefghijk', 42]) {
    const { status } = await json(await invoke('POST', checkoutSync, sessionRequest(bad), deps));
    assert.equal(status, 204, String(bad));
  }
  assert.equal(calls.length, 0);
});

test('an unknown session is 204 (no information leak)', async () => {
  const { stripe } = fakeStripe({
    [`GET /v1/checkout/sessions/${SESSION_ID}`]: () => { throw { status: 404, error: { type: 'invalid_request_error', message: 'No such session' } }; },
  });
  const { status } = await json(await invoke('POST', checkoutSync, sessionRequest(SESSION_ID), makeDeps({ stripe })));
  assert.equal(status, 204);
});

test('a complete subscription session stores the customer and the entitlement, then 204', async () => {
  const sub = subscription({ id: 'sub_test_1', status: 'active' });
  const { stripe } = fakeStripe(sessionRoutes(sub));
  const db = fakeDb();
  const { status } = await json(await invoke('POST', checkoutSync, sessionRequest(SESSION_ID), makeDeps({ stripe, db })));
  assert.equal(status, 204);

  const customer = db.tables.customers.find((r) => r.user_id === USER_A);
  assert.equal(customer.stripe_customer_id, 'cus_test_1');
  const entitlement = db.tables.entitlements.find((r) => r.user_id === USER_A);
  assert.equal(entitlement.plan, 'plus');
  assert.equal(entitlement.status, 'active');
  assert.equal(entitlement.cancel_at_period_end, false);
  assert.equal(entitlement.stripe_subscription_id, 'sub_test_1');
});

test('one-year choice sets cancel_at_period_end with the one-year idempotency key', async () => {
  const sub = subscription({ id: 'sub_test_1', status: 'active' });
  const session = checkoutSession({ id: SESSION_ID, renewal: 'oneYear' });
  const { stripe, calls } = fakeStripe(sessionRoutes(sub, session));
  const db = fakeDb();
  await invoke('POST', checkoutSync, sessionRequest(SESSION_ID), makeDeps({ stripe, db }));

  const update = stripeCalls(calls, 'POST', '/v1/subscriptions/sub_test_1')[0];
  assert.equal(update.body.get('cancel_at_period_end'), 'true');
  assert.equal(update.idempotencyKey, `one-year-${SESSION_ID}`);
  const entitlement = db.tables.entitlements.find((r) => r.user_id === USER_A);
  assert.equal(entitlement.cancel_at_period_end, true);
});

test('an incomplete session writes nothing', async () => {
  const sub = subscription({ id: 'sub_test_1', status: 'incomplete' });
  const session = checkoutSession({ id: SESSION_ID, status: 'open' });
  const { stripe } = fakeStripe(sessionRoutes(sub, session));
  const db = fakeDb();
  const { status } = await json(await invoke('POST', checkoutSync, sessionRequest(SESSION_ID), makeDeps({ stripe, db })));
  assert.equal(status, 204);
  assert.equal(writes(db).length, 0);
});

test('a session from the other Stripe mode is ignored', async () => {
  const sub = subscription({ id: 'sub_test_1' });
  const session = { ...checkoutSession({ id: SESSION_ID }), livemode: true };
  const { stripe, calls } = fakeStripe(sessionRoutes(sub, session));
  const db = fakeDb();
  const { status } = await json(await invoke('POST', checkoutSync, sessionRequest(SESSION_ID), makeDeps({ stripe, db })));
  assert.equal(status, 204);
  assert.equal(calls.length, 1, 'only the session retrieval');
  assert.equal(writes(db).length, 0);
});

test('a subscription on another price does not touch Uncloud rows', async () => {
  const sub = subscription({ id: 'sub_test_1', lookupKey: 'pageready_other', product: 'prod_other' });
  const { stripe } = fakeStripe(sessionRoutes(sub));
  const db = fakeDb();
  await invoke('POST', checkoutSync, sessionRequest(SESSION_ID), makeDeps({ stripe, db }));
  assert.equal(writes(db).length, 0);
});

// ---- syncCheckoutSession / applySubscription -------------------------------

test('the customer upsert carries the Checkout user and live flag', async () => {
  const sub = subscription({ id: 'sub_test_1' });
  const { stripe } = fakeStripe({ [`GET /v1/subscriptions/sub_test_1`]: () => sub });
  const db = fakeDb();
  const deps = makeDeps({ stripe, db });
  const result = await syncCheckoutSession(deps, checkoutSession({ id: SESSION_ID, customer: 'cus_abc' }));
  assert.equal(result, 'applied');
  const upsert = db.calls.find((c) => c.op === 'upsert');
  assert.deepEqual(upsert.row, { user_id: USER_A, stripe_customer_id: 'cus_abc', livemode: false });
  assert.deepEqual(upsert.mode, { service: true });
});

// Two live subscriptions for one user: keep the newer, cancel the older and refund its latest payment.

test('duplicate: the older subscription is replaced and its latest payment refunded', async () => {
  const older = subscription({ id: 'sub_old', created: NOW_SECONDS - 10 * DAY, latestInvoice: 'in_old' });
  const newer = subscription({ id: 'sub_new', created: NOW_SECONDS - 1 * DAY });
  const { stripe, calls } = fakeStripe({
    'GET /v1/subscriptions/sub_old': () => older,
    'DELETE /v1/subscriptions/sub_old': () => ({ ...older, status: 'canceled' }),
    'GET /v1/invoices/in_old': () => ({ id: 'in_old', charge: 'ch_old', amount_paid: 999 }),
    'POST /v1/refunds': () => ({ id: 're_1' }),
  });
  const db = fakeDb({
    entitlements: [{ user_id: USER_A, plan: 'plus', status: 'active', current_period_end: '2027-10-18T09:41:00Z', cancel_at_period_end: false, stripe_subscription_id: 'sub_old', livemode: false }],
  });
  const result = await applySubscription(makeDeps({ stripe, db }), newer);
  assert.equal(result, 'duplicate_replaced');

  const cancel = stripeCalls(calls, 'DELETE', '/v1/subscriptions/sub_old')[0];
  assert.equal(cancel.idempotencyKey, 'dup-cancel-sub_old');
  const refund = stripeCalls(calls, 'POST', '/v1/refunds')[0];
  assert.equal(refund.body.get('charge'), 'ch_old');
  assert.equal(refund.idempotencyKey, 'dup-refund-sub_old');
  assert.equal(db.tables.entitlements[0].stripe_subscription_id, 'sub_new');
});

test('duplicate: an older incoming subscription is cancelled and the newer one stays', async () => {
  const newer = subscription({ id: 'sub_new', created: NOW_SECONDS - 1 * DAY });
  const older = subscription({ id: 'sub_old', created: NOW_SECONDS - 10 * DAY, latestInvoice: 'in_old' });
  const { stripe, calls } = fakeStripe({
    'GET /v1/subscriptions/sub_new': () => newer,
    'GET /v1/subscriptions/sub_old': () => older,
    'DELETE /v1/subscriptions/sub_old': () => ({ ...older, status: 'canceled' }),
    'GET /v1/invoices/in_old': () => ({ id: 'in_old', charge: 'ch_old', amount_paid: 999 }),
    'POST /v1/refunds': () => ({ id: 're_1' }),
  });
  const db = fakeDb({
    entitlements: [{ user_id: USER_A, plan: 'plus', status: 'active', current_period_end: '2027-10-18T09:41:00Z', cancel_at_period_end: false, stripe_subscription_id: 'sub_new', livemode: false }],
  });
  const result = await applySubscription(makeDeps({ stripe, db }), older);
  assert.equal(result, 'duplicate_cancelled');
  assert.equal(stripeCalls(calls, 'DELETE', '/v1/subscriptions/sub_old').length, 1);
  assert.equal(db.tables.entitlements[0].stripe_subscription_id, 'sub_new', 'the live row is untouched');
});

test('a canceled old subscription cannot overwrite a live one', async () => {
  const { stripe } = fakeStripe({});
  const db = fakeDb({
    entitlements: [{ user_id: USER_A, plan: 'plus', status: 'active', current_period_end: '2027-10-18T09:41:00Z', cancel_at_period_end: false, stripe_subscription_id: 'sub_new', livemode: false }],
  });
  const old = subscription({ id: 'sub_old', status: 'canceled', created: NOW_SECONDS - 10 * DAY });
  const result = await applySubscription(makeDeps({ stripe, db }), old);
  assert.equal(result, 'stale_ignored');
  assert.equal(writes(db).filter((c) => c.name === 'apply_subscription').length, 0);
});

test('a user is resolved from the customers table when the subscription has no metadata', async () => {
  const sub = subscription({ id: 'sub_test_1', userId: null, customer: 'cus_known' });
  const { stripe } = fakeStripe({});
  const db = fakeDb({ customers: [{ user_id: USER_A, stripe_customer_id: 'cus_known', livemode: false }] });
  const result = await applySubscription(makeDeps({ stripe, db }), sub);
  assert.equal(result, 'applied');
  assert.equal(db.tables.entitlements[0].user_id, USER_A);
});

test('a subscription that cannot be tied to a user is ignored', async () => {
  const sub = subscription({ id: 'sub_test_1', userId: null, customer: 'cus_unknown' });
  const db = fakeDb();
  assert.equal(await applySubscription(makeDeps({ db }), sub), 'ignored');
  assert.equal(writes(db).length, 0);
});

test('config is used for the price lookup key', async () => {
  const sub = subscription({ id: 'sub_test_1', lookupKey: 'uncloud_plus_next' });
  const db = fakeDb();
  const deps = makeDeps({ db, config: testConfig({ STRIPE_PRICE_LOOKUP_KEY: 'uncloud_plus_next' }) });
  assert.equal(await applySubscription(deps, sub), 'applied');
});
