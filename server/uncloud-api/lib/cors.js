// CORS for the public waitlist endpoint only. Answers preflight itself, refuses a POST from any origin
// that is not on the allow-list, and copies the CORS headers onto every response to an allowed origin
// (success and errors), so the page can read its 400 and 429 messages.

import { errorResponse, logEvent } from './http.js';

const ALLOWED_METHODS = 'POST, OPTIONS';
const ALLOWED_HEADERS = 'content-type';
const MAX_AGE = '86400';

function corsHeaders(origin) {
  return {
    'Access-Control-Allow-Origin': origin,
    Vary: 'Origin',
    'Access-Control-Allow-Methods': ALLOWED_METHODS,
    'Access-Control-Allow-Headers': ALLOWED_HEADERS,
    'Access-Control-Max-Age': MAX_AGE,
  };
}

// `origins` is a function returning the allow-list, read per request so an env change applies on redeploy.
export function withCors(handler, { origins }) {
  return async (request) => {
    const origin = request.headers.get('origin');
    const allowed = origin !== null && origins().includes(origin) ? origin : null;

    if (request.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers: allowed ? corsHeaders(allowed) : { Vary: 'Origin' } });
    }
    if (request.method === 'POST' && allowed === null) {
      logEvent({ evt: 'waitlist', result: 'forbidden_origin' });
      return errorResponse('forbidden_origin', 403, undefined, { Vary: 'Origin' });
    }

    const response = await handler(request);
    if (allowed === null) return response;
    const headers = new Headers(response.headers);
    for (const [name, value] of Object.entries(corsHeaders(allowed))) headers.set(name, value);
    return new Response(response.body, { status: response.status, headers });
  };
}
