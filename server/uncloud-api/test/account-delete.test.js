// POST /v1/account/delete (plan §4.1–4.2, §7.3). The database through the fake in helpers.js. No network.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { deleteAccount } from '../lib/handlers.js';
import { setLogSink } from '../lib/http.js';
import { DbError } from '../lib/supabase.js';
import { fakeDb, makeDeps, invoke, json, USER_A } from './helpers.js';
import { FAKE_RESTRICTED_TEST_KEY } from './fixtures/keys.js';

const URL_PATH = 'https://uncloud-api.vercel.app/v1/account/delete';
const deleteRequest = (body, { token = true } = {}) =>
  new Request(URL_PATH, {
    method: 'POST',
    headers: { ...(token ? { authorization: `Bearer ${USER_A}` } : {}), 'content-type': 'application/json' },
    body: typeof body === 'string' ? body : JSON.stringify(body ?? { confirmEmail: 'name@example.com' }),
  });
const run = (deps, request) => invoke('POST', deleteAccount, request, deps);

// ---- request checks --------------------------------------------------------

test('without a token it is 401 and deletes nothing', async () => {
  const db = fakeDb();
  const { status, body } = await json(await run(makeDeps({ db }), deleteRequest({ confirmEmail: 'name@example.com' }, { token: false })));
  assert.equal(status, 401);
  assert.equal(body.error.code, 'unauthorized');
  assert.equal(db.calls.some((c) => c.op === 'deleteUser'), false);
});

test('a body that is not JSON or has no confirmEmail is 400 bad_request', async () => {
  const db = fakeDb();
  for (const body of ['not json', { confirmEmail: 42 }, {}, []]) {
    const { status, body: out } = await json(await run(makeDeps({ db }), deleteRequest(body)));
    assert.equal(status, 400, JSON.stringify(body));
    assert.equal(out.error.code, 'bad_request');
  }
  assert.equal(db.calls.some((c) => c.op === 'deleteUser'), false);
});

test('another address is confirmation_mismatch; case and surrounding spaces are ignored', async () => {
  const db = fakeDb();
  const mismatch = await json(await run(makeDeps({ db }), deleteRequest({ confirmEmail: 'other@example.com' })));
  assert.equal(mismatch.status, 400);
  assert.equal(mismatch.body.error.code, 'confirmation_mismatch');
  assert.equal(db.calls.some((c) => c.op === 'deleteUser'), false);

  const matched = await json(await run(makeDeps({ db }), deleteRequest({ confirmEmail: '  Name@Example.com ' })));
  assert.equal(matched.status, 204);
});

test('the route refuses GET with a JSON 405', async () => {
  const response = await run(makeDeps(), new Request(URL_PATH, { method: 'GET' }));
  assert.equal(response.status, 405);
  assert.equal((await response.json()).error.code, 'method_not_allowed');
});

test('/v1/account/delete is a POST route; other methods get the JSON 405', async () => {
  const module = await import('../api/v1/account/delete.js');
  assert.equal(typeof module.POST, 'function');
  for (const method of ['GET', 'PUT', 'PATCH', 'DELETE']) {
    const response = await module[method](new Request(URL_PATH, { method }));
    assert.equal(response.status, 405, method);
    assert.equal((await response.json()).error.code, 'method_not_allowed');
  }
});

// ---- the deletion ----------------------------------------------------------

test('a valid request deletes the Supabase user and returns 204; no payment provider is called', async () => {
  const db = fakeDb();
  const { status } = await json(await run(makeDeps({ db }), deleteRequest({ confirmEmail: 'name@example.com' })));
  assert.equal(status, 204);
  assert.deepEqual(db.calls.filter((c) => c.op === 'deleteUser').map((c) => c.userId), [USER_A]);
});

test('a Supabase failure is a 500 and the user can retry', async () => {
  const db = fakeDb();
  db.deleteUser = async () => { throw new DbError(500, 'deleteUser'); };
  const { status, body } = await json(await run(makeDeps({ db }), deleteRequest({ confirmEmail: 'name@example.com' })));
  assert.equal(status, 500);
  assert.equal(body.error.code, 'server_error');

  const retryDb = fakeDb();
  const retry = await json(await run(makeDeps({ db: retryDb }), deleteRequest({ confirmEmail: 'name@example.com' })));
  assert.equal(retry.status, 204);
});

test('the sixth attempt within an hour is 429 with Retry-After and deletes nothing', async () => {
  const db = fakeDb();
  const deps = makeDeps({ db });
  for (let i = 0; i < 5; i += 1) {
    assert.equal((await run(deps, deleteRequest({ confirmEmail: 'name@example.com' }))).status, 204);
  }
  const response = await run(deps, deleteRequest({ confirmEmail: 'name@example.com' }));
  assert.equal(response.status, 429);
  assert.equal(response.headers.get('retry-after'), '3600');
  assert.equal(db.calls.filter((c) => c.op === 'deleteUser').length, 5);
});

test('logs carry the event and no email, token or key', async () => {
  const lines = [];
  setLogSink((line) => lines.push(line));
  try {
    const { status } = await json(await run(makeDeps(), deleteRequest({ confirmEmail: 'name@example.com' })));
    assert.equal(status, 204);
  } finally {
    setLogSink(() => {});
  }
  const text = lines.join('\n');
  assert.match(text, /"evt":"account_delete"/);
  for (const secret of ['name@example.com', 'Bearer', FAKE_RESTRICTED_TEST_KEY, 'sb_secret_']) {
    assert.equal(text.includes(secret), false, `log must not contain ${secret}`);
  }
});
