// Account deletion (plan §4.2). Stops billing first, removes saved cards and the link to the user,
// and deletes the Supabase user last. Every step can be repeated, so a retry after any failure completes it.

import { isOurSubscription, isoSeconds } from './entitlement.js';
import { isMissingCustomer } from './checkout.js';
import { logEvent } from './http.js';

// Stripe statuses that still bill or can still be billed. Canceled subscriptions are never cancelled again.
const OPEN_STATUSES = new Set(['active', 'trialing', 'past_due', 'unpaid', 'incomplete', 'paused']);

// Stops billing and removes what Stripe holds for the user, keeping the customer for tax records (owner Q2).
// Returns the number of subscriptions cancelled by this call.
export async function removeBilling(deps, { customerId }) {
  const { stripe, config } = deps;
  const nowIso = isoSeconds(deps.now());
  let subscriptions;
  try {
    subscriptions = await stripe.subscriptions.list({ customer: customerId, status: 'all', limit: 20 });
  } catch (error) {
    // The Stripe customer no longer exists (for example after test-data cleanup): nothing is left to remove.
    if (isMissingCustomer(error)) return 0;
    throw error;
  }

  let cancelled = 0;
  const ours = subscriptions.data.filter((sub) => isOurSubscription(sub, { priceLookupKey: config.priceLookupKey }));
  for (const sub of ours) {
    if (OPEN_STATUSES.has(sub.status)) {
      // Metadata first: a canceled subscription cannot be updated. Without the user link, a late webhook
      // for this subscription cannot be tied to the deleted user.
      await stripe.subscriptions.update(sub.id, { metadata: { user_id: '', uncloud_account_deleted: nowIso } });
      // prorate: false is no automatic refund (owner decision 1).
      await stripe.subscriptions.cancel(sub.id, { prorate: false, invoice_now: false }, { idempotencyKey: `delete-${sub.id}` });
      cancelled += 1;
    }
    // Runs for canceled subscriptions too, so a retry after a failed void still voids the invoice.
    const open = await stripe.invoices.list({ subscription: sub.id, status: 'open', limit: 20 });
    for (const invoice of open.data) await stripe.invoices.voidInvoice(invoice.id);
  }

  const methods = await stripe.paymentMethods.list({ customer: customerId, limit: 20 });
  for (const method of methods.data) await stripe.paymentMethods.detach(method.id);

  await stripe.customers.update(customerId, { metadata: { user_id: '', uncloud_account_deleted: nowIso } });
  return cancelled;
}

// Deletes the account for a verified user: Stripe first, then the Supabase user (owner decision 2).
export async function deleteAccountFor(deps, userId) {
  const rows = await deps.db.select('customers', { user_id: userId }, { service: true });
  let cancelled = 0;
  if (rows[0]?.stripe_customer_id) {
    cancelled = await removeBilling(deps, { customerId: rows[0].stripe_customer_id });
  }
  await deps.db.deleteUser(userId);
  logEvent({ evt: 'account_delete', user: userId, result: 'deleted', subscriptions: cancelled });
}
