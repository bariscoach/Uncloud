import { test } from 'node:test';
import assert from 'node:assert/strict';
import { checkout } from '../lib/handlers.js';
import { checkoutSessionParams, RENEW_TEXT, ONE_YEAR_TEXT } from '../lib/checkout.js';
import { fakeStripe, fakeDb, makeDeps, authed, json, testConfig, invoke, USER_A, USERS } from './helpers.js';

function happyRoutes(overrides = {}) {
  return {
    'GET /v1/prices': () => ({ object: 'list', data: [{ id: 'price_test_1', lookup_key: 'uncloud_plus_yearly' }] }),
    'POST /v1/customers': () => ({ id: 'cus_test_1', object: 'customer', livemode: false }),
    'POST /v1/checkout/sessions': () => ({ id: 'cs_test_a1b2c3d4e5f6', url: 'https://checkout.stripe.com/c/pay/cs_test_a1b2c3d4e5f6' }),
    ...overrides,
  };
}

const call = (calls, method, path) => calls.find((c) => c.method === method && c.path === path);

test('checkout creates the customer once with an idempotency key and returns the session URL', async () => {
  const { stripe, calls } = fakeStripe(happyRoutes());
  const db = fakeDb();
  const deps = makeDeps({ stripe, db });

  const response = await invoke('POST', checkout, authed('/v1/checkout', { body: { renewal: 'automatic' } }), deps);
  const { status, body } = await json(response);

  assert.equal(status, 200);
  assert.deepEqual(body, { url: 'https://checkout.stripe.com/c/pay/cs_test_a1b2c3d4e5f6', sessionId: 'cs_test_a1b2c3d4e5f6' });

  const customerCall = call(calls, 'POST', '/v1/customers');
  // The key covers the email (review L4), so a changed email never replays another request's body.
  assert.match(customerCall.idempotencyKey, new RegExp(`^customer-${USER_A}-[0-9a-f]{16}$`));
  assert.equal(customerCall.body.get('email'), 'name@example.com');
  assert.equal(customerCall.body.get('metadata[user_id]'), USER_A);

  const stored = db.tables.customers.find((r) => r.user_id === USER_A);
  assert.equal(stored.stripe_customer_id, 'cus_test_1');
  assert.equal(stored.livemode, false);
});

test('a second checkout reuses the stored customer (no second customer call)', async () => {
  const { stripe, calls } = fakeStripe(happyRoutes());
  const db = fakeDb({ customers: [{ user_id: USER_A, stripe_customer_id: 'cus_existing', livemode: false }] });
  const deps = makeDeps({ stripe, db });

  const { status } = await json(await invoke('POST', checkout, authed('/v1/checkout', { body: { renewal: 'oneYear' } }), deps));
  assert.equal(status, 200);
  assert.equal(call(calls, 'POST', '/v1/customers'), undefined);
  const session = call(calls, 'POST', '/v1/checkout/sessions');
  assert.equal(session.body.get('customer'), 'cus_existing');
});

test('session parameters for the automatic choice', async () => {
  const { stripe, calls } = fakeStripe(happyRoutes());
  await invoke('POST', checkout, authed('/v1/checkout', { body: { renewal: 'automatic' } }), makeDeps({ stripe }));
  const body = call(calls, 'POST', '/v1/checkout/sessions').body;

  assert.equal(body.get('mode'), 'subscription');
  assert.equal(body.get('line_items[0][price]'), 'price_test_1');
  assert.equal(body.get('line_items[0][quantity]'), '1');
  assert.equal(body.get('client_reference_id'), USER_A);
  assert.equal(body.get('metadata[user_id]'), USER_A);
  assert.equal(body.get('metadata[renewal]'), 'automatic');
  assert.equal(body.get('subscription_data[metadata][user_id]'), USER_A);
  assert.equal(body.get('success_url'), 'https://uncloud-api.vercel.app/checkout/success?session_id={CHECKOUT_SESSION_ID}');
  assert.equal(body.get('cancel_url'), 'https://uncloud-api.vercel.app/checkout/cancelled');
  assert.equal(body.get('allow_promotion_codes'), 'false');
  assert.equal(body.get('custom_text[submit][message]'), RENEW_TEXT);
  // Tax is off by default (STRIPE_AUTOMATIC_TAX unset), so no customer_update either.
  assert.equal(body.get('automatic_tax[enabled]'), 'false');
  assert.equal(body.get('customer_update[address]'), null);
});

test('session parameters for the one-year choice use the one-year text', async () => {
  const { stripe, calls } = fakeStripe(happyRoutes());
  await invoke('POST', checkout, authed('/v1/checkout', { body: { renewal: 'oneYear' } }), makeDeps({ stripe }));
  const body = call(calls, 'POST', '/v1/checkout/sessions').body;
  assert.equal(body.get('metadata[renewal]'), 'oneYear');
  assert.equal(body.get('custom_text[submit][message]'), ONE_YEAR_TEXT);
  assert.ok(RENEW_TEXT.length <= 1200 && ONE_YEAR_TEXT.length <= 1200);
});

test('automatic tax on: automatic_tax enabled and customer_update address/name auto', () => {
  const params = checkoutSessionParams({
    config: testConfig({ STRIPE_AUTOMATIC_TAX: 'true' }),
    userId: USER_A,
    customerId: 'cus_test_1',
    priceId: 'price_test_1',
    renewal: 'automatic',
  });
  assert.deepEqual(params.automatic_tax, { enabled: true });
  assert.deepEqual(params.customer_update, { address: 'auto', name: 'auto' });
  assert.equal(params.customer, 'cus_test_1');
});

test('an active plan blocks a second checkout with 409 and no Stripe calls', async () => {
  const { stripe, calls } = fakeStripe(happyRoutes());
  const db = fakeDb({
    customers: [{ user_id: USER_A, stripe_customer_id: 'cus_test_1', livemode: false }],
    entitlements: [{
      user_id: USER_A, plan: 'plus', status: 'active', current_period_end: '2027-10-18T09:41:00Z',
      cancel_at_period_end: false, stripe_subscription_id: 'sub_test_1', livemode: false,
    }],
  });
  const response = await invoke('POST', checkout, authed('/v1/checkout', { body: { renewal: 'automatic' } }), makeDeps({ stripe, db }));
  const { status, body } = await json(response);
  assert.equal(status, 409);
  assert.equal(body.error.code, 'already_subscribed');
  assert.equal(calls.length, 0);
});

test('a non-renewing plan whose period has ended may buy again', async () => {
  const { stripe } = fakeStripe(happyRoutes());
  const db = fakeDb({
    customers: [{ user_id: USER_A, stripe_customer_id: 'cus_test_1', livemode: false }],
    entitlements: [{
      user_id: USER_A, plan: 'plus', status: 'active', current_period_end: '2026-10-01T00:00:00Z',
      cancel_at_period_end: true, stripe_subscription_id: 'sub_old', livemode: false,
    }],
  });
  const { status } = await json(await invoke('POST', checkout, authed('/v1/checkout', { body: { renewal: 'automatic' } }), makeDeps({ stripe, db })));
  assert.equal(status, 200);
});

test('a failing price lookup is 503 checkout_unavailable and creates no customer', async () => {
  const { stripe, calls } = fakeStripe(happyRoutes({
    'GET /v1/prices': () => { throw { status: 500, error: { type: 'api_error', message: 'boom' } }; },
  }));
  const db = fakeDb();
  const { status, body } = await json(await invoke('POST', checkout, authed('/v1/checkout', { body: { renewal: 'automatic' } }), makeDeps({ stripe, db })));
  assert.equal(status, 503);
  assert.equal(body.error.code, 'checkout_unavailable');
  assert.equal(call(calls, 'POST', '/v1/customers'), undefined);
});

test('an empty price list is also 503', async () => {
  const { stripe } = fakeStripe(happyRoutes({ 'GET /v1/prices': () => ({ object: 'list', data: [] }) }));
  const { status } = await json(await invoke('POST', checkout, authed('/v1/checkout', { body: { renewal: 'automatic' } }), makeDeps({ stripe })));
  assert.equal(status, 503);
});

test('a bad renewal value is 400', async () => {
  const { stripe } = fakeStripe(happyRoutes());
  const { status, body } = await json(await invoke('POST', checkout, authed('/v1/checkout', { body: { renewal: 'monthly' } }), makeDeps({ stripe })));
  assert.equal(status, 400);
  assert.equal(body.error.code, 'bad_request');
});

test('a customer from the other Stripe mode is refused with 503', async () => {
  const { stripe } = fakeStripe(happyRoutes());
  const db = fakeDb({ customers: [{ user_id: USER_A, stripe_customer_id: 'cus_live', livemode: true }] });
  const { status } = await json(await invoke('POST', checkout, authed('/v1/checkout', { body: { renewal: 'automatic' } }), makeDeps({ stripe, db })));
  assert.equal(status, 503);
});

test('review L4: a changed email gets a different customer idempotency key', async () => {
  const keys = [];
  for (const email of ['name@example.com', 'New.Name@example.com']) {
    const { stripe, calls } = fakeStripe(happyRoutes());
    const deps = makeDeps({ stripe, db: fakeDb() });
    const user = { ...USERS[USER_A], email };
    deps.verify = async () => ({ ...user, jwt: user.userId });
    await invoke('POST', checkout, authed('/v1/checkout', { body: { renewal: 'automatic' } }), deps);
    keys.push(call(calls, 'POST', '/v1/customers').idempotencyKey);
  }
  assert.notEqual(keys[0], keys[1]);
  // Case and surrounding spaces do not change the key for the same address.
  const { stripe, calls } = fakeStripe(happyRoutes());
  const deps = makeDeps({ stripe, db: fakeDb() });
  deps.verify = async () => ({ ...USERS[USER_A], email: '  NAME@example.com ', jwt: USER_A });
  await invoke('POST', checkout, authed('/v1/checkout', { body: { renewal: 'automatic' } }), deps);
  assert.equal(call(calls, 'POST', '/v1/customers').idempotencyKey, keys[0]);
});

test('review L4: a stored customer that Stripe no longer has is replaced once, and the new one is stored', async () => {
  let sessionAttempts = 0;
  const { stripe, calls } = fakeStripe(happyRoutes({
    'POST /v1/checkout/sessions': () => {
      sessionAttempts += 1;
      if (sessionAttempts === 1) {
        throw {
          status: 404,
          error: { type: 'invalid_request_error', code: 'resource_missing', param: 'customer', message: 'No such customer: cus_gone' },
        };
      }
      return { id: 'cs_test_a1b2c3d4e5f6', url: 'https://checkout.stripe.com/c/pay/cs_test_a1b2c3d4e5f6' };
    },
    'POST /v1/customers': () => ({ id: 'cus_new', object: 'customer', livemode: false }),
  }));
  const db = fakeDb({ customers: [{ user_id: USER_A, stripe_customer_id: 'cus_gone', livemode: false }] });
  const { status, body } = await json(await invoke('POST', checkout, authed('/v1/checkout', { body: { renewal: 'automatic' } }), makeDeps({ stripe, db })));
  assert.equal(status, 200);
  assert.equal(body.sessionId, 'cs_test_a1b2c3d4e5f6');
  assert.equal(sessionAttempts, 2);
  const customerCall = call(calls, 'POST', '/v1/customers');
  assert.match(customerCall.idempotencyKey, /-replace-cus_gone$/, 'a replacement has its own key');
  const sessionCalls = calls.filter((c) => c.method === 'POST' && c.path === '/v1/checkout/sessions');
  assert.equal(sessionCalls[1].body.get('customer'), 'cus_new');
  assert.equal(db.tables.customers.find((r) => r.user_id === USER_A).stripe_customer_id, 'cus_new');
});

test('review L4: other session errors are not retried and still fail', async () => {
  const { stripe, calls } = fakeStripe(happyRoutes({
    'POST /v1/checkout/sessions': () => { throw { status: 400, error: { type: 'invalid_request_error', code: 'parameter_invalid_empty', param: 'line_items', message: 'bad' } }; },
  }));
  const db = fakeDb({ customers: [{ user_id: USER_A, stripe_customer_id: 'cus_test_1', livemode: false }] });
  const { status } = await json(await invoke('POST', checkout, authed('/v1/checkout', { body: { renewal: 'automatic' } }), makeDeps({ stripe, db })));
  assert.equal(status, 500);
  assert.equal(calls.filter((c) => c.path === '/v1/customers').length, 0);
});

test('review M6: a user may start 10 checkouts an hour; the 11th is 429 with no Stripe call', async () => {
  const { stripe, calls } = fakeStripe(happyRoutes());
  const deps = makeDeps({ stripe, db: fakeDb({ customers: [{ user_id: USER_A, stripe_customer_id: 'cus_test_1', livemode: false }] }) });
  for (let i = 0; i < 10; i += 1) {
    assert.equal((await json(await invoke('POST', checkout, authed('/v1/checkout', { body: { renewal: 'automatic' } }), deps))).status, 200);
  }
  const before = calls.length;
  const limited = await json(await invoke('POST', checkout, authed('/v1/checkout', { body: { renewal: 'automatic' } }), deps));
  assert.equal(limited.status, 429);
  assert.equal(limited.body.error.code, 'rate_limited');
  assert.equal(calls.length, before, 'no Stripe call while limited');
});
