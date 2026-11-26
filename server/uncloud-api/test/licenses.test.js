import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { readFileSync } from 'node:fs';
import {
  loadPrivateKey,
  publicKeyFromPrivate,
  mintLicense,
  readSignedLicense,
  verifyLicense,
  verifyLicenseRequest,
  memoryLicenseLedger,
  emailHash,
} from '../lib/licenses.js';
import { handleStripeWebhook, verifyStripeSignature, tierForPrice, licenseEmail } from '../lib/stripe-license.js';
import { licenseSupabaseConfig } from '../lib/license-ledger.js';
import { TEST_LICENSE_PRIVATE_KEY, TEST_LICENSE_PUBLIC_KEY, TEST_LICENSE_TOKEN } from './fixtures/license-key.js';

const privateKey = loadPrivateKey(TEST_LICENSE_PRIVATE_KEY);
const publicKey = publicKeyFromPrivate(privateKey);
const prices = {
  plus: 'price_1UfrRNFQA2wOQUo52ZVB9O0z',
  pro: 'price_1UfrRPFQA2wOQUo5QQnUjlGk',
  family: 'price_1UfrRQFQA2wOQUo5CqAgSdqE',
};

function signHeader(raw, secret, now) {
  const t = Math.floor(now / 1000);
  const v1 = createHmac('sha256', secret).update(`${t}.${raw}`).digest('hex');
  return `t=${t},v1=${v1}`;
}

function deps(overrides = {}) {
  const emails = [];
  return {
    emails,
    ledger: memoryLicenseLedger(),
    webhookSecret: 'whsec_test_only',
    privateKey,
    prices,
    now: () => Date.parse('2026-11-26T00:00:00Z'),
    sendEmail: async (message) => { emails.push(message); },
    ...overrides,
  };
}

test('a signed key verifies, and a shape-only key does not', () => {
  const parsed = readSignedLicense(TEST_LICENSE_TOKEN, publicKey);
  assert.equal(parsed.tier, 'plus');
  assert.equal(parsed.seats, 1);
  assert.equal(parsed.jti, 'cs_test_vector');
  assert.equal(readSignedLicense('UC1.plus.1.g.EXISTING1', publicKey), null);
  assert.equal(readSignedLicense(TEST_LICENSE_TOKEN.slice(0, -2) + 'AA', publicKey), null);
  const minted = mintLicense({
    tier: 'family', seats: 5, jti: 'cs_test_family', iat: 1764000000, email: 'Buyer@Example.com', privateKey,
  });
  const family = readSignedLicense(minted, publicKey);
  assert.equal(family.tier, 'family');
  assert.equal(family.seats, 5);
  assert.equal(family.emailHash, emailHash('buyer@example.com'));
});

test('verify reports revocation and rejects a bad signature', async () => {
  const ledger = memoryLicenseLedger();
  const key = mintLicense({ tier: 'pro', seats: 2, jti: 'cs_test_pro', iat: 1764000000, privateKey });
  assert.equal(verifyLicense(key, { publicKey, isRevoked: () => false }).valid, true);
  await ledger.revoke('cs_test_pro', 'charge.refunded');
  const revoked = verifyLicense(key, { publicKey, isRevoked: (jti) => jti === 'cs_test_pro' });
  assert.equal(revoked.valid, false);
  assert.equal(revoked.reason, 'revoked');

  const response = await verifyLicenseRequest(new Request('https://uncloud-api.vercel.app/v1/licenses/verify', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ key: 'UC1.plus.1.g.EXISTING1' }),
  }), { publicKey, isRevoked: async () => false });
  assert.equal(response.status, 200);
  assert.equal((await response.json()).reason, 'invalid_signature');
});

test('verify without a signing key is not configured', async () => {
  const response = await verifyLicenseRequest(new Request('https://uncloud-api.vercel.app/v1/licenses/verify', {
    method: 'POST',
    body: JSON.stringify({ key: TEST_LICENSE_TOKEN }),
  }), {});
  assert.equal(response.status, 503);
});

test('the Stripe signature covers the raw body and rejects a stale timestamp', () => {
  const raw = '{"id":"evt_1"}';
  const now = Date.parse('2026-11-26T00:00:00Z');
  const header = signHeader(raw, 'whsec_test_only', now);
  assert.equal(verifyStripeSignature({ rawBody: raw, header, secret: 'whsec_test_only', now }), true);
  assert.equal(verifyStripeSignature({ rawBody: raw + ' ', header, secret: 'whsec_test_only', now }), false);
  assert.equal(verifyStripeSignature({
    rawBody: raw, header, secret: 'whsec_test_only', now: now + 10 * 60 * 1000,
  }), false);
});

test('checkout.session.completed mints one key, emails it, and is idempotent', async () => {
  const context = deps();
  const event = {
    type: 'checkout.session.completed',
    data: {
      object: {
        id: 'cs_test_paid',
        payment_status: 'paid',
        payment_intent: 'pi_test_paid',
        customer_details: { email: 'buyer@example.com' },
        line_items: { data: [{ price: { id: prices.plus } }] },
      },
    },
  };
  const raw = JSON.stringify(event);
  const header = signHeader(raw, context.webhookSecret, context.now());
  const first = await handleStripeWebhook(raw, header, context);
  assert.equal(first.status, 200);
  assert.equal((await first.json()).duplicate, false);
  assert.equal(context.emails.length, 1);
  assert.match(context.emails[0].text, /uncloud:\/\/license\?key=/);
  assert.match(context.emails[0].from, /noreply@tryuncloud.com/);
  const stored = await context.ledger.findBySession('cs_test_paid');
  assert.equal(readSignedLicense(stored.key, publicKey).tier, 'plus');
  assert.equal(stored.seats, 1);

  const second = await handleStripeWebhook(raw, header, context);
  assert.equal((await second.json()).duplicate, true);
  assert.equal(context.emails.length, 1);
});

test('a refund revokes the key and verify then rejects it', async () => {
  const context = deps();
  const paid = {
    type: 'checkout.session.completed',
    data: {
      object: {
        id: 'cs_test_refund',
        payment_status: 'paid',
        payment_intent: 'pi_test_refund',
        customer_details: { email: 'buyer@example.com' },
        line_items: { data: [{ price: { id: prices.family } }] },
      },
    },
  };
  const rawPaid = JSON.stringify(paid);
  await handleStripeWebhook(rawPaid, signHeader(rawPaid, context.webhookSecret, context.now()), context);
  const stored = await context.ledger.findByPaymentIntent('pi_test_refund');
  assert.equal(verifyLicense(stored.key, { publicKey, isRevoked: () => false }).tier, 'family');

  const refund = { type: 'charge.refunded', data: { object: { payment_intent: 'pi_test_refund' } } };
  const rawRefund = JSON.stringify(refund);
  const response = await handleStripeWebhook(rawRefund, signHeader(rawRefund, context.webhookSecret, context.now()), context);
  assert.equal((await response.json()).revoked, true);
  assert.equal(await context.ledger.isRevoked(stored.jti), true);
  assert.equal(verifyLicense(stored.key, {
    publicKey,
    isRevoked: (jti) => jti === stored.jti,
  }).reason, 'revoked');
});

test('an unknown price and a bad signature are refused', async () => {
  const context = deps();
  const event = {
    type: 'checkout.session.completed',
    data: { object: { id: 'cs_test_other', payment_status: 'paid', line_items: { data: [{ price: { id: 'price_other' } }] } } },
  };
  const raw = JSON.stringify(event);
  const unknown = await handleStripeWebhook(raw, signHeader(raw, context.webhookSecret, context.now()), context);
  assert.equal(unknown.status, 400);
  const bad = await handleStripeWebhook(raw, 't=1,v1=nope', context);
  assert.equal(bad.status, 400);
  assert.deepEqual(tierForPrice(prices.pro, prices), { tier: 'pro', seats: 2 });
});

test('the license email carries the deep link and not a second account step', () => {
  const message = licenseEmail({ to: 'buyer@example.com', key: TEST_LICENSE_TOKEN });
  assert.match(message.text, /uncloud:\/\/license\?key=/);
  assert.match(message.text, /does not need an account/);
});

test('the license ledger uses its own Supabase project and falls back to the account project', () => {
  assert.deepEqual(licenseSupabaseConfig({
    LICENSE_SUPABASE_URL: 'https://zkdykcghctegpeanslyz.supabase.co',
    LICENSE_SUPABASE_SECRET_KEY: 'license-secret',
    LICENSE_SUPABASE_PUBLISHABLE_KEY: 'license-public',
    SUPABASE_URL: 'https://auth.supabase.co',
    SUPABASE_SECRET_KEY: 'auth-secret',
    SUPABASE_PUBLISHABLE_KEY: 'auth-public',
  }), {
    url: 'https://zkdykcghctegpeanslyz.supabase.co',
    secret: 'license-secret',
    publishable: 'license-public',
  });
  assert.deepEqual(licenseSupabaseConfig({
    LICENSE_SUPABASE_URL: 'https://zkdykcghctegpeanslyz.supabase.co',
    SUPABASE_SECRET_KEY: '  auth-secret  ',
    SUPABASE_PUBLISHABLE_KEY: 'auth-public',
  }), {
    url: 'https://zkdykcghctegpeanslyz.supabase.co',
    secret: 'auth-secret',
    publishable: 'auth-public',
  });
  assert.deepEqual(licenseSupabaseConfig({
    SUPABASE_URL: 'https://auth.supabase.co',
    SUPABASE_SECRET_KEY: 'auth-secret',
    SUPABASE_PUBLISHABLE_KEY: 'auth-public',
  }), {
    url: 'https://auth.supabase.co',
    secret: 'auth-secret',
    publishable: 'auth-public',
  });
  assert.equal(licenseSupabaseConfig({}).url, undefined);
});

test('the license routes name env vars and do not embed a live secret', () => {
  const verifySource = readFileSync(new URL('../api/v1/licenses/verify.js', import.meta.url), 'utf8');
  const webhookSource = readFileSync(new URL('../api/v1/webhooks/payments.js', import.meta.url), 'utf8');
  assert.match(verifySource, /LICENSE_SIGNING_PRIVATE_KEY/);
  assert.match(webhookSource, /STRIPE_WEBHOOK_SECRET/);
  assert.match(webhookSource, /RESEND_API_KEY/);
  assert.doesNotMatch(verifySource + webhookSource, /sk_live_|whsec_[A-Za-z0-9]{8}/);
  assert.equal(TEST_LICENSE_PUBLIC_KEY, '9eTHD62q5241M5GcgIzPInNbF+/Jsi9c7emeztduWFQ=');
});
