// Turns Stripe state into the entitlements row. Shared by the webhook and the success-page sync.
// Every path re-fetches the subscription from Stripe, so duplicate, retried and out-of-order
// events converge on Stripe's current state.

import { logEvent } from './http.js';
import { idOf, subscriptionIdOf } from './stripe-shapes.js';
import { mapSubscription, isOurSubscription } from './entitlement.js';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
// Entitlement-row statuses that mean "this subscription is paying for Uncloud Plus now".
const LIVE_ROW_STATUSES = new Set(['active', 'trialing', 'pastDue']);
// The same idea for Stripe's own subscription statuses.
const LIVE_STRIPE_STATUSES = new Set(['active', 'trialing', 'past_due']);
// A duplicate's latest payment is refunded only when it was paid this recently (review H3).
const REFUND_WINDOW_SECONDS = 24 * 60 * 60;
// Set on every refund this server makes for a duplicate, so the charge.refunded it causes is skipped.
const DUPLICATE_REASON = 'duplicate';
// Subscription metadata key recording the Checkout Session whose one-year choice was applied (review M2).
const ONE_YEAR_MARKER = 'one_year_applied';

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

// The refund target for a paid invoice: its PaymentIntent, or the charge for a payment made without one. Found through Invoice Payments, since Invoice has no charge field (review H1).
async function paidPaymentOf(stripe, invoiceId) {
  const list = await stripe.invoicePayments.list({ invoice: invoiceId, status: 'paid', limit: 10 });
  const paid = list.data.find((entry) => entry.payment);
  if (!paid) return null;
  const paymentIntent = idOf(paid.payment.payment_intent);
  if (paymentIntent) return { payment_intent: paymentIntent };
  const charge = idOf(paid.payment.charge);
  return charge ? { charge } : null;
}

// Cancels a duplicate subscription and refunds its latest payment. Re-running it is safe: a canceled
// subscription is not canceled again, and the refund uses a fixed idempotency key.
// Returns the refund outcome for logs: refunded, refund_skipped_old or no_payment.
async function cancelAndRefund(deps, subscriptionId) {
  const { stripe } = deps;
  const current = await stripe.subscriptions.retrieve(subscriptionId);
  if (current.status !== 'canceled') {
    await stripe.subscriptions.cancel(subscriptionId, { prorate: false }, { idempotencyKey: `dup-cancel-${subscriptionId}` });
  }
  const invoiceId = idOf(current.latest_invoice);
  if (!invoiceId) return 'no_payment';
  const invoice = await stripe.invoices.retrieve(invoiceId);
  if (!(invoice.amount_paid > 0)) return 'no_payment';
  // Only a recent payment is refunded, so a refund never reaches back into an old period (review H3).
  const paidAt = invoice.status_transitions?.paid_at;
  if (typeof paidAt !== 'number' || deps.now().getTime() / 1000 - paidAt > REFUND_WINDOW_SECONDS) {
    return 'refund_skipped_old';
  }
  const target = await paidPaymentOf(stripe, invoiceId);
  if (!target) return 'no_payment';
  await stripe.refunds.create(
    { ...target, metadata: { uncloud_reason: DUPLICATE_REASON, subscription: subscriptionId } },
    { idempotencyKey: `dup-refund-${subscriptionId}` },
  );
  return 'refunded';
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
  if (
    existing?.stripe_subscription_id &&
    existing.stripe_subscription_id !== subscription.id &&
    LIVE_ROW_STATUSES.has(existing.status)
  ) {
    const other = await deps.stripe.subscriptions.retrieve(existing.stripe_subscription_id);
    if (!LIVE_STRIPE_STATUSES.has(other.status)) {
      // The row still says live, but Stripe says that subscription has ended (a late or failed
      // deletion event). Re-sync it, then apply this subscription normally (review H3).
      await applySubscription(deps, other, { userIdHint: userId });
    } else if (LIVE_ROW_STATUSES.has(row.status)) {
      // Two live Uncloud subscriptions for one user (for example two checkout tabs). Keep the newer.
      if (other.created > subscription.created) {
        const outcome = await cancelAndRefund(deps, subscription.id);
        logEvent({ evt: 'duplicate_refund', id: subscription.id, user: userId, result: outcome });
        result = 'duplicate_cancelled';
      } else {
        const outcome = await cancelAndRefund(deps, other.id);
        logEvent({ evt: 'duplicate_refund', id: other.id, user: userId, result: outcome });
        result = 'duplicate_replaced';
      }
    } else {
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

  // Checkout cannot set cancel_at_period_end, so the one-year choice is applied here, once per
  // Checkout Session (review M2). Without the marker, every reload, restored tab or late webhook
  // would turn renewal off again after the user had turned it back on.
  if (session.metadata?.renewal === 'oneYear' && subscription.metadata?.[ONE_YEAR_MARKER] !== session.id) {
    await stripe.subscriptions.update(
      subscriptionId,
      { cancel_at_period_end: true, metadata: { [ONE_YEAR_MARKER]: session.id } },
      { idempotencyKey: `one-year-${session.id}` },
    );
    // Re-read: an idempotent replay returns the cached response, not the current state.
    subscription = await stripe.subscriptions.retrieve(subscriptionId);
  }
  return applySubscription(deps, subscription, { userIdHint: userId });
}

// The invoice behind a charge, found through the charge's PaymentIntent (review H2).
async function invoiceIdOfCharge(stripe, charge) {
  const paymentIntent = idOf(charge.payment_intent);
  if (!paymentIntent) return null;
  const list = await stripe.invoicePayments.list({
    payment: { type: 'payment_intent', payment_intent: paymentIntent },
    limit: 10,
  });
  const match = list.data.find((entry) => idOf(entry.payment?.payment_intent) === paymentIntent);
  return idOf(match?.invoice);
}

// charge.refunded: a full refund ends the plan now, but only when the refunded charge paid for the
// user's current subscription (review H2). A partial refund changes nothing. A refund this server
// made for a duplicate is skipped, because the duplicate handling already dealt with it.
async function handleRefund(deps, charge) {
  const { stripe } = deps;
  if (charge.refunded !== true) return 'partial_ignored';
  const customerId = idOf(charge.customer);
  if (!customerId) return 'ignored';
  const customers = await deps.db.select('customers', { stripe_customer_id: customerId }, { service: true });
  const userId = customers[0]?.user_id;
  if (!userId) return 'ignored';
  const entitlement = (await deps.db.select('entitlements', { user_id: userId }, { service: true }))[0];
  if (!entitlement?.stripe_subscription_id || !LIVE_ROW_STATUSES.has(entitlement.status)) {
    return 'no_active_subscription';
  }

  const refunds = await stripe.refunds.list({ charge: charge.id, limit: 100 });
  if (refunds.data.some((refund) => refund.metadata?.uncloud_reason === DUPLICATE_REASON)) {
    return 'duplicate_refund_ignored';
  }

  const invoiceId = await invoiceIdOfCharge(stripe, charge);
  if (!invoiceId) return 'refund_other_invoice';
  const invoice = await stripe.invoices.retrieve(invoiceId);
  const subscriptionId = subscriptionIdOf(invoice);
  if (!subscriptionId || subscriptionId !== entitlement.stripe_subscription_id) return 'refund_other_invoice';
  const subscription = await stripe.subscriptions.retrieve(subscriptionId);
  if (idOf(subscription.latest_invoice) !== invoiceId) return 'refund_other_invoice';

  if (subscription.status !== 'canceled') {
    await stripe.subscriptions.cancel(subscriptionId, { prorate: false }, { idempotencyKey: `refund-${charge.id}` });
  }
  return syncSubscription(deps, subscriptionId, { userIdHint: userId });
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
