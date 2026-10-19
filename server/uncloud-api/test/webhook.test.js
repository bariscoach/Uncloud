import { test } from 'node:test';
import assert from 'node:assert/strict';
import { webhook } from '../lib/handlers.js';
import {
  fakeStripe, fakeDb, makeDeps, invoke, json, subscription, checkoutSession, event, webhookRequest, USER_A, NOW_SECONDS,
} from './helpers.js';

const hook = (deps, req) => invoke('POST', webhook, req, deps);
const applied = (db) => db.calls.filter((c) => c.op === 'rpc' && c.name === 'apply_subscription');
const stripeCalls = (calls, method, path) => calls.filter((c) => c.method === method && c.path === path);

function subRoute(sub) {
  return { [`GET /v1/subscriptions/${sub.id}`]: () => sub };
}

test('a bad signature is 400 and writes nothing', async () => {
  const { stripe } = fakeStripe({});
  const db = fakeDb();
  const deps = makeDeps({ stripe, db });
  const req = webhookRequest(stripe, event('customer.subscription.updated', subscription()), { signature: 't=1,v1=deadbeef' });
  const { status, body } = await json(await hook(deps, req));
  assert.equal(status, 400);
  assert.equal(body.error.code, 'bad_request');
  assert.equal(db.calls.length, 0);
});

test('a missing signature header is 400', async () => {
  const { stripe } = fakeStripe({});
  const req = new Request('https://uncloud-api.vercel.app/v1/stripe/webhook', { method: 'POST', body: '{}' });
  const { status } = await json(await hook(makeDeps({ stripe }), req));
  assert.equal(status, 400);
});

test('an event from the other Stripe mode is acknowledged and ignored', async () => {
  const sub = subscription({ id: 'sub_test_1' });
  const { stripe, calls } = fakeStripe(subRoute(sub));
  const db = fakeDb();
  const evt = event('customer.subscription.updated', sub, { livemode: true });
  const { status, body } = await json(await hook(makeDeps({ stripe, db }), webhookRequest(stripe, evt)));
  assert.equal(status, 200);
  assert.deepEqual(body, { received: true });
  assert.equal(calls.length, 0);
  assert.equal(db.calls.length, 0);
});

test('an event applied once is acknowledged again without side effects', async () => {
  const sub = subscription({ id: 'sub_test_1' });
  const { stripe, calls } = fakeStripe(subRoute(sub));
  const db = fakeDb();
  const deps = makeDeps({ stripe, db });
  const evt = event('customer.subscription.updated', sub, { id: 'evt_dup' });

  assert.equal((await json(await hook(deps, webhookRequest(stripe, evt)))).status, 200);
  const callsAfterFirst = calls.length;
  assert.equal(applied(db).length, 1);

  const second = await json(await hook(deps, webhookRequest(stripe, evt)));
  assert.equal(second.status, 200);
  assert.equal(applied(db).length, 1, 'applied once');
  assert.equal(calls.length, callsAfterFirst, 'no second Stripe call');
  assert.equal(db.tables.stripe_events.filter((r) => r.id === 'evt_dup').length, 1);
});

test('checkout.session.completed routes to the checkout sync and records the event', async () => {
  const sub = subscription({ id: 'sub_test_1' });
  const session = checkoutSession({ id: 'cs_test_a1b2c3d4e5f6', subscriptionId: 'sub_test_1' });
  const { stripe } = fakeStripe(subRoute(sub));
  const db = fakeDb();
  const evt = event('checkout.session.completed', session, { id: 'evt_cs' });
  const { status } = await json(await hook(makeDeps({ stripe, db }), webhookRequest(stripe, evt)));
  assert.equal(status, 200);
  assert.equal(db.tables.entitlements[0].status, 'active');
  const row = db.tables.stripe_events[0];
  assert.equal(row.id, 'evt_cs');
  assert.equal(row.type, 'checkout.session.completed');
  assert.equal(row.livemode, false);
});

test('customer.subscription.updated and deleted re-fetch and apply Stripe\'s current state', async () => {
  // The event says active, but Stripe now says canceled: the re-fetch wins.
  const current = subscription({ id: 'sub_test_1', status: 'canceled' });
  const { stripe, calls } = fakeStripe(subRoute(current));
  const db = fakeDb();
  const stale = subscription({ id: 'sub_test_1', status: 'active' });
  const evt = event('customer.subscription.updated', stale, { id: 'evt_order' });
  await hook(makeDeps({ stripe, db }), webhookRequest(stripe, evt));
  assert.equal(stripeCalls(calls, 'GET', '/v1/subscriptions/sub_test_1').length, 1);
  const row = db.tables.entitlements[0];
  assert.equal(row.plan, 'free');
  assert.equal(row.status, 'expired');
});

test('customer.subscription.deleted maps to expired', async () => {
  const canceled = subscription({ id: 'sub_test_1', status: 'canceled' });
  const { stripe } = fakeStripe(subRoute(canceled));
  const db = fakeDb();
  const evt = event('customer.subscription.deleted', canceled, { id: 'evt_del' });
  const { status } = await json(await hook(makeDeps({ stripe, db }), webhookRequest(stripe, evt)));
  assert.equal(status, 200);
  assert.equal(db.tables.entitlements[0].status, 'expired');
});

test('invoice.paid moves the period end (basil location of the subscription id)', async () => {
  const sub = subscription({ id: 'sub_test_1', periodEnd: NOW_SECONDS + 730 * 24 * 60 * 60 });
  const { stripe } = fakeStripe(subRoute(sub));
  const db = fakeDb();
  const invoice = { id: 'in_1', parent: { type: 'subscription_details', subscription_details: { subscription: 'sub_test_1' } } };
  await hook(makeDeps({ stripe, db }), webhookRequest(stripe, event('invoice.paid', invoice, { id: 'evt_paid' })));
  assert.equal(db.tables.entitlements[0].stripe_subscription_id, 'sub_test_1');
  assert.ok(db.tables.entitlements[0].current_period_end > '2027-10-18');
});

test('invoice.paid also reads the older invoice.subscription location', async () => {
  const sub = subscription({ id: 'sub_test_1', basil: false });
  const { stripe } = fakeStripe(subRoute(sub));
  const db = fakeDb();
  const invoice = { id: 'in_2', subscription: 'sub_test_1' };
  const { status } = await json(await hook(makeDeps({ stripe, db }), webhookRequest(stripe, event('invoice.paid', invoice, { id: 'evt_old' }))));
  assert.equal(status, 200);
  assert.equal(db.tables.entitlements[0].status, 'active');
});

test('invoice.payment_failed moves the plan to pastDue', async () => {
  const sub = subscription({ id: 'sub_test_1', status: 'past_due' });
  const { stripe } = fakeStripe(subRoute(sub));
  const db = fakeDb();
  const invoice = { id: 'in_3', parent: { subscription_details: { subscription: 'sub_test_1' } } };
  await hook(makeDeps({ stripe, db }), webhookRequest(stripe, event('invoice.payment_failed', invoice, { id: 'evt_fail' })));
  assert.equal(db.tables.entitlements[0].status, 'pastDue');
  assert.equal(db.tables.entitlements[0].plan, 'plus');
});

test('a full refund cancels the subscription now, keyed by the charge', async () => {
  const canceled = subscription({ id: 'sub_test_1', status: 'canceled' });
  const { stripe, calls } = fakeStripe({
    'DELETE /v1/subscriptions/sub_test_1': () => canceled,
    ...subRoute(canceled),
  });
  const db = fakeDb({
    customers: [{ user_id: USER_A, stripe_customer_id: 'cus_test_1', livemode: false }],
    entitlements: [{ user_id: USER_A, plan: 'plus', status: 'active', current_period_end: '2027-10-18T09:41:00Z', cancel_at_period_end: false, stripe_subscription_id: 'sub_test_1', livemode: false }],
  });
  const charge = { id: 'ch_refund', object: 'charge', customer: 'cus_test_1', refunded: true };
  const { status } = await json(await hook(makeDeps({ stripe, db }), webhookRequest(stripe, event('charge.refunded', charge, { id: 'evt_refund' }))));
  assert.equal(status, 200);
  const cancel = stripeCalls(calls, 'DELETE', '/v1/subscriptions/sub_test_1')[0];
  assert.equal(cancel.idempotencyKey, 'refund-ch_refund');
  assert.equal(db.tables.entitlements[0].status, 'expired');
});

test('a partial refund changes nothing', async () => {
  const { stripe, calls } = fakeStripe({});
  const db = fakeDb({
    customers: [{ user_id: USER_A, stripe_customer_id: 'cus_test_1', livemode: false }],
    entitlements: [{ user_id: USER_A, plan: 'plus', status: 'active', stripe_subscription_id: 'sub_test_1', livemode: false }],
  });
  const charge = { id: 'ch_partial', object: 'charge', customer: 'cus_test_1', refunded: false, amount_refunded: 100 };
  const { status } = await json(await hook(makeDeps({ stripe, db }), webhookRequest(stripe, event('charge.refunded', charge, { id: 'evt_partial' }))));
  assert.equal(status, 200);
  assert.equal(calls.length, 0);
  assert.equal(db.tables.entitlements[0].status, 'active');
});

test('an unknown event type is acknowledged and recorded', async () => {
  const { stripe, calls } = fakeStripe({});
  const db = fakeDb();
  const { status } = await json(await hook(makeDeps({ stripe, db }), webhookRequest(stripe, event('product.updated', { id: 'prod_x' }, { id: 'evt_other' }))));
  assert.equal(status, 200);
  assert.equal(calls.length, 0);
  assert.equal(db.tables.stripe_events[0].type, 'product.updated');
});

test('a processing failure is 500 and records no event, so Stripe retries', async () => {
  const sub = subscription({ id: 'sub_test_1' });
  const { stripe } = fakeStripe({
    'GET /v1/subscriptions/sub_test_1': () => { throw { status: 500, error: { type: 'api_error', message: 'upstream' } }; },
  });
  const db = fakeDb();
  const evt = event('customer.subscription.updated', sub, { id: 'evt_fail_proc' });
  const { status, body } = await json(await hook(makeDeps({ stripe, db }), webhookRequest(stripe, evt)));
  assert.equal(status, 500);
  assert.equal(body.error.code, 'server_error');
  assert.equal(db.tables.stripe_events.length, 0);
});

test('a non-POST request is a JSON 405', async () => {
  const { stripe } = fakeStripe({});
  const req = new Request('https://uncloud-api.vercel.app/v1/stripe/webhook', { method: 'GET' });
  const response = await invoke('POST', webhook, req, makeDeps({ stripe }));
  assert.equal(response.status, 405);
  assert.equal(response.headers.get('allow'), 'POST');
});
