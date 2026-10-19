// Reads Stripe objects in the shape of the pinned API version (2026-09-30.endive, the SDK's API_VERSION).
// Older shapes are deliberately not read: fixtures must match the pinned API, or bugs hide (review H1).

// Stripe ids come as strings or as expanded objects.
export function idOf(value) {
  if (typeof value === 'string') return value;
  if (value && typeof value === 'object' && typeof value.id === 'string') return value.id;
  return null;
}

export function firstItem(subscription) {
  return subscription?.items?.data?.[0] ?? null;
}

// current_period_end lives on the subscription item. Returns a Date or null.
export function periodEnd(subscription) {
  const seconds = firstItem(subscription)?.current_period_end;
  return typeof seconds === 'number' ? new Date(seconds * 1000) : null;
}

// invoice.parent.subscription_details.subscription. Returns the id or null.
export function subscriptionIdOf(invoice) {
  return idOf(invoice?.parent?.subscription_details?.subscription);
}
