// Signed Uncloud license keys. No account is required.
//
// A key is `UC1.<base64url(payload)>.<base64url(ed25519 signature)>`.
// The payload is canonical JSON: emailHash (optional), iat, jti, seats, tier, v.
// The signature covers those exact bytes. An unsigned or reshaped key is rejected.
//
// LICENSE_SIGNING_PRIVATE_KEY is a PKCS#8 Ed25519 private key, base64. It is never
// committed. Tests use the keypair in test/fixtures/license-key.js, which is public
// and must be rotated before license limits are turned on in a release build.

import { createHash, createPrivateKey, createPublicKey, sign, verify } from 'node:crypto';
import { json, logEvent, readText } from './http.js';

export const FREE_ITEM_CAP = 1000;
export const SIGNATURE_PREFIX = 'UC1';

const TIERS = ['plus', 'pro', 'family'];
const SEATS = { plus: 1, pro: 2, family: 5 };
const PAYLOAD_KEYS = ['emailHash', 'iat', 'jti', 'seats', 'tier', 'v'];

const PLUS_FEATURES = [
  'unlimitedExport',
  'automaticBackups',
  'allLayouts',
  'mapPlaceBrowse',
  'xmpSidecars',
];
const PRO_FEATURES = [
  ...PLUS_FEATURES,
  'verifiedICloudCleanup',
  'verifyBackup',
  'secondDestination',
  'emailSupport',
];

export function featuresFor(tier) {
  if (tier === 'plus') return [...PLUS_FEATURES];
  if (tier === 'pro' || tier === 'family') return [...PRO_FEATURES];
  return [];
}

export function seatsFor(tier) {
  return SEATS[tier] ?? null;
}

export function canonicalLicenseJSON(payload) {
  const ordered = {};
  for (const key of PAYLOAD_KEYS) {
    if (payload[key] !== undefined && payload[key] !== null) ordered[key] = payload[key];
  }
  return JSON.stringify(ordered);
}

export function base64url(bytes) {
  return Buffer.from(bytes).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
}

export function base64urlDecode(text) {
  if (typeof text !== 'string' || text.length === 0 || /[^A-Za-z0-9_-]/.test(text)) return null;
  const padded = text.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - (text.length % 4)) % 4);
  const bytes = Buffer.from(padded, 'base64');
  if (bytes.length === 0 || base64url(bytes) !== text) return null;
  return bytes;
}

export function emailHash(email) {
  if (typeof email !== 'string') return null;
  const normalized = email.trim().toLowerCase();
  if (normalized.length === 0) return null;
  return createHash('sha256').update(normalized).digest('hex');
}

export function loadPrivateKey(privateKeyBase64) {
  return createPrivateKey({
    key: Buffer.from(privateKeyBase64, 'base64'),
    format: 'der',
    type: 'pkcs8',
  });
}

export function publicKeyFromPrivate(privateKey) {
  return createPublicKey(privateKey);
}

export function mintLicense({ tier, seats, jti, iat, email, privateKey }) {
  if (!TIERS.includes(tier) || seats !== SEATS[tier]) {
    throw new Error('tier and seats do not match');
  }
  if (typeof jti !== 'string' || jti.length < 4 || jti.length > 128) throw new Error('jti');
  if (!Number.isInteger(iat)) throw new Error('iat');
  const payload = { v: 1, tier, seats, jti, iat };
  const hash = emailHash(email);
  if (hash) payload.emailHash = hash;
  const bytes = Buffer.from(canonicalLicenseJSON(payload));
  const signature = sign(null, bytes, privateKey);
  return `${SIGNATURE_PREFIX}.${base64url(bytes)}.${base64url(signature)}`;
}

// Returns the payload when the signature matches `publicKey`, otherwise null.
export function readSignedLicense(raw, publicKey) {
  if (typeof raw !== 'string' || !publicKey) return null;
  const token = raw.trim();
  const parts = token.split('.');
  if (parts.length !== 3 || parts[0] !== SIGNATURE_PREFIX) return null;
  const payloadBytes = base64urlDecode(parts[1]);
  const signature = base64urlDecode(parts[2]);
  if (!payloadBytes || !signature || signature.length !== 64) return null;
  const ok = verify(null, payloadBytes, publicKey, signature);
  if (!ok) return null;
  let payload;
  try {
    payload = JSON.parse(payloadBytes.toString('utf8'));
  } catch {
    return null;
  }
  if (!payload || payload.v !== 1 || !TIERS.includes(payload.tier)) return null;
  if (payload.seats !== SEATS[payload.tier]) return null;
  if (typeof payload.jti !== 'string' || payload.jti.length < 4 || payload.jti.length > 128) return null;
  if (!Number.isInteger(payload.iat)) return null;
  if (payload.emailHash !== undefined && !/^[a-f0-9]{64}$/.test(payload.emailHash)) return null;
  // The signed bytes must be the canonical form, so a reordered payload cannot pass.
  if (payloadBytes.toString('utf8') !== canonicalLicenseJSON(payload)) return null;
  return {
    key: token,
    tier: payload.tier,
    seats: payload.seats,
    jti: payload.jti,
    iat: payload.iat,
    emailHash: payload.emailHash ?? null,
  };
}

export function verifyLicense(raw, { publicKey, isRevoked }) {
  const parsed = readSignedLicense(raw, publicKey);
  if (!parsed) {
    return { valid: false, mode: 'signed', reason: 'invalid_signature', accountRequired: false };
  }
  if (isRevoked?.(parsed.jti)) {
    return { valid: false, mode: 'signed', reason: 'revoked', jti: parsed.jti, accountRequired: false };
  }
  return {
    valid: true,
    mode: 'signed',
    tier: parsed.tier,
    seats: parsed.seats,
    jti: parsed.jti,
    iat: parsed.iat,
    features: featuresFor(parsed.tier),
    accountRequired: false,
  };
}

export async function verifyLicenseRequest(request, deps) {
  let body;
  try {
    body = JSON.parse(await readText(request, 16 * 1024));
  } catch {
    return json({ error: { code: 'bad_request', message: 'The request body must be JSON.' } }, 400);
  }
  if (!body || typeof body !== 'object' || Array.isArray(body)) {
    return json({ error: { code: 'bad_request', message: 'The request body must be a JSON object.' } }, 400);
  }
  if (!deps?.publicKey) {
    logEvent({ evt: 'license_verify', result: 'not_configured' });
    return json({ error: { code: 'not_configured', message: 'License verification is not configured.' } }, 503);
  }
  const parsed = readSignedLicense(body.key, deps.publicKey);
  let revoked = false;
  if (parsed && deps.isRevoked) {
    try {
      revoked = await deps.isRevoked(parsed.jti);
    } catch {
      logEvent({ evt: 'license_verify', result: 'not_configured' });
      return json({ error: { code: 'not_configured', message: 'License verification is not configured.' } }, 503);
    }
  }
  const checked = verifyLicense(body.key, {
    publicKey: deps.publicKey,
    isRevoked: () => revoked,
  });
  logEvent({ evt: 'license_verify', result: checked.valid ? 'valid' : checked.reason, mode: 'signed' });
  return json(checked);
}

export function memoryLicenseLedger() {
  const issuances = new Map();
  const byIntent = new Map();
  const revoked = new Map();
  return {
    async findBySession(sessionId) {
      return issuances.get(sessionId) ?? null;
    },
    async findByPaymentIntent(paymentIntent) {
      if (!paymentIntent) return null;
      return byIntent.get(paymentIntent) ?? null;
    },
    async save(row) {
      issuances.set(row.sessionId, row);
      if (row.paymentIntent) byIntent.set(row.paymentIntent, row);
    },
    async markEmailed(sessionId, at) {
      const row = issuances.get(sessionId);
      if (row) row.emailedAt = at;
    },
    async isRevoked(jti) {
      return revoked.has(jti);
    },
    async revoke(jti, reason) {
      revoked.set(jti, { reason, at: new Date().toISOString() });
    },
  };
}
