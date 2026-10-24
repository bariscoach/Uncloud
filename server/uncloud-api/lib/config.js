// Environment configuration. Values are read once per process. Secrets are only
// read when a route asks for them (getters), so a route never fails because of a
// variable it does not use. Errors name the variable, never its value.

export const DEFAULT_WAITLIST_ORIGINS = 'https://uncloud-app.vercel.app';

// TODO(owner): the support address appears in the static pages (public/terms.html, public/privacy.html).

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

export function loadConfig(env = process.env) {
  const config = {
    // Exact-match origins allowed to POST /v1/waitlist (comma-separated env).
    waitlistOrigins: (env.WAITLIST_ALLOWED_ORIGINS || DEFAULT_WAITLIST_ORIGINS)
      .split(',').map((origin) => origin.trim()).filter(Boolean),
  };
  Object.defineProperties(config, {
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
