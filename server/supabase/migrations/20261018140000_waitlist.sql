-- Launch list (landing page). Runs after 20261018130000_uncloud_plus_hardening.sql.
-- Email is the primary key, so a repeat sign-up cannot create a second row. No user agent, no IP.

create table public.waitlist (
  email      text primary key
             check (char_length(email) between 3 and 254 and email = lower(email) and position('@' in email) > 1),
  source     text not null default 'landing' check (source ~ '^[a-z0-9_-]{1,32}$'),
  created_at timestamptz not null default now()
);

-- No policies: anon and authenticated get nothing. Only the service role (which bypasses RLS) reads or writes.
alter table public.waitlist enable row level security;
revoke all on public.waitlist from public, anon, authenticated;
grant select, insert on public.waitlist to service_role;

comment on table public.waitlist is 'Launch list emails from the landing page. Service role only.';
