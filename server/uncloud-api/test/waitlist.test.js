// POST /v1/waitlist: the launch-list endpoint. No network: the fake database and the in-process route.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { route, setLogSink } from '../lib/http.js';
import { waitlist } from '../lib/handlers.js';
import { withCors } from '../lib/cors.js';
import { DbError } from '../lib/supabase.js';
import * as waitlistRoute from '../api/v1/waitlist.js';
import { fakeDb, makeDeps } from './helpers.js';

const ORIGIN = 'https://uncloud.vercel.app';
const URL_WAITLIST = 'https://uncloud-api.vercel.app/v1/waitlist';
const CORS_HEADERS = ['access-control-allow-origin', 'vary', 'access-control-allow-methods', 'access-control-allow-headers', 'access-control-max-age'];

// The same wrapping as api/v1/waitlist.js, with injected deps.
const app = (deps) => withCors(route('POST', (request) => waitlist(request, deps)), { origins: () => [ORIGIN] });

function post(body, { origin = ORIGIN, ip = '203.0.113.7', raw } = {}) {
  const headers = { 'content-type': 'application/json', 'x-real-ip': ip };
  if (origin !== null) headers.origin = origin;
  return new Request(URL_WAITLIST, { method: 'POST', headers, body: raw ?? JSON.stringify(body) });
}

function headerNames(response) {
  return [...response.headers.keys()].sort();
}

test('a new email is stored trimmed and lowercased, and answers ok', async () => {
  const deps = makeDeps({ db: fakeDb() });
  const response = await app(deps)(post({ email: '  Name@Example.COM ', source: 'landing-bottom' }));
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { ok: true });
  assert.deepEqual(deps.db.tables.waitlist, [{ email: 'name@example.com', source: 'landing-bottom' }]);
  const upsert = deps.db.calls.find((call) => call.op === 'upsert');
  assert.equal(upsert.table, 'waitlist');
  assert.deepEqual(upsert.mode, { service: true });
  assert.equal(upsert.ignoreDuplicates, true);
});

test('a repeat sign-up answers exactly like a new one and keeps the original created_at', async () => {
  const first = { email: 'name@example.com', source: 'landing', created_at: '2026-01-02T03:04:05Z' };
  const deps = makeDeps({ db: fakeDb({ waitlist: [first] }) });
  const fresh = await app(makeDeps({ db: fakeDb() }))(post({ email: 'new@example.com' }, { ip: '198.51.100.1' }));
  const repeat = await app(deps)(post({ email: '  NAME@example.com ' }));

  assert.equal(repeat.status, fresh.status);
  assert.deepEqual(await repeat.json(), await fresh.json());
  assert.deepEqual(headerNames(repeat), headerNames(fresh));
  assert.equal(deps.db.tables.waitlist.length, 1);
  assert.equal(deps.db.tables.waitlist[0].created_at, first.created_at);
});

test('invalid emails get 400 invalid_email and touch neither the table nor the rate limit', async () => {
  const bad = [
    '',
    'a',
    'a@b',
    `${'x'.repeat(250)}@e.co`,
    123,
    ['a@b.co'],
    'a@b.co\nc@d.co',
  ];
  for (const email of bad) {
    const deps = makeDeps({ db: fakeDb() });
    const response = await app(deps)(post({ email }));
    assert.equal(response.status, 400, JSON.stringify(email));
    assert.equal((await response.json()).error.code, 'invalid_email');
    assert.equal(deps.db.calls.length, 0, 'no insert and no rate-limit call');
  }
});

test('a filled honeypot answers ok, stores nothing and spends no rate limit', async () => {
  const deps = makeDeps({ db: fakeDb() });
  const response = await app(deps)(post({ email: 'bot@example.com', website: 'https://spam.example' }));
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { ok: true });
  assert.equal(deps.db.calls.length, 0);
  assert.deepEqual(deps.db.tables.waitlist, []);
});

test('the sixth request from one address is 429, another address still passes, and the global limit holds', async () => {
  const deps = makeDeps({ db: fakeDb() });
  const handler = app(deps);
  for (let i = 0; i < 5; i++) {
    assert.equal((await handler(post({ email: `user${i}@example.com` }))).status, 200);
  }
  const limited = await handler(post({ email: 'user5@example.com' }));
  assert.equal(limited.status, 429);
  assert.equal((await limited.json()).error.code, 'rate_limited');
  assert.equal(limited.headers.get('retry-after'), String(60 * 60));

  const other = await handler(post({ email: 'other@example.com' }, { ip: '198.51.100.9' }));
  assert.equal(other.status, 200);

  const global = makeDeps({ db: fakeDb(), waitlistLimits: { global: { limit: 2, windowSeconds: 3600 } } });
  const globalHandler = app(global);
  assert.equal((await globalHandler(post({ email: 'a@example.com' }, { ip: '198.51.100.20' }))).status, 200);
  assert.equal((await globalHandler(post({ email: 'b@example.com' }, { ip: '198.51.100.21' }))).status, 200);
  const capped = await globalHandler(post({ email: 'c@example.com' }, { ip: '198.51.100.22' }));
  assert.equal(capped.status, 429);
  assert.equal((await capped.json()).error.code, 'rate_limited');
});

test('a missing or other origin gets 403 forbidden_origin with no CORS headers', async () => {
  for (const origin of [null, 'https://evil.example', 'https://uncloud.vercel.app.evil.test']) {
    const deps = makeDeps({ db: fakeDb() });
    const response = await app(deps)(post({ email: 'a@example.com' }, { origin }));
    assert.equal(response.status, 403, String(origin));
    const body = await response.json();
    assert.equal(body.error.code, 'forbidden_origin');
    assert.equal(body.error.message, 'This origin is not allowed.');
    assert.equal(response.headers.get('access-control-allow-origin'), null);
    assert.equal(deps.db.calls.length, 0);
  }
});

test('a preflight from the allowed origin is 204 with the exact CORS headers; another origin gets none', async () => {
  const preflight = (origin) => new Request(URL_WAITLIST, {
    method: 'OPTIONS',
    headers: { origin, 'access-control-request-method': 'POST' },
  });
  const allowed = await app(makeDeps())(preflight(ORIGIN));
  assert.equal(allowed.status, 204);
  assert.equal(allowed.headers.get('access-control-allow-origin'), ORIGIN);
  assert.equal(allowed.headers.get('vary'), 'Origin');
  assert.equal(allowed.headers.get('access-control-allow-methods'), 'POST, OPTIONS');
  assert.equal(allowed.headers.get('access-control-allow-headers'), 'content-type');
  assert.equal(allowed.headers.get('access-control-max-age'), '86400');
  assert.equal(allowed.headers.get('access-control-allow-credentials'), null);

  const other = await app(makeDeps())(preflight('https://evil.example'));
  assert.equal(other.status, 204);
  assert.equal(other.headers.get('access-control-allow-origin'), null);
});

test('error responses from an allowed origin carry the CORS headers so the page can read them', async () => {
  const deps = makeDeps({ db: fakeDb(), waitlistLimits: { perIp: { limit: 0, windowSeconds: 3600 } } });
  const invalid = await app(makeDeps({ db: fakeDb() }))(post({ email: 'nope' }));
  assert.equal(invalid.status, 400);
  assert.equal(invalid.headers.get('access-control-allow-origin'), ORIGIN);

  const limited = await app(deps)(post({ email: 'a@example.com' }));
  assert.equal(limited.status, 429);
  assert.equal(limited.headers.get('access-control-allow-origin'), ORIGIN);
});

test('GET on the real route is a JSON 405 envelope', async () => {
  const response = await waitlistRoute.GET(new Request(URL_WAITLIST, { method: 'GET', headers: { origin: ORIGIN } }));
  assert.equal(response.status, 405);
  assert.match(response.headers.get('content-type'), /application\/json/);
  assert.equal((await response.json()).error.code, 'method_not_allowed');
});

test('the real route answers preflight without touching Stripe or the signing key', async () => {
  const response = await waitlistRoute.OPTIONS(new Request(URL_WAITLIST, {
    method: 'OPTIONS',
    headers: { origin: ORIGIN },
  }));
  assert.equal(response.status, 204);
  assert.equal(response.headers.get('access-control-allow-origin'), ORIGIN);
  for (const name of CORS_HEADERS) assert.ok(response.headers.has(name), name);
});

test('a database failure is a 500 server_error, and the log names neither the email nor the address', async () => {
  const lines = [];
  setLogSink((line) => lines.push(line));
  try {
    const db = fakeDb();
    db.upsert = async () => {
      throw new DbError(503, 'upsert');
    };
    const response = await app(makeDeps({ db }))(post({ email: 'private.person@example.com' }, { ip: '203.0.113.77' }));
    assert.equal(response.status, 500);
    assert.equal((await response.json()).error.code, 'server_error');
    const logged = lines.join('\n');
    assert.ok(!logged.includes('private.person'), 'no email in logs');
    assert.ok(!logged.includes('203.0.113.77'), 'no address in logs');
  } finally {
    setLogSink(() => {});
  }
});

test('an unknown source becomes "landing"', async () => {
  const deps = makeDeps({ db: fakeDb() });
  await app(deps)(post({ email: 'a@example.com', source: 'Not Valid!' }));
  assert.equal(deps.db.tables.waitlist[0].source, 'landing');
});

test('a body that is not a JSON object is 400 bad_request', async () => {
  const response = await app(makeDeps({ db: fakeDb() }))(post(null, { raw: '["a@example.com"]' }));
  assert.equal(response.status, 400);
  assert.equal((await response.json()).error.code, 'bad_request');
});
