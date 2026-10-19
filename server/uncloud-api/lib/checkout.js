// Checkout Session parameters, the customer lookup and creation, and the renewal choice.

import { createHash } from 'node:crypto';
import { apiError, logEvent } from './http.js';

// Custom submit-button text (final copy, plan §5.3). Checkout allows up to 1200 characters.
export const RENEW_TEXT =
  'Uncloud Plus renews every year at $9.99 plus tax. We’ll email you before it renews. Turn renewal off anytime in Uncloud › Settings › Account.';
export const ONE_YEAR_TEXT =
  'One year of Uncloud Plus. It won’t renew and you won’t be charged again unless you turn renewal on in Uncloud. Stripe keeps your card only for that.';

export const RENEWALS = ['automatic', 'oneYear'];

export function submitTextFor(renewal) {
  return renewal === 'automatic' ? RENEW_TEXT : ONE_YEAR_TEXT;
}

// The Checkout Session body (plan §2.2). `customerId` is the Stripe customer for this user.
export function checkoutSessionParams({ config, userId, customerId, priceId: price, renewal }) {
  const params = {
    mode: 'subscription',
    customer: customerId,
    billing_address_collection: 'auto',
    line_items: [{ price, quantity: 1 }],
    automatic_tax: { enabled: config.automaticTax },
    client_reference_id: userId,
    metadata: { user_id: userId, renewal },
    subscription_data: { metadata: { user_id: userId } },
    success_url: `${config.publicBaseUrl}/checkout/success?session_id={CHECKOUT_SESSION_ID}`,
    cancel_url: `${config.publicBaseUrl}/checkout/cancelled`,
    allow_promotion_codes: false,
    locale: 'auto',
    custom_text: { submit: { message: submitTextFor(renewal) } },
  };
  // Required by Stripe for automatic_tax with an existing customer.
  if (config.automaticTax) params.customer_update = { address: 'auto', name: 'auto' };
  return params;
}

// Stripe rejects a Checkout Session whose customer no longer exists. The error code and parameter.
export function isMissingCustomer(error) {
  return error?.code === 'resource_missing' && error?.param === 'customer';
}

// Short hash of the email, for idempotency keys: a changed email then never replays another body (review L4).
function emailKey(email) {
  return createHash('sha256').update(String(email).trim().toLowerCase()).digest('hex').slice(0, 16);
}

// Stripe customer for the Supabase user: from the customers table, else created once.
// `replacing` names a stored customer that Stripe no longer has; a new one is created in its place.
// Refuses (503) when the stored customer belongs to the other Stripe mode.
export async function ensureCustomer(deps, { userId, email, replacing = null }) {
  const { db, stripe, config } = deps;
  const rows = await db.select('customers', { user_id: userId }, { service: true });
  const stored = rows[0] ?? null;
  if (stored && stored.stripe_customer_id !== replacing) {
    if (stored.livemode !== config.livemode) throw apiError('checkout_unavailable', 503);
    return stored.stripe_customer_id;
  }
  // A replacement has its own key, so Stripe does not replay the deleted customer's response.
  const key = `customer-${userId}-${emailKey(email)}${replacing ? `-replace-${replacing}` : ''}`;
  const customer = await stripe.customers.create(
    { email, metadata: { user_id: userId } },
    { idempotencyKey: key },
  );
  if (customer.livemode !== config.livemode) throw apiError('checkout_unavailable', 503);
  await db.upsert(
    'customers',
    { user_id: userId, stripe_customer_id: customer.id, livemode: customer.livemode },
    { onConflict: 'user_id' },
    { service: true },
  );
  logEvent({ evt: 'customer_created', user: userId, result: replacing ? 'replaced' : 'created' });
  return customer.id;
}
