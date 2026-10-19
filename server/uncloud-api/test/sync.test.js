import { test } from 'node:test';
import assert from 'node:assert/strict';
import { checkoutSync } from '../lib/handlers.js';
import { applySubscription, syncCheckoutSession } from '../lib/sync.js';
import { DbError } from '../lib/supabase.js';
import {
  fakeStripe, fakeDb, makeDeps, invoke, json, subscription, checkoutSession, invoice, invoicePayment, USER_A, NOW_SECONDS, DAY, testConfig,
} from './helpers.js';

const SESSION_ID = 'cs_test_a1b2c3d4e5f6';

const sessionRequest = (sessionId, headers = {}) =>
  new Request('https://uncloud-api.vercel.app/v1/checkout/sync', {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...headers },
    body: JSON.stringify({ sessionId }),
  });

const writes = (db) => db.calls.filter((c) => c.op === 'upsert' || (c.op === 'rpc' && c.name === 'apply_subscription'));
const stripeCalls = (calls, method, path) => calls.filter((c) => c.method === method && c.path === path);
const liveRow = (overrides = {}) => ({
  user_id: USER_A, plan: 'plus', status: 'active', current_period_end: '2027-10-18T09:41:00Z',
  cancel_at_period_end: false, stripe_subscription_id: 'sub_old', livemode: false, ...overrides,
});

// A subscription whose state changes with each update, as Stripe's does. Returns the routes and the
// live state object (so a test can read what Stripe would now say).
function statefulSubscription(sub, session = checkoutSession({ id: SESSION_ID })) {
  const state = structuredClone(sub);
  return {
    state,
    routes: {
      [`GET /v1/checkout/sessions/${session.id}`]: () => session,
      [`GET /v1/subscriptions/${sub.id}`]: () => structuredClone(state),
      [`POST /v1/subscriptions/${sub.id}`]: ({ body }) => {
        if (body.has('cancel_at_period_end')) state.cancel_at_period_end = body.get('cancel_at_period_end') === 'true';
        if (body.has('metadata[one_year_applied]')) {
          state.metadata = { ...state.metadata, one_year_applied: body.get('metadata[one_year_applied]') };
        }
        return structuredClone(state);
      },
    },
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
  const { stripe } = fakeStripe(statefulSubscription(sub).routes);
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

test('one-year choice sets cancel_at_period_end and records the session in the subscription metadata', async () => {
  const sub = subscription({ id: 'sub_test_1', status: 'active' });
  const session = checkoutSession({ id: SESSION_ID, renewal: 'oneYear' });
  const fake = statefulSubscription(sub, session);
  const { stripe, calls } = fakeStripe(fake.routes);
  const db = fakeDb();
  await invoke('POST', checkoutSync, sessionRequest(SESSION_ID), makeDeps({ stripe, db }));

  const update = stripeCalls(calls, 'POST', '/v1/subscriptions/sub_test_1')[0];
  assert.equal(update.body.get('cancel_at_period_end'), 'true');
  assert.equal(update.body.get('metadata[one_year_applied]'), SESSION_ID);
  assert.equal(update.idempotencyKey, `one-year-${SESSION_ID}`);
  const entitlement = db.tables.entitlements.find((r) => r.user_id === USER_A);
  assert.equal(entitlement.cancel_at_period_end, true);
});

test('review M2: a reload of the success page does not turn renewal off again', async () => {
  const sub = subscription({ id: 'sub_test_1', status: 'active' });
  const session = checkoutSession({ id: SESSION_ID, renewal: 'oneYear' });
  const fake = statefulSubscription(sub, session);
  const { stripe, calls } = fakeStripe(fake.routes);
  const db = fakeDb();
  const deps = makeDeps({ stripe, db });

  await invoke('POST', checkoutSync, sessionRequest(SESSION_ID), deps);
  // The user turns renewal back on in Settings (the renewal route changes only cancel_at_period_end).
  fake.state.cancel_at_period_end = false;
  await invoke('POST', checkoutSync, sessionRequest(SESSION_ID), deps);
  await invoke('POST', checkoutSync, sessionRequest(SESSION_ID), deps);

  assert.equal(stripeCalls(calls, 'POST', '/v1/subscriptions/sub_test_1').length, 1, 'applied once');
  assert.equal(fake.state.cancel_at_period_end, false, 'the user choice stands');
  assert.equal(db.tables.entitlements.find((r) => r.user_id === USER_A).cancel_at_period_end, false);
});

test('review M2: the stored flag comes from a fresh read, not from the update response', async () => {
  // The update response says cancel_at_period_end=true, but the subscription as read back is false
  // (for example, the response was an idempotent replay of an earlier request).
  const sub = subscription({ id: 'sub_test_1', status: 'active' });
  const session = checkoutSession({ id: SESSION_ID, renewal: 'oneYear' });
  const { stripe } = fakeStripe({
    ...statefulSubscription(sub, session).routes,
    [`GET /v1/subscriptions/sub_test_1`]: () => ({ ...sub, cancel_at_period_end: false }),
    [`POST /v1/subscriptions/sub_test_1`]: () => ({ ...sub, cancel_at_period_end: true }),
  });
  const db = fakeDb();
  await invoke('POST', checkoutSync, sessionRequest(SESSION_ID), makeDeps({ stripe, db }));
  assert.equal(db.tables.entitlements.find((r) => r.user_id === USER_A).cancel_at_period_end, false);
});

test('an incomplete session writes nothing', async () => {
  const sub = subscription({ id: 'sub_test_1', status: 'incomplete' });
  const session = checkoutSession({ id: SESSION_ID, status: 'open' });
  const { stripe } = fakeStripe(statefulSubscription(sub, session).routes);
  const db = fakeDb();
  const { status } = await json(await invoke('POST', checkoutSync, sessionRequest(SESSION_ID), makeDeps({ stripe, db })));
  assert.equal(status, 204);
  assert.equal(writes(db).length, 0);
});

test('a session from the other Stripe mode is ignored', async () => {
  const sub = subscription({ id: 'sub_test_1' });
  const session = { ...checkoutSession({ id: SESSION_ID }), livemode: true };
  const { stripe, calls } = fakeStripe(statefulSubscription(sub, session).routes);
  const db = fakeDb();
  const { status } = await json(await invoke('POST', checkoutSync, sessionRequest(SESSION_ID), makeDeps({ stripe, db })));
  assert.equal(status, 204);
  assert.equal(calls.length, 1, 'only the session retrieval');
  assert.equal(writes(db).length, 0);
});

test('a subscription on another price does not touch Uncloud rows', async () => {
  const sub = subscription({ id: 'sub_test_1', lookupKey: 'pageready_other', product: 'prod_other' });
  const { stripe } = fakeStripe(statefulSubscription(sub).routes);
  const db = fakeDb();
  await invoke('POST', checkoutSync, sessionRequest(SESSION_ID), makeDeps({ stripe, db }));
  assert.equal(writes(db).length, 0);
});

test('review M6: the sync endpoint is limited per address, with no Stripe call once over the limit', async () => {
  const sub = subscription({ id: 'sub_test_1', status: 'active' });
  const { stripe, calls } = fakeStripe(statefulSubscription(sub).routes);
  const deps = makeDeps({ stripe, db: fakeDb() });
  const from = (ip) => ({ 'x-real-ip': ip });

  for (let i = 0; i < 30; i += 1) {
    assert.equal((await json(await invoke('POST', checkoutSync, sessionRequest(SESSION_ID, from('203.0.113.7')), deps))).status, 204);
  }
  const callsBefore = calls.length;
  const limited = await json(await invoke('POST', checkoutSync, sessionRequest(SESSION_ID, from('203.0.113.7')), deps));
  assert.equal(limited.status, 429);
  assert.equal(limited.body.error.code, 'rate_limited');
  assert.equal(calls.length, callsBefore, 'no Stripe call while limited');

  // Another address has its own allowance.
  assert.equal((await json(await invoke('POST', checkoutSync, sessionRequest(SESSION_ID, from('198.51.100.9')), deps))).status, 204);
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
// The fixtures use the pinned shape: the invoice has no charge field, and its payment is found through
// Invoice Payments (review H1).

function duplicateRoutes({ older, newer, olderInvoice = invoice({ id: 'in_old', subscriptionId: 'sub_old', paidSecondsAgo: 60 }) }) {
  return {
    'GET /v1/subscriptions/sub_old': () => older,
    'GET /v1/subscriptions/sub_new': () => newer,
    'DELETE /v1/subscriptions/sub_old': () => ({ ...older, status: 'canceled' }),
    'DELETE /v1/subscriptions/sub_new': () => ({ ...newer, status: 'canceled' }),
    'GET /v1/invoices/in_old': () => olderInvoice,
    'GET /v1/invoice_payments': () => ({ object: 'list', data: [invoicePayment({ invoiceId: 'in_old', paymentIntent: 'pi_old' })] }),
    'POST /v1/refunds': () => ({ id: 're_1', object: 'refund' }),
  };
}

test('duplicate: the older subscription is replaced and its latest payment refunded by PaymentIntent', async () => {
  const older = subscription({ id: 'sub_old', created: NOW_SECONDS - 10 * DAY, latestInvoice: 'in_old' });
  const newer = subscription({ id: 'sub_new', created: NOW_SECONDS - 1 * DAY });
  const { stripe, calls } = fakeStripe(duplicateRoutes({ older, newer }));
  const db = fakeDb({ entitlements: [liveRow()] });
  const result = await applySubscription(makeDeps({ stripe, db }), newer);
  assert.equal(result, 'duplicate_replaced');

  const cancel = stripeCalls(calls, 'DELETE', '/v1/subscriptions/sub_old')[0];
  assert.equal(cancel.idempotencyKey, 'dup-cancel-sub_old');
  const refund = stripeCalls(calls, 'POST', '/v1/refunds')[0];
  assert.equal(refund.body.get('payment_intent'), 'pi_old');
  assert.equal(refund.body.get('charge'), null);
  assert.equal(refund.body.get('metadata[uncloud_reason]'), 'duplicate');
  assert.equal(refund.body.get('metadata[subscription]'), 'sub_old');
  assert.equal(refund.idempotencyKey, 'dup-refund-sub_old');
  assert.equal(db.tables.entitlements[0].stripe_subscription_id, 'sub_new');
});

test('duplicate: an older incoming subscription is cancelled and the newer one stays', async () => {
  const newer = subscription({ id: 'sub_new', created: NOW_SECONDS - 1 * DAY });
  const older = subscription({ id: 'sub_old', created: NOW_SECONDS - 10 * DAY, latestInvoice: 'in_old' });
  const { stripe, calls } = fakeStripe(duplicateRoutes({ older, newer }));
  const db = fakeDb({ entitlements: [liveRow({ stripe_subscription_id: 'sub_new' })] });
  const result = await applySubscription(makeDeps({ stripe, db }), older);
  assert.equal(result, 'duplicate_cancelled');
  assert.equal(stripeCalls(calls, 'DELETE', '/v1/subscriptions/sub_old').length, 1);
  assert.equal(stripeCalls(calls, 'POST', '/v1/refunds')[0].body.get('payment_intent'), 'pi_old');
  assert.equal(db.tables.entitlements[0].stripe_subscription_id, 'sub_new', 'the live row is untouched');
});

test('review H3: a duplicate whose latest payment is old is cancelled but not refunded', async () => {
  const older = subscription({ id: 'sub_old', created: NOW_SECONDS - 10 * DAY, latestInvoice: 'in_old' });
  const newer = subscription({ id: 'sub_new', created: NOW_SECONDS - 1 * DAY });
  const oldInvoice = invoice({ id: 'in_old', subscriptionId: 'sub_old', paidSecondsAgo: 5 * DAY });
  const { stripe, calls } = fakeStripe(duplicateRoutes({ older, newer, olderInvoice: oldInvoice }));
  const db = fakeDb({ entitlements: [liveRow()] });
  const result = await applySubscription(makeDeps({ stripe, db }), newer);
  assert.equal(result, 'duplicate_replaced');
  assert.equal(stripeCalls(calls, 'DELETE', '/v1/subscriptions/sub_old').length, 1);
  assert.equal(stripeCalls(calls, 'POST', '/v1/refunds').length, 0, 'an old period is never refunded');
});

test('review H3: a row that still says live, over a subscription Stripe has ended, refunds nothing', async () => {
  // A one-year plan ended, but its deletion event was late, so the row still says active.
  const ended = subscription({ id: 'sub_old', status: 'canceled', created: NOW_SECONDS - 400 * DAY, latestInvoice: 'in_old' });
  const fresh = subscription({ id: 'sub_new', status: 'active', created: NOW_SECONDS - 1 * DAY });
  const oldInvoice = invoice({ id: 'in_old', subscriptionId: 'sub_old', paidSecondsAgo: 365 * DAY });
  const { stripe, calls } = fakeStripe({
    ...duplicateRoutes({ older: ended, newer: fresh, olderInvoice: oldInvoice }),
    'GET /v1/subscriptions/sub_old': () => ended,
  });
  const db = fakeDb({ entitlements: [liveRow()] });
  const result = await applySubscription(makeDeps({ stripe, db }), fresh);
  assert.equal(result, 'applied');
  assert.equal(stripeCalls(calls, 'POST', '/v1/refunds').length, 0, 'the used year is not refunded');
  assert.equal(stripeCalls(calls, 'DELETE', '/v1/subscriptions/sub_old').length, 0);
  assert.equal(db.tables.entitlements[0].stripe_subscription_id, 'sub_new');
  assert.equal(db.tables.entitlements[0].status, 'active');
});

test('review H3: past_due counts as live for the duplicate check', async () => {
  const older = subscription({ id: 'sub_old', status: 'past_due', created: NOW_SECONDS - 10 * DAY, latestInvoice: 'in_old' });
  const newer = subscription({ id: 'sub_new', created: NOW_SECONDS - 1 * DAY });
  const { stripe, calls } = fakeStripe(duplicateRoutes({ older, newer }));
  const db = fakeDb({ entitlements: [liveRow()] });
  assert.equal(await applySubscription(makeDeps({ stripe, db }), newer), 'duplicate_replaced');
  assert.equal(stripeCalls(calls, 'POST', '/v1/refunds').length, 1);
});

test('a canceled old subscription cannot overwrite a live one', async () => {
  const live = subscription({ id: 'sub_new', created: NOW_SECONDS - 1 * DAY });
  const { stripe } = fakeStripe({ 'GET /v1/subscriptions/sub_new': () => live });
  const db = fakeDb({ entitlements: [liveRow({ stripe_subscription_id: 'sub_new' })] });
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

// ---- account deletion races (plan §4.3) -----------------------------------

test('a subscription event for a user deleted meanwhile is ignored, not an error (no Stripe retry)', async () => {
  const sub = subscription({ id: 'sub_test_1' });
  const db = fakeDb({ customers: [], entitlements: [] });
  const rpc = db.rpc;
  db.rpc = async (name, args, mode) => {
    if (name === 'apply_subscription') throw new DbError(409, 'rpc');
    return rpc(name, args, mode);
  };
  const result = await applySubscription(makeDeps({ stripe: fakeStripe().stripe, db }), sub);
  assert.equal(result, 'ignored');
});

test('a subscription whose metadata was scrubbed and whose customer row is gone is ignored (no_user)', async () => {
  const sub = subscription({ id: 'sub_test_1', userId: null, customer: 'cus_gone' });
  const db = fakeDb({ customers: [], entitlements: [] });
  const result = await applySubscription(makeDeps({ stripe: fakeStripe().stripe, db }), sub);
  assert.equal(result, 'ignored');
  assert.equal(db.calls.some((c) => c.op === 'rpc'), false);
});

test('a checkout that completes after the account was deleted cancels and refunds the new subscription', async () => {
  const sub = subscription({ id: 'sub_test_1', latestInvoice: 'in_test_1' });
  const state = structuredClone(sub);
  const { stripe, calls } = fakeStripe({
    'GET /v1/subscriptions/sub_test_1': () => structuredClone(state),
    'DELETE /v1/subscriptions/sub_test_1': () => { state.status = 'canceled'; return state; },
    'GET /v1/invoices/in_test_1': () => invoice({ id: 'in_test_1', subscriptionId: 'sub_test_1' }),
    'GET /v1/invoice_payments': () => ({ object: 'list', data: [invoicePayment({ invoiceId: 'in_test_1', paymentIntent: 'pi_new' })] }),
    'GET /v1/refunds': () => ({ object: 'list', data: [] }),
    'POST /v1/refunds': () => ({ id: 're_new', object: 'refund', status: 'succeeded' }),
  });
  const db = fakeDb({ customers: [], entitlements: [] });
  db.upsert = async () => { throw new DbError(409, 'upsert'); };
  const result = await syncCheckoutSession(makeDeps({ stripe, db }), checkoutSession({ id: SESSION_ID, userId: USER_A }));
  assert.equal(result, 'user_gone_refunded');
  const cancel = stripeCalls(calls, 'DELETE', '/v1/subscriptions/sub_test_1')[0];
  assert.equal(cancel.query.get('prorate'), 'false');
  const refund = stripeCalls(calls, 'POST', '/v1/refunds')[0];
  assert.equal(refund.body.get('payment_intent'), 'pi_new');
  assert.equal(refund.idempotencyKey, 'dup-refund-sub_test_1');
  assert.equal(db.calls.some((c) => c.op === 'rpc'), false, 'no entitlement is written for a deleted user');
});
