import { test } from 'node:test';
import assert from 'node:assert/strict';
import { route, readJSON, apiError, ApiError } from '../lib/http.js';

test('the route guard answers other methods with a JSON 405 and Allow', async () => {
  const handler = route('POST', () => new Response('ok'));
  const response = await handler(new Request('https://x.test/v1/x', { method: 'DELETE' }));
  assert.equal(response.status, 405);
  assert.equal(response.headers.get('allow'), 'POST');
  assert.deepEqual(await response.json(), { error: { code: 'method_not_allowed', message: 'This method is not allowed here.' } });
});

test('an ApiError becomes its envelope', async () => {
  const handler = route('GET', () => { throw apiError('no_subscription', 409); });
  const response = await handler(new Request('https://x.test/v1/x'));
  assert.equal(response.status, 409);
  assert.equal((await response.json()).error.code, 'no_subscription');
});

test('an unexpected error is a generic 500 with no detail', async () => {
  const handler = route('GET', () => { throw new Error('secret internal detail'); });
  const response = await handler(new Request('https://x.test/v1/x'));
  assert.equal(response.status, 500);
  const text = await response.text();
  assert.doesNotMatch(text, /internal detail/);
  assert.deepEqual(JSON.parse(text), { error: { code: 'server_error', message: 'Something went wrong. Try again later.' } });
});

test('readJSON rejects non-JSON, arrays and bodies over 16 KB', async () => {
  const bad = (body) => readJSON(new Request('https://x.test/', { method: 'POST', body }));
  await assert.rejects(bad('not json'), ApiError);
  await assert.rejects(bad('[1,2]'), ApiError);
  await assert.rejects(bad('"text"'), ApiError);
  await assert.rejects(bad(JSON.stringify({ pad: 'x'.repeat(17 * 1024) })), (e) => e.status === 400);
  assert.deepEqual(await readJSON(new Request('https://x.test/', { method: 'POST', body: '{"a":1}' })), { a: 1 });
});
