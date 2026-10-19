import { test } from 'node:test';
import assert from 'node:assert/strict';
import { loadConfig, requireEnv, stripeModeOf, ConfigError, DEFAULT_PUBLIC_BASE_URL } from '../lib/config.js';
import { FAKE_RESTRICTED_TEST_KEY, FAKE_RESTRICTED_LIVE_KEY, FAKE_WEBHOOK_SECRET } from './fixtures/keys.js';

test('a missing secret throws a ConfigError that names the variable and never its value', () => {
  const config = loadConfig({});
  assert.throws(
    () => config.stripeSecretKey,
    (error) => {
      assert.ok(error instanceof ConfigError);
      assert.equal(error.varName, 'STRIPE_SECRET_KEY');
      assert.match(error.message, /STRIPE_SECRET_KEY/);
      assert.doesNotMatch(error.message, /rk_|sk_|whsec_|sb_/);
      return true;
    },
  );
});

test('an empty or whitespace value counts as missing', () => {
  assert.throws(() => requireEnv({ SUPABASE_URL: '   ' }, 'SUPABASE_URL'), ConfigError);
  assert.throws(() => requireEnv({ SUPABASE_URL: '' }, 'SUPABASE_URL'), ConfigError);
});

test('secrets are read lazily, so an unrelated route does not need them', () => {
  const config = loadConfig({ PUBLIC_BASE_URL: 'https://example.test' });
  assert.equal(config.publicBaseUrl, 'https://example.test');
  assert.throws(() => config.supabaseUrl, ConfigError);
});

test('Stripe mode comes from the key prefix', () => {
  assert.equal(stripeModeOf(FAKE_RESTRICTED_TEST_KEY), 'test');
  assert.equal(stripeModeOf(FAKE_RESTRICTED_LIVE_KEY), 'live');
  assert.equal(stripeModeOf('pk_test_FAKE'), null, 'publishable keys are not accepted');
  assert.equal(stripeModeOf(''), null);
});

test('an unrecognised key format is refused by stripeMode', () => {
  const config = loadConfig({ STRIPE_SECRET_KEY: 'not-a-stripe-key' });
  assert.throws(() => config.stripeMode, (error) => error instanceof ConfigError && /unrecognised/.test(error.message));
});

test('livemode follows the key', () => {
  assert.equal(loadConfig({ STRIPE_SECRET_KEY: FAKE_RESTRICTED_TEST_KEY }).livemode, false);
  assert.equal(loadConfig({ STRIPE_SECRET_KEY: FAKE_RESTRICTED_LIVE_KEY }).livemode, true);
});

test('defaults: base URL, price lookup key, automatic tax off', () => {
  const config = loadConfig({});
  assert.equal(config.publicBaseUrl, DEFAULT_PUBLIC_BASE_URL);
  assert.equal(config.priceLookupKey, 'uncloud_plus_yearly');
  assert.equal(config.automaticTax, false);
});

test('overrides: trailing slashes trimmed, lookup key, automatic tax flag', () => {
  const config = loadConfig({
    PUBLIC_BASE_URL: 'https://example.test///',
    STRIPE_PRICE_LOOKUP_KEY: 'uncloud_plus_next',
    STRIPE_AUTOMATIC_TAX: 'true',
  });
  assert.equal(config.publicBaseUrl, 'https://example.test');
  assert.equal(config.priceLookupKey, 'uncloud_plus_next');
  assert.equal(config.automaticTax, true);
  assert.equal(loadConfig({ STRIPE_AUTOMATIC_TAX: 'yes' }).automaticTax, false);
});

test('the webhook secret getter names only its variable', () => {
  const config = loadConfig({ STRIPE_WEBHOOK_SECRET: FAKE_WEBHOOK_SECRET });
  assert.equal(config.stripeWebhookSecret, FAKE_WEBHOOK_SECRET);
  assert.throws(() => loadConfig({}).stripeWebhookSecret, /STRIPE_WEBHOOK_SECRET/);
});
