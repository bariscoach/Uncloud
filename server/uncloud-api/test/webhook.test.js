import { test } from 'node:test';
import assert from 'node:assert/strict';
import { webhook } from '../lib/handlers.js';
import {
  fakeStripe, fakeDb, makeDeps, invoke, json, subscription, checkoutSession, event, webhookRequest, invoice, invoicePayment, USER_A, NOW_SECONDS,
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

test('invoice.paid moves the period end (subscription id under parent.subscription_details)', async () => {
  const sub = subscription({ id: 'sub_test_1', periodEnd: NOW_SECONDS + 730 * 24 * 60 * 60 });
  const { stripe } = fakeStripe(subRoute(sub));
  const db = fakeDb();
  const invoice = { id: 'in_1', parent: { type: 'subscription_details', subscription_details: { subscription: 'sub_test_1' } } };
  await hook(makeDeps({ stripe, db }), webhookRequest(stripe, event('invoice.paid', invoice, { id: 'evt_paid' })));
  assert.equal(db.tables.entitlements[0].stripe_subscription_id, 'sub_test_1');
  assert.ok(db.tables.entitlements[0].current_period_end > '2027-10-18');
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

// Refund fixtures in the pinned shape: the charge names its PaymentIntent, and the PaymentIntent's
// invoice payment names the invoice (review H2).
function refundRoutes({ sub, invoiceId = 'in_test_1', subscriptionOfInvoice = 'sub_test_1', refunds = [] }) {
  return {
    ...subRoute(sub),
    'GET /v1/invoice_payments': () => ({ object: 'list', data: [invoicePayment({ invoiceId, paymentIntent: 'pi_refund' })] }),
    [`GET /v1/invoices/${invoiceId}`]: () => invoice({ id: invoiceId, subscriptionId: subscriptionOfInvoice }),
    'GET /v1/refunds': () => ({ object: 'list', data: refunds }),
  };
}
const refundCharge = { id: 'ch_refund', object: 'charge', customer: 'cus_test_1', refunded: true, payment_intent: 'pi_refund' };
const activeRowFor = (subId = 'sub_test_1') => ({
  user_id: USER_A, plan: 'plus', status: 'active', current_period_end: '2027-10-18T09:41:00Z',
  cancel_at_period_end: false, stripe_subscription_id: subId, livemode: false,
});
const customerRow = { user_id: USER_A, stripe_customer_id: 'cus_test_1', livemode: false };

test('a full refund of the current subscription invoice cancels the subscription now, keyed by the charge', async () => {
  // Stateful: the cancel changes what the follow-up read returns, as Stripe does.
  const state = subscription({ id: 'sub_test_1', status: 'active', latestInvoice: 'in_test_1' });
  const { stripe, calls } = fakeStripe({
    ...refundRoutes({ sub: state }),
    'GET /v1/subscriptions/sub_test_1': () => state,
    'DELETE /v1/subscriptions/sub_test_1': () => { state.status = 'canceled'; return state; },
  });
  const db = fakeDb({ customers: [customerRow], entitlements: [activeRowFor()] });
  const { status } = await json(await hook(makeDeps({ stripe, db }), webhookRequest(stripe, event('charge.refunded', refundCharge, { id: 'evt_refund' }))));
  assert.equal(status, 200);
  const cancel = stripeCalls(calls, 'DELETE', '/v1/subscriptions/sub_test_1')[0];
  assert.equal(cancel.idempotencyKey, 'refund-ch_refund');
  assert.equal(db.tables.entitlements[0].status, 'expired');
});

test('review H2: the refund of a duplicate we cancelled does not cancel the kept subscription', async () => {
  // Duplicate resolution refunded the cancelled subscription's payment with metadata uncloud_reason=duplicate.
  const kept = subscription({ id: 'sub_test_1', status: 'active', latestInvoice: 'in_test_1' });
  const duplicateRefund = { id: 're_dup', object: 'refund', charge: 'ch_refund', metadata: { uncloud_reason: 'duplicate', subscription: 'sub_old' } };
  const { stripe, calls } = fakeStripe(refundRoutes({ sub: kept, refunds: [duplicateRefund] }));
  const db = fakeDb({ customers: [customerRow], entitlements: [activeRowFor('sub_test_1')] });
  const { status } = await json(await hook(makeDeps({ stripe, db }), webhookRequest(stripe, event('charge.refunded', refundCharge, { id: 'evt_dup_refund' }))));
  assert.equal(status, 200);
  assert.equal(stripeCalls(calls, 'DELETE', '/v1/subscriptions/sub_test_1').length, 0);
  assert.equal(db.tables.entitlements[0].status, 'active');
  assert.equal(db.tables.stripe_events[0].id, 'evt_dup_refund', 'the event is still recorded');
});

test('review H2: a refund of an older invoice on the customer cancels nothing', async () => {
  // The owner refunds last year's renewal from the Dashboard. The current subscription must stay.
  const current = subscription({ id: 'sub_test_1', status: 'active', latestInvoice: 'in_this_year' });
  const { stripe, calls } = fakeStripe(refundRoutes({ sub: current, invoiceId: 'in_last_year', subscriptionOfInvoice: 'sub_test_1' }));
  const db = fakeDb({ customers: [customerRow], entitlements: [activeRowFor('sub_test_1')] });
  const { status } = await json(await hook(makeDeps({ stripe, db }), webhookRequest(stripe, event('charge.refunded', refundCharge, { id: 'evt_old_inv' }))));
  assert.equal(status, 200);
  assert.equal(stripeCalls(calls, 'DELETE', '/v1/subscriptions/sub_test_1').length, 0);
  assert.equal(db.tables.entitlements[0].status, 'active');
});

test('review H2: a refund of another subscription\'s invoice cancels nothing, even for the same customer', async () => {
  const current = subscription({ id: 'sub_test_1', status: 'active', latestInvoice: 'in_test_1' });
  const { stripe, calls } = fakeStripe(refundRoutes({ sub: current, invoiceId: 'in_other', subscriptionOfInvoice: 'sub_other' }));
  const db = fakeDb({ customers: [customerRow], entitlements: [activeRowFor('sub_test_1')] });
  await hook(makeDeps({ stripe, db }), webhookRequest(stripe, event('charge.refunded', refundCharge, { id: 'evt_other_sub' })));
  assert.equal(stripeCalls(calls, 'DELETE', '/v1/subscriptions/sub_test_1').length, 0);
  assert.equal(db.tables.entitlements[0].status, 'active');
});

test('review H2: a refunded charge that is not the subscription\'s latest invoice cancels nothing', async () => {
  // The subscription's invoice is the same subscription, but a newer one exists (for example a renewal already billed).
  const current = subscription({ id: 'sub_test_1', status: 'active', latestInvoice: 'in_newer' });
  const { stripe, calls } = fakeStripe(refundRoutes({ sub: current, invoiceId: 'in_test_1', subscriptionOfInvoice: 'sub_test_1' }));
  const db = fakeDb({ customers: [customerRow], entitlements: [activeRowFor('sub_test_1')] });
  await hook(makeDeps({ stripe, db }), webhookRequest(stripe, event('charge.refunded', refundCharge, { id: 'evt_not_latest' })));
  assert.equal(stripeCalls(calls, 'DELETE', '/v1/subscriptions/sub_test_1').length, 0);
});
