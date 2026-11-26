import { test } from 'node:test';
import assert from 'node:assert/strict';
import { requestAuthCode, verifyAuthCode } from '../lib/handlers.js';
import {
  assertDeliverableSender,
  issueSignInCode,
  normalizeSignInEmail,
  sendCodeEmail,
  verifySignInCode,
} from '../lib/signin.js';
import { setLogSink } from '../lib/http.js';
import { makeDeps, invoke, json } from './helpers.js';

function mail(overrides = {}) {
  return {
    issueCode: async () => '123456',
    sendCode: async () => {},
    verifyCode: async () => ({
      access_token: 'access',
      refresh_token: 'refresh',
      expires_in: 3600,
      user: { id: 'user', email: 'name@example.com' },
    }),
    ...overrides,
  };
}

function post(path, body, ip = '203.0.113.10') {
  return new Request(`https://uncloud-api.vercel.app${path}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-real-ip': ip },
    body: JSON.stringify(body),
  });
}

test('addresses are trimmed and lowercased, and junk is refused', () => {
  assert.equal(normalizeSignInEmail('  Name@Example.COM '), 'name@example.com');
  for (const bad of ['', 'nope', 'a@b', 'a@b.c', 'has space@example.com', null, 4]) {
    assert.equal(normalizeSignInEmail(bad), null);
  }
});

test('the Resend sandbox sender is refused before any mail is sent', () => {
  assert.equal(assertDeliverableSender('Uncloud <noreply@tryuncloud.com>'), 'Uncloud <noreply@tryuncloud.com>');
  for (const from of ['onboarding@resend.dev', 'Uncloud <onboarding@resend.dev>', 'anything@resend.dev', '  ', '']) {
    assert.throws(() => assertDeliverableSender(from), (error) => error.code === 'undeliverable_sender');
  }
});

test('a new address gets a signup code, and a returning address gets a magic-link code', async () => {
  const calls = [];
  const admin = {
    async generateLink(body) {
      calls.push(body);
      if (body.type === 'magiclink' && body.email === 'new@example.com') {
        return { ok: false, status: 404, json: { error_code: 'user_not_found', msg: 'User not found' } };
      }
      return { ok: true, status: 200, json: { email_otp: '654321' } };
    },
  };
  assert.equal(await issueSignInCode(admin, 'new@example.com'), '654321');
  assert.equal(calls[0].type, 'magiclink');
  assert.equal(calls[1].type, 'signup');
  assert.equal(typeof calls[1].password, 'string');
  assert.ok(calls[1].password.length >= 16);

  calls.length = 0;
  assert.equal(await issueSignInCode(admin, 'name@example.com'), '654321');
  assert.deepEqual(calls.map((call) => call.type), ['magiclink']);
});

test('a code Supabase will not issue fails without returning a partial code', async () => {
  const admin = {
    async generateLink() {
      return { ok: true, status: 200, json: { email_otp: 'nope' } };
    },
  };
  await assert.rejects(issueSignInCode(admin, 'name@example.com'), (error) => error.code === 'code_unavailable');
});

test('the code email goes to Resend and nowhere else, and a refused send fails', async () => {
  const requests = [];
  await sendCodeEmail({
    fetchFn: async (url, init) => {
      requests.push({ url, init });
      return { ok: true, status: 200 };
    },
    apiKey: 're_test',
    from: 'Uncloud <noreply@tryuncloud.com>',
    to: 'name@example.com',
    code: '123456',
  });
  assert.equal(requests.length, 1);
  assert.equal(requests[0].url, 'https://api.resend.com/emails');
  const body = JSON.parse(requests[0].init.body);
  assert.equal(body.from, 'Uncloud <noreply@tryuncloud.com>');
  assert.deepEqual(body.to, ['name@example.com']);
  assert.match(body.text, /123456/);
  assert.match(body.text, /never receives your photos/);
  assert.equal(requests[0].init.headers.authorization, 'Bearer re_test');

  await assert.rejects(
    sendCodeEmail({
      fetchFn: async () => {
        throw new Error('should not be called');
      },
      apiKey: 're_test',
      from: 'onboarding@resend.dev',
      to: 'name@example.com',
      code: '123456',
    }),
    (error) => error.code === 'undeliverable_sender',
  );

  await assert.rejects(
    sendCodeEmail({
      fetchFn: async () => ({ ok: false, status: 403 }),
      apiKey: 're_test',
      from: 'Uncloud <noreply@tryuncloud.com>',
      to: 'name@example.com',
      code: '123456',
    }),
    (error) => error.code === 'mail_failed' && error.status === 403,
  );
});

test('verify returns the session and maps a bad or expired code', async () => {
  const admin = {
    async verifyOtp(body) {
      assert.deepEqual(body, { type: 'email', email: 'name@example.com', token: '123456' });
      return {
        ok: true,
        status: 200,
        json: { access_token: 'a', refresh_token: 'r', email_otp: '123456', user: { email: 'name@example.com' } },
      };
    },
  };
  const session = await verifySignInCode(admin, 'name@example.com', '123456');
  assert.equal(session.access_token, 'a');
  assert.equal(session.email_otp, undefined);

  const wrong = {
    async verifyOtp() {
      return { ok: false, status: 403, json: { error_code: 'otp_expired', msg: 'Token has expired or is invalid' } };
    },
  };
  await assert.rejects(verifySignInCode(wrong, 'name@example.com', '000000'), (error) => error.code === 'wrong_code');
});

test('POST /v1/auth/code emails a code and answers ok, without the code or the address in the log', async () => {
  const lines = [];
  setLogSink((line) => lines.push(line));
  const sent = [];
  const deps = makeDeps({
    mail: mail({
      sendCode: async (to, code) => {
        sent.push({ to, code });
      },
    }),
  });
  const { status, body } = await json(await invoke('POST', requestAuthCode, post('/v1/auth/code', { email: ' Name@Example.com ' }), deps));
  assert.equal(status, 200);
  assert.deepEqual(body, { ok: true });
  assert.deepEqual(sent, [{ to: 'name@example.com', code: '123456' }]);
  const logged = lines.join('\n');
  assert.match(logged, /"evt":"auth_code"/);
  assert.doesNotMatch(logged, /name@example.com/);
  assert.doesNotMatch(logged, /123456/);
  setLogSink(() => {});
});

test('a mailer that cannot deliver answers code_email_not_sent and does not pretend the code was sent', async () => {
  const deps = makeDeps({
    mail: mail({
      sendCode: async () => {
        const error = new Error('undeliverable_sender');
        error.code = 'undeliverable_sender';
        throw error;
      },
    }),
  });
  const response = await invoke('POST', requestAuthCode, post('/v1/auth/code', { email: 'name@example.com' }), deps);
  assert.equal(response.status, 503);
  assert.equal((await response.json()).error.code, 'code_email_not_sent');
});

test('an address the code service cannot issue for is the same mail failure, not a server dump', async () => {
  const deps = makeDeps({
    mail: mail({
      issueCode: async () => {
        throw new Error('supabase said Error sending confirmation email to name@example.com otp 999999');
      },
    }),
  });
  const response = await invoke('POST', requestAuthCode, post('/v1/auth/code', { email: 'name@example.com' }, '203.0.113.11'), deps);
  const body = await response.json();
  assert.equal(response.status, 503);
  assert.equal(body.error.code, 'code_email_not_sent');
  assert.doesNotMatch(JSON.stringify(body), /999999|name@example.com|confirmation email/i);
});

test('invalid code requests are 400 and do not send mail or spend the rate limit', async () => {
  let sent = 0;
  const deps = makeDeps({
    mail: mail({
      sendCode: async () => {
        sent += 1;
      },
    }),
  });
  const response = await invoke('POST', requestAuthCode, post('/v1/auth/code', { email: 'nope' }), deps);
  assert.equal(response.status, 400);
  assert.equal((await response.json()).error.code, 'invalid_email');
  assert.equal(sent, 0);
  assert.equal(deps.db.calls.length, 0);
});

test('the sixth code request from one IP is 429', async () => {
  const deps = makeDeps({ mail: mail() });
  for (let i = 0; i < 5; i += 1) {
    const response = await invoke('POST', requestAuthCode, post('/v1/auth/code', { email: `user${i}@example.com` }, '203.0.113.20'), deps);
    assert.equal(response.status, 200);
  }
  const limited = await invoke('POST', requestAuthCode, post('/v1/auth/code', { email: 'user5@example.com' }, '203.0.113.20'), deps);
  assert.equal(limited.status, 429);
  assert.equal(limited.headers.get('retry-after'), '3600');
});

test('POST /v1/auth/verify returns the session, and a bad code is wrong_code', async () => {
  const deps = makeDeps({ mail: mail() });
  const ok = await json(await invoke('POST', verifyAuthCode, post('/v1/auth/verify', { email: 'name@example.com', token: '123456' }), deps));
  assert.equal(ok.status, 200);
  assert.equal(ok.body.access_token, 'access');
  assert.equal(ok.body.refresh_token, 'refresh');

  const bad = await invoke('POST', verifyAuthCode, post('/v1/auth/verify', { email: 'name@example.com', token: '12' }, '203.0.113.30'), deps);
  assert.equal(bad.status, 400);
  assert.equal((await bad.json()).error.code, 'wrong_code');
});

test('GET on the auth routes is a JSON 405', async () => {
  const { GET: codeGet } = await import('../api/v1/auth/code.js');
  const { GET: verifyGet } = await import('../api/v1/auth/verify.js');
  for (const handler of [codeGet, verifyGet]) {
    const response = await handler(new Request('https://uncloud-api.vercel.app/v1/auth/code'));
    assert.equal(response.status, 405);
    assert.equal((await response.json()).error.code, 'method_not_allowed');
  }
});
