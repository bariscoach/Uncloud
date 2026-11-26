-- Issued license keys and revocations. Service role only. No Uncloud account is required.
-- Apply before the Stripe webhook can store a key: `supabase db push` from server/.

create table if not exists public.license_issuances (
  session_id text primary key,
  jti text not null unique,
  payment_intent text,
  tier text not null,
  seats integer not null,
  email text,
  license_key text not null,
  emailed_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists license_issuances_payment_intent
  on public.license_issuances (payment_intent);

create table if not exists public.license_revocations (
  jti text primary key,
  reason text,
  revoked_at timestamptz not null default now()
);

alter table public.license_issuances enable row level security;
alter table public.license_revocations enable row level security;
