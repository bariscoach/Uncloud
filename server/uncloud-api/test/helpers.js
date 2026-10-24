// Shared test doubles. No network: Supabase runs through an in-memory fake, and auth through a fake verifier.

import { generateKeyPairSync } from 'node:crypto';
import { loadConfig } from '../lib/config.js';
import { apiError, route, setLogSink } from '../lib/http.js';

// Keep test output readable: structured logs go nowhere during tests.
setLogSink(() => {});
import { FAKE_SUPABASE_SECRET } from './fixtures/keys.js';

export const NOW = new Date('2026-10-18T09:41:07Z');
export const NOW_SECONDS = Math.floor(NOW.getTime() / 1000);
export const DAY = 24 * 60 * 60;

export const USER_A = '8b1c2d3e-4f50-4a61-8b72-9c83d4e5f601';
export const USER_B = '0f9e8d7c-6b5a-4f3e-9d2c-1b0a9f8e7d6c';
export const USERS = {
  [USER_A]: { userId: USER_A, email: 'name@example.com' },
  [USER_B]: { userId: USER_B, email: 'other@example.com' },
};

// A throwaway Ed25519 pair generated per test process. Not used for production.
export const TEST_SIGNING_KEY = generateKeyPairSync('ed25519').privateKey;

export function testConfig(overrides = {}) {
  return loadConfig({
    SUPABASE_URL: 'https://example.supabase.test',
    SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_FAKE_TEST',
    SUPABASE_SECRET_KEY: FAKE_SUPABASE_SECRET,
    ENTITLEMENT_SIGNING_KEY: 'FAKE_TEST_ONLY',
    ...overrides,
  });
}

// Fake Supabase client with the same surface as lib/supabase.js. The "jwt" of a fake user is its id.
// Every call is recorded in `calls`, so a test can see what the route asked the database for.
export function fakeDb(seed = {}) {
  const tables = {
    waitlist: [...(seed.waitlist ?? [])],
  };
  const calls = [];
  const rateCounts = {};
  const matches = (row, filters) =>
    Object.entries(filters).every(([k, v]) => String(row[k]) === String(v));
  return {
    tables,
    calls,
    async select(table, filters, mode) {
      calls.push({ op: 'select', table, filters, mode });
      return tables[table].filter((r) => matches(r, filters)).slice(0, 50).map((r) => ({ ...r }));
    },
    async upsert(table, row, { onConflict, ignoreDuplicates = false }, mode) {
      calls.push({ op: 'upsert', table, row, mode, ignoreDuplicates });
      const index = tables[table].findIndex((r) => r[onConflict] === row[onConflict]);
      // Like PostgREST resolution=ignore-duplicates: an existing row is left exactly as it is.
      if (index >= 0) {
        if (!ignoreDuplicates) tables[table][index] = { ...tables[table][index], ...row };
        return;
      }
      tables[table].push({ ...row });
    },
    async deleteUser(userId, mode) {
      calls.push({ op: 'deleteUser', userId, mode });
    },
    async rpc(name, args, mode) {
      calls.push({ op: 'rpc', name, args, mode });
      if (name === 'consume_rate_limit') {
        const hits = (rateCounts[args.p_key] ?? 0) + 1;
        rateCounts[args.p_key] = hits;
        return hits <= args.p_limit;
      }
      throw new Error(`fake rpc ${name} not implemented`);
    },
  };
}

// Verifier that accepts "Bearer <userId>" for the known fake users.
export async function fakeVerify(request) {
  const match = /^Bearer (.+)$/.exec(request.headers.get('authorization') ?? '');
  const user = match && USERS[match[1]];
  if (!user) throw apiError('unauthorized', 401);
  return { ...user, jwt: user.userId };
}

export function makeDeps(overrides = {}) {
  return {
    config: testConfig(),
    now: () => new Date(NOW),
    db: fakeDb(),
    privateKey: TEST_SIGNING_KEY,
    verify: fakeVerify,
    ...overrides,
  };
}

export function authed(path, { method = 'POST', body, user = USER_A } = {}) {
  const headers = { authorization: `Bearer ${user}` };
  if (body !== undefined) headers['content-type'] = 'application/json';
  return new Request(`https://uncloud-api.vercel.app${path}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

export async function json(response) {
  return { status: response.status, body: response.status === 204 ? null : await response.json() };
}

// Runs a handler through the same route wrapper Vercel uses, so ApiErrors become responses.
export function invoke(method, handler, request, deps) {
  return route(method, (r) => handler(r, deps))(request);
}
