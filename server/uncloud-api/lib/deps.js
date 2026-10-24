// Production dependencies, built lazily so a route only touches the secrets it uses.

import { loadConfig } from './config.js';
import { createSupabase } from './supabase.js';
import { jwksFor, verifyRequest } from './auth.js';
import { loadSigningKey } from './entitlement.js';

export function buildDeps(env = process.env) {
  const config = loadConfig(env);
  let db = null;
  let jwks = null;
  let privateKey = null;
  return {
    config,
    now: () => new Date(),
    get db() {
      db ??= createSupabase({
        url: config.supabaseUrl,
        publishableKey: config.supabasePublishableKey,
        secretKey: config.supabaseSecretKey,
      });
      return db;
    },
    get privateKey() {
      privateKey ??= loadSigningKey(config.entitlementSigningKey);
      return privateKey;
    },
    verify(request) {
      jwks ??= jwksFor(config.supabaseUrl);
      return verifyRequest(request, { supabaseUrl: config.supabaseUrl, jwks });
    },
  };
}

let shared = null;
export function defaultDeps() {
  shared ??= buildDeps();
  return shared;
}
