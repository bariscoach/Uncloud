// Turns Stripe state into the entitlements row. Shared by the webhook and the success-page sync.
// Every path re-fetches the subscription from Stripe, so duplicate, retried and out-of-order
// events converge on Stripe's current state.

import { logEvent } from './http.js';
import { idOf, subscriptionIdOf } from './stripe-shapes.js';
import { mapSubscription, isOurSubscription } from './entitlement.js';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
// Stripe statuses that mean "this subscription is paying for Uncloud Plus now".
const LIVE_STATUSES = new Set(['active', 'trialing', 'pastDue']);

const asUUID = (value) => (typeof value === 'string' && UUID.test(value) ? value : null);

async function resolveUser(deps, subscription, userIdHint) {
  const fromMetadata = asUUID(subscription.metadata?.user_id);
  if (fromMetadata) return fromMetadata;
  const customerId = idOf(subscription.customer);
  if (customerId) {
    const rows = await deps.db.select('customers', { stripe_customer_id: customerId }, { service: true });
    if (rows[0]?.user_id) return rows[0].user_id;
  }
  return asUUID(userIdHint);
}

// Cancels a subscription we must not keep and refunds its latest invoice payment.
// Re-running it is safe: a canceled subscription is not canceled again, and the refund uses a
// fixed idempotency key.
async function cancelAndRefund(deps, subscriptionId) {
  const { stripe } = deps;
  const current = await stripe.subscriptions.retrieve(subscriptionId);
  if (current.status !== 'canceled') {
    await stripe.subscriptions.cancel(subscriptionId, { prorate: false }, { idempotencyKey: `dup-cancel-${subscriptionId}` });
  }
  const invoiceId = idOf(current.latest_invoice);
  if (!invoiceId) return;
  const invoice = await stripe.invoices.retrieve(invoiceId);
  const chargeId = idOf(invoice.charge);
  if (!chargeId || !(invoice.amount_paid > 0)) return;
  await stripe.refunds.create({ charge: chargeId }, { idempotencyKey: `dup-refund-${subscriptionId}` });
}

// Writes the entitlement for a subscription (already fetched from Stripe).
// Returns a result name for logs: applied, ignored, duplicate_cancelled, duplicate_replaced, stale_ignored.
export async function applySubscription(deps, subscription, { userIdHint } = {}) {
  const { db, config } = deps;
  const now = deps.now();
  const row = mapSubscription(subscription, {
    now,
    priceLookupKey: config.priceLookupKey,
    livemode: config.livemode,
  });
  if (!row) {
    logEvent({ evt: 'subscription', id: subscription.id, result: 'foreign_price' });
    return 'ignored';
  }
  const userId = await resolveUser(deps, subscription, userIdHint);
  if (!userId) {
    logEvent({ evt: 'subscription', id: subscription.id, result: 'no_user' });
    return 'ignored';
  }

  let result = 'applied';
  const existing = (await db.select('entitlements', { user_id: userId }, { service: true }))[0] ?? null;
  if (existing?.stripe_subscription_id && existing.stripe_subscription_id !== subscription.id) {
    if (LIVE_STATUSES.has(existing.status) && LIVE_STATUSES.has(row.status)) {
      // Two live Uncloud subscriptions for one user (for example two checkout tabs). Keep the newer.
      const other = await deps.stripe.subscriptions.retrieve(existing.stripe_subscription_id);
      if (other.created > subscription.created) {
        await cancelAndRefund(deps, subscription.id);
        result = 'duplicate_cancelled';
      } else {
        await cancelAndRefund(deps, other.id);
        result = 'duplicate_replaced';
      }
    } else if (LIVE_STATUSES.has(existing.status) && !LIVE_STATUSES.has(row.status)) {
      // An old subscription ending must not overwrite the one that is live now.
      logEvent({ evt: 'subscription', id: subscription.id, user: userId, result: 'stale_ignored' });
      return 'stale_ignored';
    }
  }

  if (result === 'duplicate_cancelled') {
    logEvent({ evt: 'subscription', id: subscription.id, user: userId, result });
    return result;
  }
  await db.rpc(
    'apply_subscription',
    {
      p_user_id: userId,
      p_subscription_id: row.stripe_subscription_id,
      p_price_id: row.stripe_price_id,
      p_plan: row.plan,
      p_status: row.status,
      p_current_period_end: row.current_period_end,
      p_cancel_at_period_end: row.cancel_at_period_end,
      p_livemode: row.livemode,
    },
    { service: true },
  );
  logEvent({ evt: 'subscription', id: subscription.id, user: userId, result });
  return result;
}

// Re-fetches a subscription from Stripe and writes its entitlement.
export async function syncSubscription(deps, subscriptionId, { userIdHint } = {}) {
  const subscription = await deps.stripe.subscriptions.retrieve(subscriptionId);
  return applySubscription(deps, subscription, { userIdHint });
}

// Handles a completed Checkout Session: stores the customer, applies the one-year choice, then syncs.
export async function syncCheckoutSession(deps, session) {
  const { stripe, db, config } = deps;
  if (session.mode !== 'subscription') return 'ignored';
  const subscriptionId = idOf(session.subscription);
  if (!subscriptionId) return 'ignored';

  let subscription = await stripe.subscriptions.retrieve(subscriptionId);
  if (!isOurSubscription(subscription, { priceLookupKey: config.priceLookupKey })) {
    logEvent({ evt: 'checkout', id: session.id, result: 'foreign_price' });
    return 'ignored';
  }

  const userId = asUUID(session.client_reference_id) ?? asUUID(session.metadata?.user_id);
  const customerId = idOf(session.customer);
  if (userId && customerId) {
    await db.upsert(
      'customers',
      { user_id: userId, stripe_customer_id: customerId, livemode: session.livemode === true },
      { onConflict: 'user_id' },
      { service: true },
    );
  }

  // Checkout cannot set cancel_at_period_end, so the one-year choice is applied here.
  if (session.metadata?.renewal === 'oneYear' && subscription.cancel_at_period_end !== true) {
    subscription = await stripe.subscriptions.update(
      subscriptionId,
      { cancel_at_period_end: true },
      { idempotencyKey: `one-year-${session.id}` },
    );
  }
  return applySubscription(deps, subscription, { userIdHint: userId });
}

// charge.refunded: a full refund ends the plan now. A partial refund changes nothing.
async function handleRefund(deps, charge) {
  if (charge.refunded !== true) return 'partial_ignored';
  const customerId = idOf(charge.customer);
  if (!customerId) return 'ignored';
  const customers = await deps.db.select('customers', { stripe_customer_id: customerId }, { service: true });
  const userId = customers[0]?.user_id;
  if (!userId) return 'ignored';
  const entitlement = (await deps.db.select('entitlements', { user_id: userId }, { service: true }))[0];
  if (!entitlement?.stripe_subscription_id || !LIVE_STATUSES.has(entitlement.status)) {
    return 'no_active_subscription';
  }
  await deps.stripe.subscriptions.cancel(
    entitlement.stripe_subscription_id,
    { prorate: false },
    { idempotencyKey: `refund-${charge.id}` },
  );
  return syncSubscription(deps, entitlement.stripe_subscription_id, { userIdHint: userId });
}

// Dispatch for verified webhook events (plan §4.6).
export async function handleEvent(deps, event) {
  const object = event.data.object;
  switch (event.type) {
    case 'checkout.session.completed':
      return syncCheckoutSession(deps, object);
    case 'customer.subscription.updated':
    case 'customer.subscription.deleted':
      return syncSubscription(deps, object.id);
    case 'invoice.paid':
    case 'invoice.payment_failed': {
      const subscriptionId = subscriptionIdOf(object);
      return subscriptionId ? syncSubscription(deps, subscriptionId) : 'ignored';
    }
    case 'charge.refunded':
      return handleRefund(deps, object);
    default:
      return 'ignored';
  }
}
