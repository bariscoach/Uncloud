// Environment configuration. Values are read once per process. Secrets are only
// read when a route asks for them (getters), so a route never fails because of a
// variable it does not use. Errors name the variable, never its value.

export const DEFAULT_PUBLIC_BASE_URL = 'https://uncloud-api.vercel.app';
export const PRODUCT_ID = 'uncloud_plus';
export const DEFAULT_PRICE_LOOKUP_KEY = 'uncloud_plus_yearly';

// TODO(owner): seller identity and support address appear in the static pages
// (public/terms.html, public/privacy.html); fill them in before go-live (owner Q5).

export class ConfigError extends Error {
  constructor(name) {
    super(`Missing or empty environment variable ${name}`);
    this.name = 'ConfigError';
    this.varName = name;
  }
}

export function requireEnv(env, name) {
  const value = env[name];
  if (typeof value !== 'string' || value.trim() === '') throw new ConfigError(name);
  return value.trim();
}

// 'test' or 'live' from the key prefix; anything else is refused.
export function stripeModeOf(key) {
  if (/^[rs]k_test_/.test(key)) return 'test';
  if (/^[rs]k_live_/.test(key)) return 'live';
  return null;
}

export function loadConfig(env = process.env) {
  const publicBaseUrl = (env.PUBLIC_BASE_URL || DEFAULT_PUBLIC_BASE_URL).replace(/\/+$/, '');
  const config = {
    publicBaseUrl,
    priceLookupKey: env.STRIPE_PRICE_LOOKUP_KEY?.trim() || DEFAULT_PRICE_LOOKUP_KEY,
    automaticTax: env.STRIPE_AUTOMATIC_TAX === 'true',
    productId: PRODUCT_ID,
  };
  Object.defineProperties(config, {
    stripeSecretKey: { enumerable: true, get: () => requireEnv(env, 'STRIPE_SECRET_KEY') },
    stripeWebhookSecret: { enumerable: true, get: () => requireEnv(env, 'STRIPE_WEBHOOK_SECRET') },
    stripePortalConfigurationId: { enumerable: true, get: () => requireEnv(env, 'STRIPE_PORTAL_CONFIGURATION_ID') },
    // 'test' or 'live', derived from the restricted key. Throws if the key is missing or unrecognised.
    stripeMode: {
      enumerable: true,
      get: () => {
        const mode = stripeModeOf(requireEnv(env, 'STRIPE_SECRET_KEY'));
        if (!mode) throw new ConfigError('STRIPE_SECRET_KEY (unrecognised key format)');
        return mode;
      },
    },
    livemode: { enumerable: true, get: () => config.stripeMode === 'live' },
    supabaseUrl: {
      enumerable: true,
      get: () => requireEnv(env, 'SUPABASE_URL').replace(/\/+$/, ''),
    },
    supabasePublishableKey: { enumerable: true, get: () => requireEnv(env, 'SUPABASE_PUBLISHABLE_KEY') },
    supabaseSecretKey: { enumerable: true, get: () => requireEnv(env, 'SUPABASE_SECRET_KEY') },
    entitlementSigningKey: { enumerable: true, get: () => requireEnv(env, 'ENTITLEMENT_SIGNING_KEY') },
  });
  return config;
}
