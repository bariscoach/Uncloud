// Verifies the Supabase access token sent by the app. Supabase signs with an asymmetric key,
// so the public keys come from the project JWKS and no shared secret is needed here.

import { createRemoteJWKSet, jwtVerify } from 'jose';
import { apiError } from './http.js';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ALGORITHMS = ['ES256', 'RS256'];

export function jwksFor(supabaseUrl) {
  return createRemoteJWKSet(new URL(`${supabaseUrl}/auth/v1/.well-known/jwks.json`));
}

// Returns { userId, email, jwt } or throws unauthorized. No detail is returned to the caller.
export async function verifyAccessToken(token, { supabaseUrl, jwks, now } = {}) {
  let payload;
  try {
    const options = {
      issuer: `${supabaseUrl}/auth/v1`,
      audience: 'authenticated',
      algorithms: ALGORITHMS,
    };
    if (now) options.currentDate = now();
    ({ payload } = await jwtVerify(token, jwks, options));
  } catch {
    throw apiError('unauthorized', 401);
  }
  if (payload.role !== 'authenticated' || typeof payload.sub !== 'string' || !UUID.test(payload.sub)) {
    throw apiError('unauthorized', 401);
  }
  if (typeof payload.email !== 'string' || payload.email === '') {
    throw apiError('unauthorized', 401);
  }
  return { userId: payload.sub, email: payload.email, jwt: token };
}

// Reads `Authorization: Bearer <token>` and verifies it.
export async function verifyRequest(request, deps) {
  const header = request.headers.get('authorization') ?? '';
  const match = /^Bearer ([A-Za-z0-9._~+/=-]+)$/.exec(header);
  if (!match) throw apiError('unauthorized', 401);
  return verifyAccessToken(match[1], deps);
}
