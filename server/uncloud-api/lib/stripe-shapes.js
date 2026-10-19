// Reads Stripe objects that changed shape in API version 2025-03-31 ("basil").
// Both the new and the old locations are read, so fixtures from either shape work.

// Stripe ids come as strings or as expanded objects.
export function idOf(value) {
  if (typeof value === 'string') return value;
  if (value && typeof value === 'object' && typeof value.id === 'string') return value.id;
  return null;
}

export function firstItem(subscription) {
  return subscription?.items?.data?.[0] ?? null;
}

// Basil: current_period_end is on the subscription item. Older API: on the subscription.
// Returns a Date or null.
export function periodEnd(subscription) {
  const seconds = firstItem(subscription)?.current_period_end ?? subscription?.current_period_end;
  return typeof seconds === 'number' ? new Date(seconds * 1000) : null;
}

// Basil: invoice.parent.subscription_details.subscription. Older: invoice.subscription.
export function subscriptionIdOf(invoice) {
  return idOf(invoice?.parent?.subscription_details?.subscription) ?? idOf(invoice?.subscription);
}
