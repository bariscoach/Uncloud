-- Uncloud Plus: customers, entitlements and webhook idempotency (plan 3.2).
-- Written only by the server (service role). Users may read their own rows through RLS.

-- Stripe customer per Supabase user.
create table public.customers (
  user_id            uuid primary key references auth.users (id) on delete cascade,
  stripe_customer_id text not null unique,
  livemode           boolean not null,
  created_at         timestamptz not null default now()
);

-- One row per user: the plan as last derived from Stripe. Written only by the server (service role).
create table public.entitlements (
  user_id                uuid primary key references auth.users (id) on delete cascade,
  plan                   text not null default 'free'  check (plan in ('free', 'plus')),
  status                 text not null default 'none'
                         check (status in ('none', 'active', 'trialing', 'pastDue', 'canceled', 'expired')),
  current_period_end     timestamptz,
  cancel_at_period_end   boolean not null default false,
  stripe_subscription_id text unique,
  stripe_price_id        text,
  livemode               boolean not null default false,
  synced_at              timestamptz not null default now()
);

-- Webhook idempotency: an event id is recorded only after it was applied.
create table public.stripe_events (
  id           text primary key,
  type         text not null,
  livemode     boolean not null,
  created      timestamptz not null,
  processed_at timestamptz not null default now()
);

alter table public.customers     enable row level security;
alter table public.entitlements  enable row level security;
alter table public.stripe_events enable row level security;

-- Users can read their own rows; nobody but the service role writes.
create policy "read own customer"    on public.customers    for select to authenticated using ((select auth.uid()) = user_id);
create policy "read own entitlement" on public.entitlements for select to authenticated using ((select auth.uid()) = user_id);
-- stripe_events: no policies, so no access for anon/authenticated.

revoke insert, update, delete on public.customers, public.entitlements from anon, authenticated;
revoke all on public.stripe_events from anon, authenticated;

-- What GET /v1/me reads, with the caller's JWT (RLS applies). Always one row for a signed-in user.
create or replace function public.my_entitlement()
returns table (plan text, status text, current_period_end timestamptz, cancel_at_period_end boolean)
language sql stable security invoker set search_path = ''
as $$
  select coalesce(e.plan, 'free'), coalesce(e.status, 'none'), e.current_period_end, coalesce(e.cancel_at_period_end, false)
  from (select (select auth.uid()) as uid) u
  left join public.entitlements e on e.user_id = u.uid
  where u.uid is not null;
$$;
revoke all on function public.my_entitlement() from public, anon;
grant execute on function public.my_entitlement() to authenticated;

-- The server's single write path (secret key / service_role only).
create or replace function public.apply_subscription(
  p_user_id uuid, p_subscription_id text, p_price_id text, p_plan text, p_status text,
  p_current_period_end timestamptz, p_cancel_at_period_end boolean, p_livemode boolean)
returns void language sql security definer set search_path = ''
as $$
  insert into public.entitlements as e (user_id, plan, status, current_period_end, cancel_at_period_end,
                                        stripe_subscription_id, stripe_price_id, livemode, synced_at)
  values (p_user_id, p_plan, p_status, p_current_period_end, p_cancel_at_period_end,
          p_subscription_id, p_price_id, p_livemode, now())
  on conflict (user_id) do update set
    plan = excluded.plan, status = excluded.status, current_period_end = excluded.current_period_end,
    cancel_at_period_end = excluded.cancel_at_period_end, stripe_subscription_id = excluded.stripe_subscription_id,
    stripe_price_id = excluded.stripe_price_id, livemode = excluded.livemode, synced_at = now();
$$;
revoke all on function public.apply_subscription(uuid, text, text, text, text, timestamptz, boolean, boolean) from public, anon, authenticated;
grant execute on function public.apply_subscription(uuid, text, text, text, text, timestamptz, boolean, boolean) to service_role;
