import { test } from 'node:test';
import assert from 'node:assert/strict';
import { loadConfig, requireEnv, stripeModeOf, ConfigError } from '../lib/config.js';
import { FAKE_RESTRICTED_TEST_KEY, FAKE_RESTRICTED_LIVE_KEY } from './fixtures/keys.js';

test('a missing secret throws a ConfigError that names the variable and never its value', () => {
  const config = loadConfig({});
  assert.throws(
    () => config.supabaseSecretKey,
    (error) => {
      assert.ok(error instanceof ConfigError);
      assert.equal(error.varName, 'SUPABASE_SECRET_KEY');
      assert.match(error.message, /SUPABASE_SECRET_KEY/);
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
  const config = loadConfig({ WAITLIST_ALLOWED_ORIGINS: 'https://example.test' });
  assert.deepEqual(config.waitlistOrigins, ['https://example.test']);
  assert.throws(() => config.supabaseUrl, ConfigError);
});

test('the signing key getter names only its variable', () => {
  const config = loadConfig({ ENTITLEMENT_SIGNING_KEY: 'FAKE_TEST_ONLY' });
  assert.equal(config.entitlementSigningKey, 'FAKE_TEST_ONLY');
  assert.throws(() => loadConfig({}).entitlementSigningKey, /ENTITLEMENT_SIGNING_KEY/);
});

test('the health check reads its mode from the key prefix', () => {
  assert.equal(stripeModeOf(FAKE_RESTRICTED_TEST_KEY), 'test');
  assert.equal(stripeModeOf(FAKE_RESTRICTED_LIVE_KEY), 'live');
  assert.equal(stripeModeOf('pk_test_FAKE'), null, 'publishable keys are not accepted');
  assert.equal(stripeModeOf(''), null);
});

test('waitlist origins default to the app site, trimmed and split', () => {
  assert.deepEqual(loadConfig({}).waitlistOrigins, ['https://uncloud-app.vercel.app']);
  assert.deepEqual(
    loadConfig({ WAITLIST_ALLOWED_ORIGINS: ' https://a.test , https://b.test ,' }).waitlistOrigins,
    ['https://a.test', 'https://b.test'],
  );
});

test('no payment settings are read any more', () => {
  const config = loadConfig({ STRIPE_SECRET_KEY: FAKE_RESTRICTED_TEST_KEY, PUBLIC_BASE_URL: 'https://example.test' });
  for (const removed of ['stripeSecretKey', 'stripeWebhookSecret', 'stripeMode', 'livemode', 'priceLookupKey', 'publicBaseUrl']) {
    assert.equal(removed in config, false, removed);
  }
});
