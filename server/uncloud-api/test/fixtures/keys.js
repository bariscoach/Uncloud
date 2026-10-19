// Obviously fake credentials for tests. None of these is a real Stripe or Supabase key.
// They match the prefixes the code checks, so they exercise the same branches as real keys.
export const FAKE_RESTRICTED_TEST_KEY = 'rk_test_FAKE_NOT_A_REAL_KEY_0000000000';
export const FAKE_RESTRICTED_LIVE_KEY = 'rk_live_FAKE_NOT_A_REAL_KEY_0000000000';
export const FAKE_WEBHOOK_SECRET = 'whsec_FAKE_NOT_A_REAL_SECRET_0000000000';
export const FAKE_SUPABASE_SECRET = 'sb_secret_FAKE_NOT_A_REAL_KEY_000000000';
