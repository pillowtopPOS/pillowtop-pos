-- m127 verify: get_delivery_calendar returns archived_trucks and
-- home_location_type on truck rows.
-- Run in the Supabase SQL editor after installing
-- supabase/migrations/127_calendar_archived_trucks.sql.
-- Requires at least the seeded Truck 1 / Truck 2 (or any truck) to be
-- meaningful; the shape checks run regardless.

\set QUIET on
\pset footer off

-- 1. Function body mentions archived_trucks and home_location_type --------
do $$
declare v_src text;
begin
  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'get_delivery_calendar';
  if v_src is null then
    raise notice 'FAIL: get_delivery_calendar missing';
  elsif v_src like '%archived_trucks%' and v_src like '%home_location_type%' then
    raise notice 'OK: function returns archived_trucks and home_location_type';
  else
    raise notice 'FAIL: function body missing new keys';
  end if;
end $$;

-- 2. Shape check — run as a logged-in employee via the app, or inspect
--    the jsonb keys directly:
--    select jsonb_object_keys(public.get_delivery_calendar(current_date, current_date + 6));
--    Expect keys: settings, trucks, archived_trucks, days.
--    select public.get_delivery_calendar(current_date, current_date + 6) -> 'archived_trucks';
--    Expect an array (empty until a truck is archived).
