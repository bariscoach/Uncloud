// Route logic. Each handler takes (request, deps); deps are injected so tests can replace
// Stripe, Supabase, auth, the clock and the signing key.

import { apiError, errorResponse, json, noContent, readJSON, readText, logEvent } from './http.js';
import { stripeModeOf } from './config.js';
import { priceId } from './stripe.js';
import { RENEWALS, checkoutSessionParams, ensureCustomer, isMissingCustomer } from './checkout.js';
import { enforceRateLimit, clientAddress } from './ratelimit.js';
import { syncCheckoutSession, syncSubscription, handleEvent } from './sync.js';
import { toWire, signEntitlement } from './entitlement.js';
import { deleteAccountFor } from './account.js';

const CHECKOUT_SESSION_ID = /^cs_(test|live)_[A-Za-z0-9]{10,200}$/;
const WEBHOOK_BODY_LIMIT = 256 * 1024;
const ACTIVE_STATUSES = new Set(['active', 'pastDue', 'trialing']);
// Allowances per window (review M6). Checkout Session creation is per user; the sync endpoint is per address.
const CHECKOUT_LIMIT = { limit: 10, windowSeconds: 60 * 60 };
const SYNC_LIMIT = { limit: 30, windowSeconds: 60 };
// Account deletion: five attempts an hour per user (plan §4.1).
const DELETE_LIMIT = { limit: 5, windowSeconds: 60 * 60 };

// GET /v1/health: no auth, no secrets. livemode comes from the key prefix when it is set.
export function health(env = process.env) {
  const mode = stripeModeOf(env.STRIPE_SECRET_KEY ?? '');
  return json({ ok: true, livemode: mode === 'live' });
}

// Current entitlement for the caller, read with the caller's JWT (RLS applies).
async function readEntitlement(deps, auth) {
  const rows = await deps.db.rpc('my_entitlement', {}, { jwt: auth.jwt });
  return toWire(Array.isArray(rows) ? rows[0] : null, deps.now());
}

function signed(deps, auth, entitlement) {
  return {
    ...entitlement,
    signature: signEntitlement(deps.privateKey, { accountId: auth.userId, entitlement }),
  };
}

// GET /v1/me
export async function me(request, deps) {
  const auth = await deps.verify(request);
  const entitlement = await readEntitlement(deps, auth);
  return json({
    account: { id: auth.userId, email: auth.email },
    entitlement: signed(deps, auth, entitlement),
  });
}

// POST /v1/checkout  body { renewal: "automatic" | "oneYear" }
export async function checkout(request, deps) {
  const auth = await deps.verify(request);
  const body = await readJSON(request);
  if (!RENEWALS.includes(body.renewal)) {
    throw apiError('bad_request', 400, 'renewal must be "automatic" or "oneYear".');
  }

  const now = deps.now();
  const current = await readEntitlement(deps, auth);
  const periodOpen = current.currentPeriodEnd && new Date(current.currentPeriodEnd).getTime() > now.getTime();
  if (ACTIVE_STATUSES.has(current.status) && periodOpen) {
    throw apiError('already_subscribed', 409);
  }
  await enforceRateLimit(deps, `checkout:${auth.userId}`, CHECKOUT_LIMIT);

  const price = await priceId(deps.stripe, deps.config.priceLookupKey);
  const createSession = (customerId) =>
    deps.stripe.checkout.sessions.create(
      checkoutSessionParams({
        config: deps.config,
        userId: auth.userId,
        customerId,
        priceId: price,
        renewal: body.renewal,
      }),
    );
  let session;
  try {
    session = await createSession(await ensureCustomer(deps, { userId: auth.userId, email: auth.email }));
  } catch (error) {
    if (!isMissingCustomer(error)) throw error;
    // The stored Stripe customer was deleted (for example test-data cleanup). Replace it once (review L4).
    const stale = (await deps.db.select('customers', { user_id: auth.userId }, { service: true }))[0];
    const replacement = await ensureCustomer(deps, {
      userId: auth.userId,
      email: auth.email,
      replacing: stale?.stripe_customer_id ?? null,
    });
    session = await createSession(replacement);
  }
  logEvent({ evt: 'checkout_session', user: auth.userId, result: body.renewal });
  return json({ url: session.url, sessionId: session.id });
}

// POST /v1/checkout/sync  body { sessionId }. No auth: it only re-derives state from Stripe.
// Always 204 for a bad or unknown id, so the response reveals nothing.
export async function checkoutSync(request, deps) {
  const body = await readJSON(request);
  const sessionId = typeof body.sessionId === 'string' ? body.sessionId : '';
  if (!CHECKOUT_SESSION_ID.test(sessionId)) return noContent();
  await enforceRateLimit(deps, `sync:${clientAddress(request)}`, SYNC_LIMIT);

  let session;
  try {
    session = await deps.stripe.checkout.sessions.retrieve(sessionId, { expand: ['subscription'] });
  } catch (error) {
    if (error?.type === 'StripeInvalidRequestError') return noContent();
    throw error;
  }
  if (session.livemode !== deps.config.livemode) return noContent();
  if (session.status === 'complete' && session.mode === 'subscription') {
    await syncCheckoutSession(deps, session);
  }
  return noContent();
}

// POST /v1/portal
export async function portal(request, deps) {
  const auth = await deps.verify(request);
  const rows = await deps.db.select('customers', { user_id: auth.userId }, { service: true });
  if (rows.length === 0) throw apiError('no_subscription', 409);
  const session = await deps.stripe.billingPortal.sessions.create({
    customer: rows[0].stripe_customer_id,
    configuration: deps.config.stripePortalConfigurationId,
    return_url: `${deps.config.publicBaseUrl}/account/return`,
  });
  return json({ url: session.url });
}

// POST /v1/subscription/renewal  body { autoRenew: boolean }
export async function renewal(request, deps) {
  const auth = await deps.verify(request);
  const body = await readJSON(request);
  if (typeof body.autoRenew !== 'boolean') {
    throw apiError('bad_request', 400, 'autoRenew must be true or false.');
  }

  const row = (await deps.db.select('entitlements', { user_id: auth.userId }, { service: true }))[0];
  const periodOpen = row?.current_period_end && new Date(row.current_period_end).getTime() > deps.now().getTime();
  if (!row?.stripe_subscription_id || !['active', 'pastDue'].includes(row.status) || !periodOpen) {
    throw apiError('no_subscription', 409);
  }

  await deps.stripe.subscriptions.update(row.stripe_subscription_id, {
    cancel_at_period_end: !body.autoRenew,
  });
  await syncSubscription(deps, row.stripe_subscription_id, { userIdHint: auth.userId });
  const entitlement = await readEntitlement(deps, auth);
  return json({ entitlement: signed(deps, auth, entitlement) });
}

// POST /v1/account/delete  body { confirmEmail }. 204 on success. Plan §4.1–4.2.
export async function deleteAccount(request, deps) {
  const auth = await deps.verify(request);
  const body = await readJSON(request);
  if (typeof body.confirmEmail !== 'string') {
    throw apiError('bad_request', 400, 'confirmEmail is required.');
  }
  if (body.confirmEmail.trim().toLowerCase() !== String(auth.email).trim().toLowerCase()) {
    throw apiError('confirmation_mismatch', 400);
  }
  await enforceRateLimit(deps, `delete:${auth.userId}`, DELETE_LIMIT);
  await deleteAccountFor(deps, auth.userId);
  return noContent();
}

// POST /v1/stripe/webhook. Signature check first; events are applied once (stripe_events).
export async function webhook(request, deps) {
  const signature = request.headers.get('stripe-signature') ?? '';
  const body = await readText(request, WEBHOOK_BODY_LIMIT);
  const secret = deps.config.stripeWebhookSecret;

  let event;
  try {
    event = deps.stripe.webhooks.constructEvent(body, signature, secret);
  } catch {
    return errorResponse('bad_request', 400, 'The signature check failed.');
  }

  if (event.livemode !== deps.config.livemode) {
    logEvent({ evt: event.type, id: event.id, result: 'livemode_mismatch' });
    return json({ received: true });
  }
  const seen = await deps.db.select('stripe_events', { id: event.id }, { service: true });
  if (seen.length > 0) {
    logEvent({ evt: event.type, id: event.id, result: 'already_applied' });
    return json({ received: true });
  }

  const result = await handleEvent(deps, event);
  await deps.db.upsert(
    'stripe_events',
    {
      id: event.id,
      type: event.type,
      livemode: event.livemode,
      created: new Date(event.created * 1000).toISOString(),
    },
    { onConflict: 'id' },
    { service: true },
  );
  logEvent({ evt: event.type, id: event.id, result });
  return json({ received: true });
}
