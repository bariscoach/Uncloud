// JSON responses, error envelope, body limits and method guards.

export class ApiError extends Error {
  constructor(code, status, message) {
    super(message ?? code);
    this.name = 'ApiError';
    this.code = code;
    this.status = status;
  }
}

const DEFAULT_MESSAGES = {
  unauthorized: 'Sign in again to continue.',
  bad_request: 'The request was not valid.',
  already_subscribed: 'You already have Uncloud Plus.',
  no_subscription: 'There is no Uncloud Plus plan to change.',
  checkout_unavailable: 'Checkout is unavailable right now. Try again later.',
  rate_limited: 'Too many requests. Try again later.',
  server_error: 'Something went wrong. Try again later.',
  method_not_allowed: 'This method is not allowed here.',
};

export function apiError(code, status, message) {
  return new ApiError(code, status, message ?? DEFAULT_MESSAGES[code]);
}

const JSON_HEADERS = { 'content-type': 'application/json; charset=utf-8' };

export function json(data, status = 200, headers = {}) {
  return new Response(JSON.stringify(data), { status, headers: { ...JSON_HEADERS, ...headers } });
}

export function errorResponse(code, status, message, headers = {}) {
  return json({ error: { code, message: message ?? DEFAULT_MESSAGES[code] } }, status, headers);
}

export function noContent() {
  return new Response(null, { status: 204 });
}

// Reads the body as text with a hard byte cap. Throws bad_request when over the cap.
export async function readText(request, limitBytes) {
  const declared = Number(request.headers.get('content-length') ?? '0');
  if (declared > limitBytes) throw apiError('bad_request', 400, 'The request body is too large.');
  const text = await request.text();
  if (Buffer.byteLength(text, 'utf8') > limitBytes) {
    throw apiError('bad_request', 400, 'The request body is too large.');
  }
  return text;
}

// JSON body with a 16 KB cap. Must be an object.
export async function readJSON(request) {
  const text = await readText(request, 16 * 1024);
  let value;
  try {
    value = JSON.parse(text);
  } catch {
    throw apiError('bad_request', 400, 'The request body must be JSON.');
  }
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw apiError('bad_request', 400, 'The request body must be a JSON object.');
  }
  return value;
}

let logSink = (line) => console.log(line);
export function setLogSink(sink) {
  logSink = sink;
}

// One JSON line per event. Callers must never pass tokens, emails or keys.
export function logEvent(fields) {
  logSink(JSON.stringify(fields));
}

// Builds the Vercel handler for one method. Every other method gets a JSON 405.
// Any thrown ApiError becomes its envelope; anything else is logged by name only and becomes a 500.
export function route(method, handler) {
  return async (request) => {
    if (request.method !== method) {
      return errorResponse('method_not_allowed', 405, undefined, { Allow: method });
    }
    try {
      return await handler(request);
    } catch (error) {
      if (error instanceof ApiError) return errorResponse(error.code, error.status, error.message);
      logEvent({ evt: 'unhandled', route: new URL(request.url).pathname, error: error?.name ?? 'Error' });
      return errorResponse('server_error', 500);
    }
  };
}
