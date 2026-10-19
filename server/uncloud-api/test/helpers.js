// Shared test doubles. No network: Stripe runs through the real SDK with a fake fetch,
// Supabase through an in-memory fake, and auth through a fake verifier.

import Stripe from 'stripe';
import { generateKeyPairSync } from 'node:crypto';
import { loadConfig } from '../lib/config.js';
import { apiError, route, setLogSink } from '../lib/http.js';

// Keep test output readable: structured logs go nowhere during tests.
setLogSink(() => {});
import {
  FAKE_RESTRICTED_TEST_KEY,
  FAKE_WEBHOOK_SECRET,
  FAKE_SUPABASE_SECRET,
} from './fixtures/keys.js';

export const NOW = new Date('2026-10-18T09:41:07Z');
export const NOW_SECONDS = Math.floor(NOW.getTime() / 1000);
export const DAY = 24 * 60 * 60;

export const USER_A = '8b1c2d3e-4f50-4a61-8b72-9c83d4e5f601';
export const USER_B = '0f9e8d7c-6b5a-4f3e-9d2c-1b0a9f8e7d6c';
export const USERS = {
  [USER_A]: { userId: USER_A, email: 'name@example.com' },
  [USER_B]: { userId: USER_B, email: 'other@example.com' },
};

// A throwaway Ed25519 pair generated per test process. Not used for production.
export const TEST_SIGNING_KEY = generateKeyPairSync('ed25519').privateKey;

export function testConfig(overrides = {}) {
  return loadConfig({
    STRIPE_SECRET_KEY: FAKE_RESTRICTED_TEST_KEY,
    STRIPE_WEBHOOK_SECRET: FAKE_WEBHOOK_SECRET,
    STRIPE_PORTAL_CONFIGURATION_ID: 'bpc_FAKE_TEST',
    SUPABASE_URL: 'https://example.supabase.test',
    SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_FAKE_TEST',
    SUPABASE_SECRET_KEY: FAKE_SUPABASE_SECRET,
    ENTITLEMENT_SIGNING_KEY: 'FAKE_TEST_ONLY',
    ...overrides,
  });
}

// Fake Stripe via the real SDK. `routes` maps "METHOD /v1/path" to a function
// ({ body, query, idempotencyKey }) returning the JSON object, or throwing { status, error }.
// Every request is recorded in `calls`.
export function fakeStripe(routes = {}) {
  const calls = [];
  const fetchFn = async (url, init = {}) => {
    const parsed = new URL(url);
    const method = (init.method ?? 'GET').toUpperCase();
    // The SDK passes headers as [name, value] pairs.
    const pairs = Array.isArray(init.headers) ? init.headers : Object.entries(init.headers ?? {});
    const headers = Object.fromEntries(pairs.map(([k, v]) => [k.toLowerCase(), v]));
    const req = {
      method,
      path: parsed.pathname,
      query: parsed.searchParams,
      body: new URLSearchParams(typeof init.body === 'string' ? init.body : ''),
      idempotencyKey: headers['idempotency-key'],
    };
    calls.push(req);
    const handler = routes[`${method} ${parsed.pathname}`];
    const respond = (status, data) =>
      new Response(JSON.stringify(data), { status, headers: { 'content-type': 'application/json' } });
    if (!handler) {
      return respond(404, { error: { type: 'invalid_request_error', message: `No fake route for ${method} ${parsed.pathname}` } });
    }
    try {
      return respond(200, await handler(req));
    } catch (failure) {
      return respond(failure.status ?? 400, { error: failure.error ?? { type: 'api_error', message: String(failure) } });
    }
  };
  const stripe = new Stripe(FAKE_RESTRICTED_TEST_KEY, {
    apiVersion: Stripe.API_VERSION,
    httpClient: Stripe.createFetchHttpClient(fetchFn),
    maxNetworkRetries: 0,
  });
  return { stripe, calls };
}

// Fake Supabase client with the same surface as lib/supabase.js. The "jwt" of a fake user is its id.
export function fakeDb(seed = {}) {
  const tables = {
    customers: [...(seed.customers ?? [])],
    entitlements: [...(seed.entitlements ?? [])],
    stripe_events: [...(seed.stripe_events ?? [])],
  };
  const calls = [];
  const rateCounts = {};
  const matches = (row, filters) =>
    Object.entries(filters).every(([k, v]) => String(row[k]) === String(v));
  const upsertRow = (table, row, key) => {
    const index = tables[table].findIndex((r) => r[key] === row[key]);
    if (index >= 0) tables[table][index] = { ...tables[table][index], ...row };
    else tables[table].push({ ...row });
  };
  return {
    tables,
    calls,
    async select(table, filters, mode) {
      calls.push({ op: 'select', table, filters, mode });
      return tables[table].filter((r) => matches(r, filters)).slice(0, 50).map((r) => ({ ...r }));
    },
    async upsert(table, row, { onConflict }, mode) {
      calls.push({ op: 'upsert', table, row, mode });
      upsertRow(table, row, onConflict);
    },
    // Like the real admin delete: the user's customers and entitlements rows cascade away.
    async deleteUser(userId, mode) {
      calls.push({ op: 'deleteUser', userId, mode });
      tables.customers = tables.customers.filter((r) => r.user_id !== userId);
      tables.entitlements = tables.entitlements.filter((r) => r.user_id !== userId);
    },
    async rpc(name, args, mode) {
      calls.push({ op: 'rpc', name, args, mode });
      if (name === 'my_entitlement') {
        const userId = mode.jwt;
        const row = tables.entitlements.find((r) => r.user_id === userId);
        if (!row) return [];
        return [{
          plan: row.plan,
          status: row.status,
          current_period_end: row.current_period_end,
          cancel_at_period_end: row.cancel_at_period_end,
        }];
      }
      if (name === 'consume_rate_limit') {
      const hits = (rateCounts[args.p_key] ?? 0) + 1;
      rateCounts[args.p_key] = hits;
      return hits <= args.p_limit;
    }
    if (name === 'apply_subscription') {
        upsertRow('entitlements', {
          user_id: args.p_user_id,
          plan: args.p_plan,
          status: args.p_status,
          current_period_end: args.p_current_period_end,
          cancel_at_period_end: args.p_cancel_at_period_end,
          stripe_subscription_id: args.p_subscription_id,
          stripe_price_id: args.p_price_id,
          livemode: args.p_livemode,
        }, 'user_id');
        return null;
      }
      throw new Error(`fake rpc ${name} not implemented`);
    },
  };
}

// Verifier that accepts "Bearer <userId>" for the known fake users.
export async function fakeVerify(request) {
  const match = /^Bearer (.+)$/.exec(request.headers.get('authorization') ?? '');
  const user = match && USERS[match[1]];
  if (!user) throw apiError('unauthorized', 401);
  return { ...user, jwt: user.userId };
}

export function makeDeps(overrides = {}) {
  const stripe = overrides.stripe ?? fakeStripe().stripe;
  return {
    config: testConfig(),
    now: () => new Date(NOW),
    stripe,
    db: fakeDb(),
    privateKey: TEST_SIGNING_KEY,
    verify: fakeVerify,
    ...overrides,
  };
}

export function authed(path, { method = 'POST', body, user = USER_A } = {}) {
  const headers = { authorization: `Bearer ${user}` };
  if (body !== undefined) headers['content-type'] = 'application/json';
  return new Request(`https://uncloud-api.vercel.app${path}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

// A subscription in the pinned API shape: current_period_end is on the item, not on the subscription.
export function subscription({
  id = 'sub_test_1',
  status = 'active',
  cancel = false,
  cancelAt = null,
  periodEnd = NOW_SECONDS + 365 * DAY,
  periodStart = periodEnd - 365 * DAY,
  created = NOW_SECONDS - 30 * DAY,
  lookupKey = 'uncloud_plus_yearly',
  product = 'uncloud_plus',
  priceId = 'price_test_1',
  customer = 'cus_test_1',
  userId = USER_A,
  latestInvoice = 'in_test_1',
  metadata = {},
} = {}) {
  return {
    id,
    object: 'subscription',
    status,
    cancel_at_period_end: cancel,
    cancel_at: cancelAt,
    created,
    customer,
    livemode: false,
    metadata: { ...(userId ? { user_id: userId } : {}), ...metadata },
    latest_invoice: latestInvoice,
    items: {
      object: 'list',
      data: [{
        id: `si_${id}`,
        object: 'subscription_item',
        current_period_start: periodStart,
        current_period_end: periodEnd,
        price: { id: priceId, object: 'price', lookup_key: lookupKey, product },
      }],
    },
  };
}

// A paid invoice in the pinned API shape: the subscription is under parent.subscription_details,
// and there is no charge field. `paidSecondsAgo` sets status_transitions.paid_at.
export function invoice({ id = 'in_test_1', subscriptionId = 'sub_test_1', paidSecondsAgo = 60, amountPaid = 999 } = {}) {
  return {
    id,
    object: 'invoice',
    status: 'paid',
    amount_paid: amountPaid,
    parent: { type: 'subscription_details', subscription_details: { subscription: subscriptionId, metadata: {} } },
    status_transitions: { paid_at: NOW_SECONDS - paidSecondsAgo, finalized_at: NOW_SECONDS - paidSecondsAgo },
  };
}

// One Invoice Payment (GET /v1/invoice_payments entry) for an invoice, paid by a PaymentIntent.
export function invoicePayment({ invoiceId = 'in_test_1', paymentIntent = 'pi_test_1', status = 'paid' } = {}) {
  return {
    id: `inpay_${invoiceId}`,
    object: 'invoice_payment',
    invoice: invoiceId,
    status,
    is_default: true,
    livemode: false,
    payment: { type: 'payment_intent', payment_intent: paymentIntent },
  };
}

// A refund object (GET /v1/refunds entry).
export function refund({ id = 're_1', charge = 'ch_test_1', metadata = {} } = {}) {
  return { id, object: 'refund', charge, metadata, status: 'succeeded' };
}

export function checkoutSession({
  id = 'cs_test_a1b2c3d4e5f6',
  mode = 'subscription',
  status = 'complete',
  subscriptionId = 'sub_test_1',
  customer = 'cus_test_1',
  userId = USER_A,
  renewal = 'automatic',
} = {}) {
  return {
    id,
    object: 'checkout.session',
    mode,
    status,
    livemode: false,
    subscription: subscriptionId,
    customer,
    client_reference_id: userId,
    metadata: { user_id: userId, renewal },
  };
}

export function event(type, object, { id = 'evt_test_1', livemode = false } = {}) {
  return { id, object: 'event', type, livemode, created: NOW_SECONDS, data: { object } };
}

// Signed webhook request for the given event, using the fake webhook secret.
export function webhookRequest(stripe, evt, { signature } = {}) {
  const payload = JSON.stringify(evt);
  const header = signature ?? stripe.webhooks.generateTestHeaderString({ payload, secret: FAKE_WEBHOOK_SECRET });
  return new Request('https://uncloud-api.vercel.app/v1/stripe/webhook', {
    method: 'POST',
    headers: { 'stripe-signature': header, 'content-type': 'application/json' },
    body: payload,
  });
}

export async function json(response) {
  return { status: response.status, body: response.status === 204 ? null : await response.json() };
}

// Runs a handler through the same route wrapper Vercel uses, so ApiErrors become responses.
export function invoke(method, handler, request, deps) {
  return route(method, (r) => handler(r, deps))(request);
}
