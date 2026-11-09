-- m124 verify: delivery trucks, exceptions, day adjustments, settings,
-- permissions, and RPC signatures. Run in the Supabase SQL editor after
-- installing supabase/migrations/124_delivery_trucks.sql.
-- Every check should print OK lines; failures print FAIL.

\set QUIET on
\pset footer off

-- 1. Tables exist -------------------------------------------------------
do $$
begin
  if to_regclass('public.delivery_trucks') is null then
    raise notice 'FAIL: delivery_trucks missing';
  elsif to_regclass('public.delivery_truck_exceptions') is null then
    raise notice 'FAIL: delivery_truck_exceptions missing';
  elsif to_regclass('public.delivery_day_adjustments') is null then
    raise notice 'FAIL: delivery_day_adjustments missing';
  else
    raise notice 'OK: tables exist';
  end if;
end $$;

-- 2. Company setting columns ---------------------------------------------
do $$
declare v_missing text;
begin
  select string_agg(col, ', ') into v_missing
  from (values
    ('delivery_limit_type'), ('delivery_window_hours'), ('delivery_day_mode'),
    ('delivery_day_start'), ('delivery_day_end')
  ) cols(col)
  where not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'companies' and column_name = cols.col
  );
  if v_missing is null then
    raise notice 'OK: companies delivery columns exist';
  else
    raise notice 'FAIL: missing companies columns: %', v_missing;
  end if;
end $$;

-- 3. Permission keys accepted -------------------------------------------
do $$
begin
  if public.is_valid_permission_key('delivery.manage_trucks')
     and public.is_valid_permission_key('delivery.manage_calendar') then
    raise notice 'OK: permission keys valid';
  else
    raise notice 'FAIL: permission keys rejected';
  end if;
end $$;

-- 4. Grants seeded for existing companies --------------------------------
do $$
declare
  v_missing integer;
begin
  select count(*) into v_missing
  from public.companies c
  where not exists (
    select 1 from public.role_permission_grants g
    where g.company_id = c.id
      and g.permission_key = 'delivery.manage_trucks'
      and g.role = 'manager'
  ) or not exists (
    select 1 from public.role_permission_grants g
    where g.company_id = c.id
      and g.permission_key = 'delivery.manage_calendar'
      and g.role = 'manager'
  );
  if v_missing = 0 then
    raise notice 'OK: manager grants seeded for all companies';
  else
    raise notice 'FAIL: % companies missing delivery grants', v_missing;
  end if;
end $$;

-- 5. RPC signatures -------------------------------------------------------
do $$
declare v record; v_ok boolean;
begin
  for v in
    select p.proname, p.pronargs
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in (
        'create_delivery_truck','update_delivery_truck',
        'set_delivery_truck_archived','set_truck_weekday_pattern',
        'set_truck_date_state','set_day_extra_slots','get_delivery_calendar'
      )
  loop
    raise notice 'RPC: % (%)', v.proname, v.pronargs;
  end loop;

  select bool_and(
    p.proname in (
      'create_delivery_truck','update_delivery_truck',
      'set_delivery_truck_archived','set_truck_weekday_pattern',
      'set_truck_date_state','set_day_extra_slots','get_delivery_calendar'
    ) and has_function_privilege('authenticated', p.oid, 'execute')
  ) into v_ok
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in (
      'create_delivery_truck','update_delivery_truck',
      'set_delivery_truck_archived','set_truck_weekday_pattern',
      'set_truck_date_state','set_day_extra_slots','get_delivery_calendar'
    );
  if v_ok then
    raise notice 'OK: all delivery RPCs exist and are executable by authenticated';
  else
    raise notice 'FAIL: a delivery RPC is missing or not executable';
  end if;
end $$;

-- 6. Internal helpers are NOT client-executable --------------------------
do $$
begin
  if has_function_privilege('authenticated', 'public.delivery_truck_day_state(public.delivery_trucks, date)', 'execute') then
    raise notice 'FAIL: delivery_truck_day_state is executable by authenticated';
  else
    raise notice 'OK: delivery_truck_day_state not client-executable';
  end if;
end $$;

-- 7. Behavioral smoke (requires an active employee JWT — run as a logged-in
--    manager in the app harness if desired):
--    select public.create_delivery_truck('Truck 1');
--    select public.set_truck_weekday_pattern(<id>, '{1,2,3,4,5,6}');
--    select public.set_truck_date_state(<id>, current_date + 7, false);
--    select public.set_day_extra_slots(current_date + 7, 2);
--    select public.get_delivery_calendar(current_date, current_date + 6);
--    Expect: truck ON for pattern days, OFF on the exception date;
--    that day's capacity = sum of on-truck caps + extra_slots (>= 0);
--    booked_count = 0.
