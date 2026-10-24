// Route logic. Each handler takes (request, deps); deps are injected so tests can replace
// Supabase, auth, the clock and the signing key.

import { apiError, json, noContent, readJSON, logEvent } from './http.js';
import { stripeModeOf } from './config.js';
import { enforceRateLimit, clientAddress } from './ratelimit.js';
import { permanentEntitlement, signEntitlement } from './entitlement.js';
import { deleteAccountFor } from './account.js';

// Account deletion: five attempts an hour per user (plan §4.1).
const DELETE_LIMIT = { limit: 5, windowSeconds: 60 * 60 };

// GET /v1/health: no auth, no secrets. livemode comes from the key prefix when it is set.
export function health(env = process.env) {
  const mode = stripeModeOf(env.STRIPE_SECRET_KEY ?? '');
  return json({ ok: true, livemode: mode === 'live' });
}

// GET /v1/me. Needs a valid Supabase access token; no database or payment lookup.
//
// Response (kept exactly as the shipped app reads it; see lib/entitlement.js):
//   {
//     "account": { "id": "<user uuid>", "email": "<email>" },
//     "entitlement": {
//       "plan": "plus",                        // always plus
//       "status": "active",                    // always active
//       "currentPeriodEnd": "2100-01-01T00:00:00Z",
//       "cancelAtPeriodEnd": false,
//       "checkedAt": "<now, UTC, whole seconds>",
//       "signature": "<base64 Ed25519 over the signed message>"
//     }
//   }
// The signature covers account id, plan, status, currentPeriodEnd, cancelAtPeriodEnd and checkedAt,
// newline-joined after the prefix "uncloud-entitlement-v1". The app rejects an unsigned or badly signed plan.
export async function me(request, deps) {
  const auth = await deps.verify(request);
  const entitlement = permanentEntitlement(deps.now());
  return json({
    account: { id: auth.userId, email: auth.email },
    entitlement: {
      ...entitlement,
      signature: signEntitlement(deps.privateKey, { accountId: auth.userId, entitlement }),
    },
  });
}

// POST /v1/account/delete  body { confirmEmail }. 204 on success. Plan §4.1–4.2.
export async function deleteAccount(request, deps) {
  const auth = await deps.verify(request);
  const body = await readJSON(request);
  if (typeof body.confirmEmail !== 'string') {
    throw apiError('bad_request', 400, 'confirmEmail is required.');
  }
  if (body.confirmEmail.trim().toLowerCase() !== String(auth.email).trim().toLowerCase()) {
    throw apiError('confirmation_mismatch', 400);
  }
  await enforceRateLimit(deps, `delete:${auth.userId}`, DELETE_LIMIT);
  await deleteAccountFor(deps, auth.userId);
  return noContent();
}

// POST /v1/waitlist: launch list from the landing page. The answer is the same for a new or an existing email,
// so it cannot reveal who is already on the list. The origin check happens in lib/cors.js.
const WAITLIST_LIMITS = {
  perIp: { limit: 5, windowSeconds: 60 * 60 },
  global: { limit: 300, windowSeconds: 60 * 60 },
};
const WAITLIST_EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;
const CONTROL_CHARACTERS = /[\u0000-\u001f\u007f]/;
const WAITLIST_SOURCE = /^[a-z0-9_-]{1,32}$/;

function waitlistEmail(value) {
  if (typeof value !== 'string') return null;
  const email = value.normalize('NFC').trim().toLowerCase();
  if (email.length < 3 || email.length > 254 || CONTROL_CHARACTERS.test(email) || !WAITLIST_EMAIL.test(email)) {
    return null;
  }
  return email;
}

export async function waitlist(request, deps) {
  const body = await readJSON(request);
  // Honeypot: a filled "website" field is a bot. Answer like success, store nothing, spend no rate limit.
  if (body.website) {
    logEvent({ evt: 'waitlist', result: 'honeypot' });
    return json({ ok: true });
  }
  const email = waitlistEmail(body.email);
  if (email === null) {
    logEvent({ evt: 'waitlist', result: 'invalid' });
    throw apiError('invalid_email', 400);
  }
  const limits = { ...WAITLIST_LIMITS, ...deps.waitlistLimits };
  await enforceRateLimit(deps, `waitlist:ip:${clientAddress(request)}`, limits.perIp);
  await enforceRateLimit(deps, 'waitlist:all', limits.global);
  const source = typeof body.source === 'string' && WAITLIST_SOURCE.test(body.source) ? body.source : 'landing';
  await deps.db.upsert('waitlist', { email, source }, { onConflict: 'email', ignoreDuplicates: true }, { service: true });
  logEvent({ evt: 'waitlist', result: 'ok' });
  return json({ ok: true });
}
