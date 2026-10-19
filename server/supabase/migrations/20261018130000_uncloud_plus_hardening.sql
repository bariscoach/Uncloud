-- Uncloud Plus hardening (server review L1 and M6). Runs after 20261018120000_uncloud_plus.sql.

-- L1: explicit grants instead of relying on Supabase's default privileges. TRUNCATE, REFERENCES and
-- TRIGGER are removed from the API roles; the server (service_role) gets the full set it needs.
revoke all on public.customers, public.entitlements from anon, authenticated;
grant select on public.customers, public.entitlements to authenticated;
grant select, insert, update, delete on public.customers, public.entitlements to service_role;
grant select, insert, update, delete on public.stripe_events to service_role;

-- M6: fixed-window request counters for the public Checkout endpoints. Written only by the server.
create table public.rate_limits (
  key          text primary key,
  window_start timestamptz not null,
  hits         integer not null default 0
);
alter table public.rate_limits enable row level security;
revoke all on public.rate_limits from anon, authenticated;
grant select, insert, update, delete on public.rate_limits to service_role;

-- Counts one request for `p_key` and reports whether it is within `p_limit` for the current window.
-- A window that has passed starts again at 1.
create or replace function public.consume_rate_limit(p_key text, p_limit integer, p_window_seconds integer)
returns boolean
language plpgsql security definer set search_path = ''
as $$
declare
  v_hits integer;
begin
  insert into public.rate_limits as r (key, window_start, hits)
  values (p_key, now(), 1)
  on conflict (key) do update set
    window_start = case when r.window_start <= now() - make_interval(secs => p_window_seconds)
                        then now() else r.window_start end,
    hits         = case when r.window_start <= now() - make_interval(secs => p_window_seconds)
                        then 1 else r.hits + 1 end
  returning r.hits into v_hits;
  return v_hits <= p_limit;
end;
$$;
revoke all on function public.consume_rate_limit(text, integer, integer) from public, anon, authenticated;
grant execute on function public.consume_rate_limit(text, integer, integer) to service_role;
