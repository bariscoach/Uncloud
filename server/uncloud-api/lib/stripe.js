// Stripe client construction and the price lookup cache.

import Stripe from 'stripe';
import { apiError } from './http.js';

// One client per process. Pinned to the SDK's own API version; the webhook endpoint uses the same.
let client = null;
export function stripeClient(config) {
  if (!client) {
    client = new Stripe(config.stripeSecretKey, {
      apiVersion: Stripe.API_VERSION,
      maxNetworkRetries: 2,
      timeout: 10_000,
    });
  }
  return client;
}

// Price id for a lookup key, cached per Stripe client. A failed lookup is never cached.
const priceCache = new WeakMap();
export async function priceId(stripe, lookupKey) {
  let byKey = priceCache.get(stripe);
  if (!byKey) {
    byKey = new Map();
    priceCache.set(stripe, byKey);
  }
  if (byKey.has(lookupKey)) return byKey.get(lookupKey);
  let id = null;
  try {
    const list = await stripe.prices.list({ lookup_keys: [lookupKey], active: true, limit: 1 });
    id = list?.data?.[0]?.id ?? null;
  } catch {
    id = null;
  }
  if (!id) throw apiError('checkout_unavailable', 503);
  byKey.set(lookupKey, id);
  return id;
}
