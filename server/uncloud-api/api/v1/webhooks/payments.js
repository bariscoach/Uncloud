// POST /v1/webhooks/payments
// Stripe sends checkout.session.completed and charge.refunded. The signature is
// checked against STRIPE_WEBHOOK_SECRET. No Uncloud account is created.
import { errorResponse, logEvent } from '../../../lib/http.js';
import { handleStripeWebhook, readWebhookBody } from '../../../lib/stripe-license.js';
import { loadPrivateKey } from '../../../lib/licenses.js';
import { supabaseLicenseLedger } from '../../../lib/license-ledger.js';

function depsFromEnv() {
  const raw = process.env.LICENSE_SIGNING_PRIVATE_KEY;
  return {
    webhookSecret: process.env.STRIPE_WEBHOOK_SECRET,
    privateKey: raw ? loadPrivateKey(raw) : null,
    ledger: supabaseLicenseLedger(),
    prices: {
      plus: process.env.STRIPE_PRICE_PLUS,
      pro: process.env.STRIPE_PRICE_PRO,
      family: process.env.STRIPE_PRICE_FAMILY,
    },
    resendApiKey: process.env.RESEND_API_KEY,
    fetchPriceId: process.env.STRIPE_SECRET_KEY
      ? async (sessionId) => {
          const response = await fetch(
            `https://api.stripe.com/v1/checkout/sessions/${encodeURIComponent(sessionId)}/line_items?limit=5`,
            { headers: { authorization: `Bearer ${process.env.STRIPE_SECRET_KEY}` } },
          );
          if (!response.ok) return null;
          const body = await response.json();
          return body.data?.[0]?.price?.id ?? null;
        }
      : null,
    now: () => Date.now(),
  };
}

async function webhook(request) {
  if (request.method !== 'POST') {
    return errorResponse('method_not_allowed', 405, undefined, { Allow: 'POST' });
  }
  try {
    const body = await readWebhookBody(request);
    if (body.error) return body.error;
    return await handleStripeWebhook(body.raw, request.headers.get('stripe-signature'), depsFromEnv());
  } catch (error) {
    logEvent({ evt: 'stripe_webhook', result: 'error', error: error?.name ?? 'Error' });
    return errorResponse('server_error', 500);
  }
}

export { webhook as GET, webhook as POST, webhook as PUT, webhook as PATCH, webhook as DELETE };
