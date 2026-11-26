// Optional email sign-in. The API asks Supabase for a one-time code and sends that code itself.
// Supabase's own mailer is not used: it was configured with Resend's sandbox sender
// (onboarding@resend.dev), which refuses every address except the Resend account owner and
// made sign-up and sign-in fail for everyone else (issues #1 and #2).
//
// Only the email address and the code are handled here. Photos never come through this service.

import { randomBytes } from 'node:crypto';
import { apiError } from './http.js';

const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;
const CONTROL = /[\u0000-\u001f\u007f]/;
// Resend's shared test domain can deliver only to the account that created the API key.
const SANDBOX_SENDER = /@resend\.dev\s*>?$/i;

export function normalizeSignInEmail(value) {
  if (typeof value !== 'string') return null;
  const email = value.normalize('NFC').trim().toLowerCase();
  if (email.length < 3 || email.length > 254 || CONTROL.test(email) || !EMAIL.test(email)) return null;
  return email;
}

// Throws before any mail is sent when the From address is missing or is Resend's sandbox sender.
export function assertDeliverableSender(from) {
  const value = typeof from === 'string' ? from.trim() : '';
  if (value === '' || SANDBOX_SENDER.test(value)) {
    const error = new Error('undeliverable_sender');
    error.code = 'undeliverable_sender';
    throw error;
  }
  return value;
}

export function createAuthAdmin({ url, publishableKey, secretKey, fetchFn = globalThis.fetch }) {
  const base = url.replace(/\/+$/, '');

  async function post(path, body, service) {
    const key = service ? secretKey : publishableKey;
    const headers = {
      apikey: key,
      accept: 'application/json',
      'content-type': 'application/json',
    };
    if (service) headers.authorization = `Bearer ${secretKey}`;
    const response = await fetchFn(`${base}${path}`, {
      method: 'POST',
      headers,
      body: JSON.stringify(body),
    });
    const text = await response.text();
    let json = null;
    if (text !== '') {
      try {
        json = JSON.parse(text);
      } catch {
        json = null;
      }
    }
    return { ok: response.ok, status: response.status, json };
  }

  return {
    generateLink: (body) => post('/auth/v1/admin/generate_link', body, true),
    verifyOtp: (body) => post('/auth/v1/verify', body, false),
  };
}

function missingUser(result) {
  const code = result.json?.error_code || result.json?.code || result.json?.error;
  const msg = String(result.json?.msg || result.json?.message || '').toLowerCase();
  return result.status === 404 || code === 'user_not_found' || msg.includes('user not found');
}

function oneTimeCode(json) {
  const code = json?.email_otp ?? json?.properties?.email_otp;
  return typeof code === 'string' && /^\d{6,10}$/.test(code) ? code : null;
}

// Returns the 6-digit code. Creates the Supabase user when the address is new.
// The code is not logged and is not returned to the app; the caller emails it.
export async function issueSignInCode(admin, email) {
  let result = await admin.generateLink({ type: 'magiclink', email });
  if (!result.ok && missingUser(result)) {
    result = await admin.generateLink({
      type: 'signup',
      email,
      password: randomBytes(24).toString('base64url'),
    });
  }
  const code = result.ok ? oneTimeCode(result.json) : null;
  if (!code) {
    const error = new Error('code_unavailable');
    error.code = 'code_unavailable';
    throw error;
  }
  return code;
}

export async function sendCodeEmail({ fetchFn = globalThis.fetch, apiKey, from, to, code }) {
  const sender = assertDeliverableSender(from);
  const response = await fetchFn('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      authorization: `Bearer ${apiKey}`,
      'content-type': 'application/json',
      accept: 'application/json',
    },
    body: JSON.stringify({
      from: sender,
      to: [to],
      subject: `Your Uncloud code is ${code}`,
      text: [
        `Your Uncloud sign-in code is ${code}.`,
        'Enter it in Uncloud. It expires in 10 minutes.',
        'If you didn’t ask for a code, you can ignore this email.',
        'Uncloud never receives your photos.',
      ].join('\n'),
    }),
  });
  if (!response.ok) {
    const error = new Error('mail_failed');
    error.code = 'mail_failed';
    error.status = response.status;
    throw error;
  }
}

export async function verifySignInCode(admin, email, token) {
  const result = await admin.verifyOtp({ type: 'email', email, token });
  if (!result.ok) {
    // Supabase uses otp_expired for a wrong code as well as an old one. The app decides
    // which sentence to show from the challenge's own expiry, so this stays one refusal.
    if (result.status === 429) throw apiError('rate_limited', 429);
    throw apiError('wrong_code', 400);
  }
  const session = result.json;
  if (!session || typeof session.access_token !== 'string' || typeof session.refresh_token !== 'string') {
    throw apiError('server_error', 502);
  }
  delete session.email_otp;
  return session;
}
