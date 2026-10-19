import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createSupabase, DbError } from '../lib/supabase.js';
import { FAKE_SUPABASE_SECRET } from './fixtures/keys.js';

const PUBLISHABLE = 'sb_publishable_FAKE_TEST';
const JWT = 'eyJhbGciOiJFUzI1NiJ9.FAKE.SIGNATURE';

// Records every request and answers with the given body and status.
function recordingFetch(status = 200, body = '[]') {
  const requests = [];
  const fetchFn = async (url, init) => {
    requests.push({ url: new URL(url), method: init.method, headers: init.headers, body: init.body });
    return new Response(body, { status, headers: { 'content-type': 'application/json' } });
  };
  return { requests, fetchFn };
}

function client(fetchFn) {
  return createSupabase({
    url: 'https://example.supabase.test/',
    publishableKey: PUBLISHABLE,
    secretKey: FAKE_SUPABASE_SECRET,
    fetchFn,
  });
}

test('user calls send the publishable key and the caller JWT, never the secret key', async () => {
  const { requests, fetchFn } = recordingFetch(200, '[{"plan":"plus"}]');
  const rows = await client(fetchFn).rpc('my_entitlement', {}, { jwt: JWT });
  assert.deepEqual(rows, [{ plan: 'plus' }]);
  const [request] = requests;
  assert.equal(request.url.toString(), 'https://example.supabase.test/rest/v1/rpc/my_entitlement');
  assert.equal(request.method, 'POST');
  assert.equal(request.headers.apikey, PUBLISHABLE);
  assert.equal(request.headers.authorization, `Bearer ${JWT}`);
  assert.equal(JSON.stringify(request.headers).includes(FAKE_SUPABASE_SECRET), false);
});

test('service calls send the secret key and no user token', async () => {
  const { requests, fetchFn } = recordingFetch(200, '[]');
  await client(fetchFn).select('entitlements', { user_id: 'u1' }, { service: true });
  const [request] = requests;
  assert.equal(request.headers.apikey, FAKE_SUPABASE_SECRET);
  assert.equal(request.headers.authorization, undefined);
});

test('select builds eq filters and escapes values', async () => {
  const { requests, fetchFn } = recordingFetch(200, '[]');
  await client(fetchFn).select('customers', { stripe_customer_id: 'cus_1&x=y' }, { service: true });
  assert.equal(requests[0].url.searchParams.get('stripe_customer_id'), 'eq.cus_1&x=y');
  assert.equal(requests[0].url.pathname, '/rest/v1/customers');
});

test('upsert merges duplicates on the conflict column', async () => {
  const { requests, fetchFn } = recordingFetch(201, '');
  await client(fetchFn).upsert('customers', { user_id: 'u1', stripe_customer_id: 'cus_1', livemode: false }, { onConflict: 'user_id' }, { service: true });
  const [request] = requests;
  assert.equal(request.url.searchParams.get('on_conflict'), 'user_id');
  assert.equal(request.headers.prefer, 'resolution=merge-duplicates,return=minimal');
  assert.deepEqual(JSON.parse(request.body), { user_id: 'u1', stripe_customer_id: 'cus_1', livemode: false });
});

test('a non-2xx response is a DbError without the response body', async () => {
  const { fetchFn } = recordingFetch(401, '{"message":"JWT expired","secret":"x"}');
  await assert.rejects(client(fetchFn).rpc('my_entitlement', {}, { jwt: JWT }), (error) => {
    assert.ok(error instanceof DbError);
    assert.equal(error.status, 401);
    assert.doesNotMatch(error.message, /secret|JWT expired/);
    return true;
  });
});

test('an empty response body is null, not a parse error', async () => {
  const { fetchFn } = recordingFetch(200, '');
  assert.equal(await client(fetchFn).rpc('apply_subscription', {}, { service: true }), null);
});

test('exactly one key mode must be given', async () => {
  const { fetchFn } = recordingFetch();
  const db = client(fetchFn);
  await assert.rejects(db.select('customers', {}, {}), TypeError);
  await assert.rejects(db.select('customers', {}, { jwt: JWT, service: true }), TypeError);
});

test('deleteUser calls the admin delete with the secret key and no user token', async () => {
  const { requests, fetchFn } = recordingFetch(200, '');
  await client(fetchFn).deleteUser('8b1c2d3e-4f50-4a61-8b72-9c83d4e5f601');
  const [request] = requests;
  assert.equal(request.url.toString(), 'https://example.supabase.test/auth/v1/admin/users/8b1c2d3e-4f50-4a61-8b72-9c83d4e5f601');
  assert.equal(request.method, 'DELETE');
  assert.equal(request.headers.apikey, FAKE_SUPABASE_SECRET);
  assert.equal(request.headers.authorization, undefined);
  assert.deepEqual(JSON.parse(request.body), { should_soft_delete: false });
});

test('deleteUser treats 404 as already deleted, so a retry succeeds', async () => {
  const { fetchFn } = recordingFetch(404, '{"message":"User not found"}');
  await client(fetchFn).deleteUser('8b1c2d3e-4f50-4a61-8b72-9c83d4e5f601');
});

test('deleteUser rethrows other failures as DbError', async () => {
  const { fetchFn } = recordingFetch(500, '');
  await assert.rejects(client(fetchFn).deleteUser('8b1c2d3e-4f50-4a61-8b72-9c83d4e5f601'), (error) => {
    assert.ok(error instanceof DbError);
    assert.equal(error.status, 500);
    return true;
  });
});
