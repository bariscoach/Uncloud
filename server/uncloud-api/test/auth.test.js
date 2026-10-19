import { test } from 'node:test';
import assert from 'node:assert/strict';
import { SignJWT, createLocalJWKSet, exportJWK, generateKeyPair } from 'jose';
import { verifyAccessToken, verifyRequest } from '../lib/auth.js';
import { ApiError } from '../lib/http.js';
import { USER_A } from './helpers.js';

const SUPABASE_URL = 'https://example.supabase.test';
const ISSUER = `${SUPABASE_URL}/auth/v1`;

const { publicKey, privateKey } = await generateKeyPair('ES256');
const publicJwk = { ...(await exportJWK(publicKey)), kid: 'test-kid', alg: 'ES256' };
const jwks = createLocalJWKSet({ keys: [publicJwk] });

// Another key, to prove a token signed by a stranger is refused.
const stranger = await generateKeyPair('ES256');

async function token({
  claims = { role: 'authenticated', email: 'name@example.com' },
  subject = USER_A,
  issuer = ISSUER,
  audience = 'authenticated',
  expires = '1h',
  key = privateKey,
} = {}) {
  let jwt = new SignJWT(claims)
    .setProtectedHeader({ alg: 'ES256', kid: 'test-kid' })
    .setIssuer(issuer)
    .setAudience(audience)
    .setIssuedAt();
  if (subject !== null) jwt = jwt.setSubject(subject);
  if (expires !== null) jwt = jwt.setExpirationTime(expires);
  return jwt.sign(key);
}

const deps = { supabaseUrl: SUPABASE_URL, jwks };

async function expectUnauthorized(promise) {
  await assert.rejects(promise, (error) => {
    assert.ok(error instanceof ApiError);
    assert.equal(error.code, 'unauthorized');
    assert.equal(error.status, 401);
    // No detail about why the token failed.
    assert.equal(error.message, 'Sign in again to continue.');
    return true;
  });
}

test('a valid token yields the user id, email and the raw token', async () => {
  const jwt = await token();
  const auth = await verifyAccessToken(jwt, deps);
  assert.deepEqual(auth, { userId: USER_A, email: 'name@example.com', jwt });
});

test('missing or malformed Authorization header is refused', async () => {
  const none = new Request('https://x.test/v1/me');
  await expectUnauthorized(verifyRequest(none, deps));
  const basic = new Request('https://x.test/v1/me', { headers: { authorization: 'Basic abc' } });
  await expectUnauthorized(verifyRequest(basic, deps));
  const spaces = new Request('https://x.test/v1/me', { headers: { authorization: 'Bearer a b' } });
  await expectUnauthorized(verifyRequest(spaces, deps));
});

test('a valid bearer header goes through verifyRequest', async () => {
  const jwt = await token();
  const request = new Request('https://x.test/v1/me', { headers: { authorization: `Bearer ${jwt}` } });
  const auth = await verifyRequest(request, deps);
  assert.equal(auth.userId, USER_A);
});

test('garbage token is refused', async () => {
  await expectUnauthorized(verifyAccessToken('not-a-jwt', deps));
});

test('wrong issuer is refused', async () => {
  await expectUnauthorized(verifyAccessToken(await token({ issuer: 'https://evil.example/auth/v1' }), deps));
});

test('wrong audience is refused', async () => {
  await expectUnauthorized(verifyAccessToken(await token({ audience: 'anon' }), deps));
});

test('expired token is refused', async () => {
  const past = Math.floor(Date.now() / 1000) - 3600;
  await expectUnauthorized(verifyAccessToken(await token({ expires: past }), deps));
});

test('role other than authenticated is refused', async () => {
  await expectUnauthorized(verifyAccessToken(await token({ claims: { role: 'anon', email: 'a@b.co' } }), deps));
});

test('a subject that is not a UUID is refused', async () => {
  await expectUnauthorized(verifyAccessToken(await token({ subject: 'not-a-uuid' }), deps));
});

test('a missing email claim is refused', async () => {
  await expectUnauthorized(verifyAccessToken(await token({ claims: { role: 'authenticated' } }), deps));
});

test('a token signed by another key is refused', async () => {
  await expectUnauthorized(verifyAccessToken(await token({ key: stranger.privateKey }), deps));
});
