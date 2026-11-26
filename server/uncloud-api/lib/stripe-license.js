// Stripe Checkout webhook. Verifies Stripe-Signature, mints one Ed25519 license
// per checkout session, emails it, and revokes that license when the charge is refunded.
// Buying does not create or require an Uncloud account.

import { createHmac, timingSafeEqual } from 'node:crypto';
import { json, logEvent } from './http.js';
import { mintLicense, seatsFor } from './licenses.js';

const TOLERANCE_SECONDS = 300;
const BODY_LIMIT = 256 * 1024;

export function verifyStripeSignature({ rawBody, header, secret, now = Date.now(), toleranceSeconds = TOLERANCE_SECONDS }) {
  if (typeof rawBody !== 'string' || typeof header !== 'string' || typeof secret !== 'string' || secret.length === 0) {
    return false;
  }
  let timestamp = null;
  const signatures = [];
  for (const piece of header.split(',')) {
    const index = piece.indexOf('=');
    if (index === -1) continue;
    const name = piece.slice(0, index);
    const value = piece.slice(index + 1);
    if (name === 't') timestamp = value;
    if (name === 'v1') signatures.push(value);
  }
  if (!timestamp || signatures.length === 0 || !/^\d+$/.test(timestamp)) return false;
  const age = Math.abs(now / 1000 - Number(timestamp));
  if (age > toleranceSeconds) return false;
  const expected = createHmac('sha256', secret).update(`${timestamp}.${rawBody}`).digest('hex');
  const expectedBuf = Buffer.from(expected, 'utf8');
  return signatures.some((signature) => {
    if (typeof signature !== 'string' || signature.length !== expected.length) return false;
    return timingSafeEqual(Buffer.from(signature, 'utf8'), expectedBuf);
  });
}

export function tierForPrice(priceId, prices) {
  if (!priceId || !prices) return null;
  if (priceId === prices.plus) return { tier: 'plus', seats: seatsFor('plus') };
  if (priceId === prices.pro) return { tier: 'pro', seats: seatsFor('pro') };
  if (priceId === prices.family) return { tier: 'family', seats: seatsFor('family') };
  return null;
}

export function priceIdFromSession(session) {
  const groups = [session?.line_items?.data, session?.display_items];
  for (const items of groups) {
    if (!Array.isArray(items)) continue;
    for (const item of items) {
      const price = item?.price;
      if (typeof price === 'string' && price.startsWith('price_')) return price;
      if (price && typeof price.id === 'string') return price.id;
    }
  }
  const meta = session?.metadata?.price_id;
  return typeof meta === 'string' ? meta : null;
}

function paymentIntentId(value) {
  if (typeof value === 'string') return value;
  if (value && typeof value.id === 'string') return value.id;
  return null;
}

export function licenseEmail({ to, key }) {
  const link = `uncloud://license?key=${encodeURIComponent(key)}`;
  return {
    from: 'Uncloud <noreply@tryuncloud.com>',
    to,
    subject: 'Your Uncloud license',
    text: [
      'Thanks for buying Uncloud. This license is yours. It is not a subscription, and it does not need an account.',
      '',
      'On your Mac, open Uncloud and choose Uncloud → Upgrade…, or use this link:',
      link,
      '',
      'License key:',
      key,
      '',
      'Photos still go from Apple to your drive. This email is the only copy of the key we send.',
    ].join('\n'),
  };
}

async function sendWithResend(apiKey, message) {
  const response = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      authorization: `Bearer ${apiKey}`,
      'content-type': 'application/json',
    },
    body: JSON.stringify(message),
  });
  if (!response.ok) {
    const error = new Error('resend');
    error.status = response.status;
    throw error;
  }
}

export async function handleStripeWebhook(rawBody, signatureHeader, deps) {
  if (typeof rawBody !== 'string' || Buffer.byteLength(rawBody, 'utf8') > BODY_LIMIT) {
    return json({ error: { code: 'bad_request', message: 'The request body is too large.' } }, 400);
  }
  if (!deps?.webhookSecret || !deps.privateKey || !deps.ledger || !deps.prices) {
    logEvent({ evt: 'stripe_webhook', result: 'not_configured' });
    return json({ error: { code: 'not_configured', message: 'License issuing is not configured.' } }, 503);
  }
  const now = deps.now ? deps.now() : Date.now();
  if (!verifyStripeSignature({ rawBody, header: signatureHeader, secret: deps.webhookSecret, now })) {
    logEvent({ evt: 'stripe_webhook', result: 'invalid_signature' });
    return json({ error: { code: 'invalid_signature', message: 'The Stripe signature did not match.' } }, 400);
  }
  let event;
  try {
    event = JSON.parse(rawBody);
  } catch {
    return json({ error: { code: 'bad_request', message: 'The request body must be JSON.' } }, 400);
  }
  const type = event?.type;
  const object = event?.data?.object;
  if (type === 'checkout.session.completed') {
    return completeCheckout(object, deps, now);
  }
  if (type === 'charge.refunded') {
    return refundCharge(object, deps);
  }
  logEvent({ evt: 'stripe_webhook', result: 'ignored', type: typeof type === 'string' ? type.slice(0, 80) : null });
  return json({ received: true, fulfilled: false });
}

async function completeCheckout(session, deps, now) {
  const sessionId = session?.id;
  if (typeof sessionId !== 'string' || !sessionId.startsWith('cs_')) {
    return json({ error: { code: 'bad_request', message: 'The checkout session is missing.' } }, 400);
  }
  if (session.payment_status && session.payment_status !== 'paid' && session.payment_status !== 'no_payment_required') {
    logEvent({ evt: 'stripe_webhook', result: 'unpaid', session: sessionId });
    return json({ received: true, fulfilled: false, reason: 'unpaid' });
  }
  const existing = await deps.ledger.findBySession(sessionId);
  if (existing) {
    if (!existing.emailedAt && existing.email) {
      await deliver(existing, deps, now);
    }
    logEvent({ evt: 'stripe_webhook', result: 'duplicate', session: sessionId });
    return json({ received: true, fulfilled: true, duplicate: true });
  }
  let priceId = priceIdFromSession(session);
  if (!priceId && deps.fetchPriceId) priceId = await deps.fetchPriceId(sessionId);
  const plan = tierForPrice(priceId, deps.prices);
  if (!plan) {
    logEvent({ evt: 'stripe_webhook', result: 'unknown_price' });
    return json({ error: { code: 'unknown_price', message: 'This price is not an Uncloud license.' } }, 400);
  }
  const email = session.customer_details?.email || session.customer_email || null;
  const key = mintLicense({
    tier: plan.tier,
    seats: plan.seats,
    jti: sessionId,
    iat: Math.floor(now / 1000),
    email,
    privateKey: deps.privateKey,
  });
  const row = {
    sessionId,
    jti: sessionId,
    paymentIntent: paymentIntentId(session.payment_intent),
    tier: plan.tier,
    seats: plan.seats,
    email: typeof email === 'string' ? email : null,
    key,
    emailedAt: null,
  };
  await deps.ledger.save(row);
  if (row.email) await deliver(row, deps, now);
  logEvent({ evt: 'stripe_webhook', result: 'issued', tier: plan.tier, emailed: Boolean(row.emailedAt) });
  return json({ received: true, fulfilled: true, duplicate: false });
}

async function deliver(row, deps, now) {
  const message = licenseEmail({ to: row.email, key: row.key });
  if (deps.sendEmail) await deps.sendEmail(message);
  else if (deps.resendApiKey) await sendWithResend(deps.resendApiKey, message);
  else {
    const error = new Error('email_not_configured');
    error.status = 503;
    throw error;
  }
  await deps.ledger.markEmailed(row.sessionId, new Date(now).toISOString());
  row.emailedAt = new Date(now).toISOString();
}

async function refundCharge(charge, deps) {
  const paymentIntent = paymentIntentId(charge?.payment_intent);
  const row = await deps.ledger.findByPaymentIntent(paymentIntent);
  if (!row) {
    logEvent({ evt: 'stripe_webhook', result: 'refund_unknown' });
    return json({ received: true, fulfilled: false, reason: 'unknown_charge' });
  }
  await deps.ledger.revoke(row.jti, 'charge.refunded');
  logEvent({ evt: 'stripe_webhook', result: 'revoked' });
  return json({ received: true, fulfilled: true, revoked: true });
}

export async function readWebhookBody(request) {
  const declared = Number(request.headers.get('content-length') ?? '0');
  if (declared > BODY_LIMIT) {
    return { error: json({ error: { code: 'bad_request', message: 'The request body is too large.' } }, 400) };
  }
  const raw = await request.text();
  if (Buffer.byteLength(raw, 'utf8') > BODY_LIMIT) {
    return { error: json({ error: { code: 'bad_request', message: 'The request body is too large.' } }, 400) };
  }
  return { raw };
}
