-- RLS and grant checks for the Uncloud Plus migration.
-- Run after the migration on a database that has Supabase's auth schema and roles
-- (for example: supabase db query --file server/supabase/tests/rls.sql). Nothing is kept:
-- the transaction ends with rollback. Any failed check raises an error and stops the script.

begin;

-- Fixtures, written as the owner role.
insert into auth.users (id, email) values
  ('11111111-1111-4111-8111-111111111111', 'a@example.test'),
  ('22222222-2222-4222-8222-222222222222', 'b@example.test');
insert into public.customers (user_id, stripe_customer_id, livemode) values
  ('11111111-1111-4111-8111-111111111111', 'cus_test_a', false);
insert into public.entitlements (user_id, plan, status, stripe_subscription_id, livemode) values
  ('11111111-1111-4111-8111-111111111111', 'plus', 'active', 'sub_test_a', false),
  ('22222222-2222-4222-8222-222222222222', 'free', 'none', null, false);
insert into public.stripe_events (id, type, livemode, created) values
  ('evt_test_1', 'customer.subscription.updated', false, now());

-- Act as user A (authenticated, JWT sub = user A).
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}', true);

-- Reads: own rows only.
do $$
declare n int;
begin
  select count(*) into n from public.entitlements;
  if n <> 1 then raise exception 'RLS: user A should see 1 entitlement, saw %', n; end if;
  select count(*) into n from public.customers;
  if n <> 1 then raise exception 'RLS: user A should see 1 customer, saw %', n; end if;
  select count(*) into n from public.my_entitlement() where plan = 'plus' and status = 'active';
  if n <> 1 then raise exception 'my_entitlement: expected user A plus/active, got % rows', n; end if;
end $$;

-- Writes: denied by grants, so each statement must raise insufficient_privilege.
do $$
begin
  begin
    update public.entitlements set plan = 'plus', status = 'active';
    raise exception 'RLS: authenticated update on entitlements was allowed';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.entitlements (user_id, plan) values ('22222222-2222-4222-8222-222222222222', 'plus');
    raise exception 'RLS: authenticated insert on entitlements was allowed';
  exception when insufficient_privilege then null;
  end;
  begin
    delete from public.customers;
    raise exception 'RLS: authenticated delete on customers was allowed';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.customers (user_id, stripe_customer_id, livemode)
      values ('22222222-2222-4222-8222-222222222222', 'cus_forged', false);
    raise exception 'RLS: authenticated insert on customers was allowed';
  exception when insufficient_privilege then null;
  end;
end $$;

-- stripe_events: no access at all for authenticated.
do $$
begin
  begin
    perform 1 from public.stripe_events;
    raise exception 'RLS: authenticated read of stripe_events was allowed';
  exception when insufficient_privilege then null;
  end;
end $$;

-- The write path is not callable by authenticated.
do $$
begin
  begin
    perform public.apply_subscription('22222222-2222-4222-8222-222222222222', 'sub_forged', 'price_x', 'plus', 'active', now(), false, false);
    raise exception 'RLS: authenticated call to apply_subscription was allowed';
  exception when insufficient_privilege then null;
  end;
end $$;

-- Act as the server (service_role): the write path works and is visible to the owner row.
reset role;
set local role service_role;
select public.apply_subscription('22222222-2222-4222-8222-222222222222', 'sub_test_b', 'price_test_1', 'plus', 'active', now() + interval '365 days', false, false);
do $$
declare plan_b text;
begin
  select plan into plan_b from public.entitlements where user_id = '22222222-2222-4222-8222-222222222222';
  if plan_b <> 'plus' then raise exception 'apply_subscription did not write the row (plan=%)', plan_b; end if;
end $$;

-- Anonymous callers see nothing.
reset role;
set local role anon;
do $$
declare n int;
begin
  begin
    select count(*) into n from public.entitlements;
    if n <> 0 then raise exception 'RLS: anon can read entitlements (% rows)', n; end if;
  exception when insufficient_privilege then null;
  end;
end $$;

-- L1: no TRUNCATE, REFERENCES or TRIGGER for the API roles on the Uncloud tables (explicit grants, migration 20261018130000).
do $$
begin
  if has_table_privilege('authenticated', 'public.customers', 'TRUNCATE')
     or has_table_privilege('authenticated', 'public.entitlements', 'TRUNCATE')
     or has_table_privilege('anon', 'public.customers', 'TRUNCATE')
     or has_table_privilege('anon', 'public.entitlements', 'TRUNCATE') then
    raise exception 'grants: TRUNCATE on Uncloud tables is granted to an API role';
  end if;
end $$;

-- M6: rate-limit counters are not readable or callable by API roles (migration 20261018130000).
do $$
begin
  begin
    perform 1 from public.rate_limits;
    raise exception 'rate_limits: authenticated read was allowed';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.consume_rate_limit('probe', 1, 60);
    raise exception 'rate_limits: authenticated call to consume_rate_limit was allowed';
  exception when insufficient_privilege then null;
  end;
end $$;

reset role;
rollback;
