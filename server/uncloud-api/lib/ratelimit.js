// Fixed-window rate limits, counted in Supabase (public.rate_limits, public.consume_rate_limit).
// Stripe's API rate limit is per account, so a script hitting public endpoints must not reach it (review M6).

import { apiError } from './http.js';

// Throws rate_limited (429) when the key has used up its allowance for the window.
export async function enforceRateLimit(deps, key, { limit, windowSeconds }) {
  const allowed = await deps.db.rpc(
    'consume_rate_limit',
    { p_key: key, p_limit: limit, p_window_seconds: windowSeconds },
    { service: true },
  );
  if (allowed !== true) throw apiError('rate_limited', 429);
}

// The caller's address for per-IP limits. Vercel sets x-real-ip; x-forwarded-for is the fallback.
export function clientAddress(request) {
  const real = request.headers.get('x-real-ip')?.trim();
  if (real) return real;
  return request.headers.get('x-forwarded-for')?.split(',')[0]?.trim() || 'unknown';
}
