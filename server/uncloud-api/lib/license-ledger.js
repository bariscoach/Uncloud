// Issued and revoked licenses. The service role is the only reader. Tests use memoryLicenseLedger.

import { createSupabase } from './supabase.js';

export function supabaseLicenseLedger(env = process.env) {
  const url = env.SUPABASE_URL;
  const secret = env.SUPABASE_SECRET_KEY;
  const publishable = env.SUPABASE_PUBLISHABLE_KEY;
  if (!url || !secret || !publishable) {
    return {
      async findBySession() { throw new Error('ledger_not_configured'); },
      async findByPaymentIntent() { throw new Error('ledger_not_configured'); },
      async save() { throw new Error('ledger_not_configured'); },
      async markEmailed() { throw new Error('ledger_not_configured'); },
      async isRevoked() { throw new Error('ledger_not_configured'); },
      async revoke() { throw new Error('ledger_not_configured'); },
    };
  }
  const db = createSupabase({ url, publishableKey: publishable, secretKey: secret });
  const mode = { service: true };
  return {
    async findBySession(sessionId) {
      const rows = await db.select('license_issuances', { session_id: sessionId }, mode);
      return rows[0] ? fromRow(rows[0]) : null;
    },
    async findByPaymentIntent(paymentIntent) {
      if (!paymentIntent) return null;
      const rows = await db.select('license_issuances', { payment_intent: paymentIntent }, mode);
      return rows[0] ? fromRow(rows[0]) : null;
    },
    async save(row) {
      await db.upsert('license_issuances', toRow(row), { onConflict: 'session_id' }, mode);
    },
    async markEmailed(sessionId, at) {
      await db.upsert('license_issuances', { session_id: sessionId, emailed_at: at }, { onConflict: 'session_id' }, mode);
    },
    async isRevoked(jti) {
      const rows = await db.select('license_revocations', { jti }, mode);
      return rows.length > 0;
    },
    async revoke(jti, reason) {
      await db.upsert('license_revocations', {
        jti,
        reason,
        revoked_at: new Date().toISOString(),
      }, { onConflict: 'jti' }, mode);
    },
  };
}

function fromRow(row) {
  return {
    sessionId: row.session_id,
    jti: row.jti,
    paymentIntent: row.payment_intent,
    tier: row.tier,
    seats: row.seats,
    email: row.email,
    key: row.license_key,
    emailedAt: row.emailed_at,
  };
}

function toRow(row) {
  return {
    session_id: row.sessionId,
    jti: row.jti,
    payment_intent: row.paymentIntent,
    tier: row.tier,
    seats: row.seats,
    email: row.email,
    license_key: row.key,
    emailed_at: row.emailedAt,
  };
}
