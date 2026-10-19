// POST /v1/account/delete (plan §4.1–4.2, §7.3). Stripe through the SDK with a fake fetch, the database
// through the fake in helpers.js. No network.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { deleteAccount } from '../lib/handlers.js';
import { setLogSink } from '../lib/http.js';
import { DbError } from '../lib/supabase.js';
import {
  fakeStripe, fakeDb, makeDeps, invoke, json, subscription, USER_A,
} from './helpers.js';
import { FAKE_RESTRICTED_TEST_KEY } from './fixtures/keys.js';

const CUSTOMER = 'cus_test_1';
const URL_PATH = 'https://uncloud-api.vercel.app/v1/account/delete';
const deleteRequest = (body, { token = true, email = 'name@example.com' } = {}) =>
  new Request(URL_PATH, {
    method: 'POST',
    headers: { ...(token ? { authorization: `Bearer ${USER_A}` } : {}), 'content-type': 'application/json' },
    body: typeof body === 'string' ? body : JSON.stringify(body ?? { confirmEmail: email }),
  });
const run = (deps, request) => invoke('POST', deleteAccount, request, deps);

const customerRow = { user_id: USER_A, stripe_customer_id: CUSTOMER, livemode: false };
const entitlementRow = { user_id: USER_A, plan: 'plus', status: 'active', current_period_end: '2027-10-18T09:41:00Z', cancel_at_period_end: false, stripe_subscription_id: 'sub_test_1', livemode: false };

// A fake Stripe for one customer. `open` maps a subscription id to the ids of its open invoices.
// `fail.cancel` makes the cancel call fail while it is true.
function world({ subs = [subscription()], open = {}, cards = ['pm_test_1'], missingCustomer = false } = {}) {
  const fail = { cancel: false };
  const routes = {
    'GET /v1/subscriptions': ({ query }) => {
      if (missingCustomer) {
        throw { status: 404, error: { type: 'invalid_request_error', code: 'resource_missing', param: 'customer', message: 'No such customer' } };
      }
      return { object: 'list', data: subs.filter((s) => s.customer === query.get('customer')).map((s) => structuredClone(s)) };
    },
    'GET /v1/invoices': ({ query }) => ({
      object: 'list',
      data: (open[query.get('subscription')] ?? []).map((id) => ({ id, object: 'invoice', status: 'open' })),
    }),
    'GET /v1/payment_methods': () => ({ object: 'list', data: cards.map((id) => ({ id, object: 'payment_method' })) }),
    [`POST /v1/customers/${CUSTOMER}`]: ({ body }) => ({ id: CUSTOMER, object: 'customer', metadata: Object.fromEntries(body) }),
  };
  for (const s of subs) {
    routes[`POST /v1/subscriptions/${s.id}`] = () => ({ ...s });
    routes[`DELETE /v1/subscriptions/${s.id}`] = () => {
      if (fail.cancel) throw { status: 500, error: { type: 'api_error', message: 'Stripe is down' } };
      return { ...s, status: 'canceled' };
    };
  }
  for (const ids of Object.values(open)) {
    for (const id of ids) routes[`POST /v1/invoices/${id}/void`] = () => ({ id, object: 'invoice', status: 'void' });
  }
  for (const id of cards) routes[`POST /v1/payment_methods/${id}/detach`] = () => ({ id, object: 'payment_method', customer: null });
  const { stripe, calls } = fakeStripe(routes);
  return { stripe, calls, fail };
}

const pathsOf = (calls) => calls.map((c) => `${c.method} ${c.path}`);
const stripeCall = (calls, method, path) => calls.find((c) => c.method === method && c.path === path);

function deps({ stripe, db = fakeDb({ customers: [customerRow], entitlements: [entitlementRow] }) } = {}) {
  return makeDeps({ stripe: stripe ?? fakeStripe().stripe, db });
}

// ---- request checks --------------------------------------------------------

test('without a token it is 401 and deletes nothing', async () => {
  const db = fakeDb({ customers: [customerRow] });
  const { status, body } = await json(await run(deps({ db }), deleteRequest({ confirmEmail: 'name@example.com' }, { token: false })));
  assert.equal(status, 401);
  assert.equal(body.error.code, 'unauthorized');
  assert.equal(db.calls.some((c) => c.op === 'deleteUser'), false);
});

test('a body that is not JSON or has no confirmEmail is 400 bad_request', async () => {
  const db = fakeDb({ customers: [customerRow] });
  for (const body of ['not json', { confirmEmail: 42 }, {}, []]) {
    const { status, body: out } = await json(await run(deps({ db }), deleteRequest(body)));
    assert.equal(status, 400, JSON.stringify(body));
    assert.equal(out.error.code, 'bad_request');
  }
  assert.equal(db.calls.some((c) => c.op === 'deleteUser'), false);
});

test('another address is confirmation_mismatch; case and surrounding spaces are ignored', async () => {
  const db = fakeDb({ entitlements: [] });
  const mismatch = await json(await run(deps({ db }), deleteRequest({ confirmEmail: 'other@example.com' })));
  assert.equal(mismatch.status, 400);
  assert.equal(mismatch.body.error.code, 'confirmation_mismatch');
  assert.equal(db.calls.some((c) => c.op === 'deleteUser'), false);

  const matched = await json(await run(deps({ db }), deleteRequest({ confirmEmail: '  Name@Example.com ' })));
  assert.equal(matched.status, 204);
});

test('the route refuses GET with a JSON 405', async () => {
  const response = await run(deps(), new Request(URL_PATH, { method: 'GET' }));
  assert.equal(response.status, 405);
  assert.equal((await response.json()).error.code, 'method_not_allowed');
});

// ---- the deletion ----------------------------------------------------------

test('no customer row: no Stripe call, the user is deleted, 204', async () => {
  const { stripe, calls } = world();
  const db = fakeDb({ entitlements: [] });
  const { status } = await json(await run(deps({ stripe, db }), deleteRequest({ confirmEmail: 'name@example.com' })));
  assert.equal(status, 204);
  assert.equal(calls.length, 0);
  assert.deepEqual(db.calls.filter((c) => c.op === 'deleteUser').map((c) => c.userId), [USER_A]);
});

test('an active Uncloud subscription is scrubbed, then cancelled with no proration, cards removed, customer scrubbed, user deleted', async () => {
  const { stripe, calls } = world({ cards: ['pm_test_1', 'pm_test_2'] });
  const db = fakeDb({ customers: [customerRow], entitlements: [entitlementRow] });
  const { status } = await json(await run(deps({ stripe, db }), deleteRequest({ confirmEmail: 'name@example.com' })));
  assert.equal(status, 204);

  const update = stripeCall(calls, 'POST', '/v1/subscriptions/sub_test_1');
  const cancel = stripeCall(calls, 'DELETE', '/v1/subscriptions/sub_test_1');
  assert.ok(pathsOf(calls).indexOf('POST /v1/subscriptions/sub_test_1') < pathsOf(calls).indexOf('DELETE /v1/subscriptions/sub_test_1'), 'scrub before cancel');
  assert.equal(update.body.get('metadata[user_id]'), '');
  assert.match(update.body.get('metadata[uncloud_account_deleted]'), /^2026-10-18T09:41:07Z$/);
  // DELETE carries its parameters in the query string.
  assert.equal(cancel.query.get('prorate'), 'false');
  assert.equal(cancel.query.get('invoice_now'), 'false');
  assert.equal(cancel.idempotencyKey, 'delete-sub_test_1');

  assert.ok(stripeCall(calls, 'POST', '/v1/payment_methods/pm_test_1/detach'));
  assert.ok(stripeCall(calls, 'POST', '/v1/payment_methods/pm_test_2/detach'));
  const customer = stripeCall(calls, 'POST', `/v1/customers/${CUSTOMER}`);
  assert.equal(customer.body.get('metadata[user_id]'), '');
  assert.equal(customer.body.has('email'), false, 'the customer keeps its email for receipts and tax records');

  assert.equal(db.tables.customers.length, 0);
  assert.equal(db.tables.entitlements.length, 0);
});

test('a past-due subscription has its open invoice voided', async () => {
  const subs = [subscription({ status: 'past_due' })];
  const { stripe, calls } = world({ subs, open: { sub_test_1: ['in_open_1'] } });
  const { status } = await json(await run(deps({ stripe }), deleteRequest({ confirmEmail: 'name@example.com' })));
  assert.equal(status, 204);
  assert.ok(stripeCall(calls, 'POST', '/v1/invoices/in_open_1/void'));
  assert.ok(stripeCall(calls, 'DELETE', '/v1/subscriptions/sub_test_1'));
});

test('a subscription on another product for the same customer is left alone', async () => {
  const foreign = subscription({ id: 'sub_other', lookupKey: 'pageready_monthly', product: 'prod_other', priceId: 'price_other' });
  const { stripe, calls } = world({ subs: [foreign, subscription()] });
  const { status } = await json(await run(deps({ stripe }), deleteRequest({ confirmEmail: 'name@example.com' })));
  assert.equal(status, 204);
  assert.equal(calls.filter((c) => c.path.includes('sub_other')).length, 0);
  assert.ok(stripeCall(calls, 'DELETE', '/v1/subscriptions/sub_test_1'));
});

test('an already cancelled Uncloud subscription gets no cancel call, but its open invoice is still voided', async () => {
  const old = subscription({ id: 'sub_old', status: 'canceled' });
  const { stripe, calls } = world({ subs: [old], open: { sub_old: ['in_old_1'] } });
  const { status } = await json(await run(deps({ stripe }), deleteRequest({ confirmEmail: 'name@example.com' })));
  assert.equal(status, 204);
  assert.equal(calls.filter((c) => c.method === 'DELETE' && c.path === '/v1/subscriptions/sub_old').length, 0);
  assert.equal(calls.filter((c) => c.method === 'POST' && c.path === '/v1/subscriptions/sub_old').length, 0);
  assert.ok(stripeCall(calls, 'POST', '/v1/invoices/in_old_1/void'));
});

test('a failed Stripe step is a 500 and the user stays; the retry completes with the same calls', async () => {
  const { stripe, calls, fail } = world();
  const db = fakeDb({ customers: [customerRow], entitlements: [entitlementRow] });
  const d = deps({ stripe, db });

  fail.cancel = true;
  const first = await json(await run(d, deleteRequest({ confirmEmail: 'name@example.com' })));
  assert.equal(first.status, 500);
  assert.equal(first.body.error.code, 'server_error');
  assert.equal(db.calls.some((c) => c.op === 'deleteUser'), false);
  assert.equal(db.tables.customers.length, 1, 'the link survives so the retry can find the customer');

  fail.cancel = false;
  const retry = await json(await run(d, deleteRequest({ confirmEmail: 'name@example.com' })));
  assert.equal(retry.status, 204);
  const cancels = calls.filter((c) => c.method === 'DELETE' && c.path === '/v1/subscriptions/sub_test_1');
  assert.equal(cancels.length, 2);
  assert.ok(cancels.every((c) => c.idempotencyKey === 'delete-sub_test_1'));
  assert.equal(db.tables.customers.length, 0);
});

test('a Supabase failure after Stripe is a 500, with the Stripe side already done for the retry', async () => {
  const { stripe, calls } = world();
  const db = fakeDb({ customers: [customerRow], entitlements: [entitlementRow] });
  db.deleteUser = async () => { throw new DbError(500, 'deleteUser'); };
  const { status, body } = await json(await run(deps({ stripe, db }), deleteRequest({ confirmEmail: 'name@example.com' })));
  assert.equal(status, 500);
  assert.equal(body.error.code, 'server_error');
  assert.ok(stripeCall(calls, 'DELETE', '/v1/subscriptions/sub_test_1'));
});

test('a stored Stripe customer that no longer exists is skipped and the user is still deleted', async () => {
  const { stripe, calls } = world({ missingCustomer: true });
  const db = fakeDb({ customers: [customerRow], entitlements: [entitlementRow] });
  const { status } = await json(await run(deps({ stripe, db }), deleteRequest({ confirmEmail: 'name@example.com' })));
  assert.equal(status, 204);
  assert.equal(calls.filter((c) => c.method !== 'GET').length, 0);
  assert.equal(db.tables.customers.length, 0);
});

test('the sixth attempt within an hour is 429 with Retry-After and deletes nothing', async () => {
  const db = fakeDb({ customers: [] });
  const d = deps({ db });
  for (let i = 0; i < 5; i += 1) {
    assert.equal((await run(d, deleteRequest({ confirmEmail: 'name@example.com' }))).status, 204);
  }
  const response = await run(d, deleteRequest({ confirmEmail: 'name@example.com' }));
  assert.equal(response.status, 429);
  assert.equal(response.headers.get('retry-after'), '3600');
  assert.equal(db.calls.filter((c) => c.op === 'deleteUser').length, 5);
});

test('logs carry the event and no email, token or key', async () => {
  const lines = [];
  setLogSink((line) => lines.push(line));
  try {
    const { stripe } = world();
    const db = fakeDb({ customers: [customerRow], entitlements: [entitlementRow] });
    const { status } = await json(await run(deps({ stripe, db }), deleteRequest({ confirmEmail: 'name@example.com' })));
    assert.equal(status, 204);
  } finally {
    setLogSink(() => {});
  }
  const text = lines.join('\n');
  assert.match(text, /"evt":"account_delete"/);
  for (const secret of ['name@example.com', 'Bearer', FAKE_RESTRICTED_TEST_KEY, 'sb_secret_']) {
    assert.equal(text.includes(secret), false, `log must not contain ${secret}`);
  }
});
