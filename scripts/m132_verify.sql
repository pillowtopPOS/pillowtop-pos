-- m132 verification — READ ONLY. Run after 132 in the Supabase SQL editor.
-- Every check should return the expected value; nothing here writes.

-- 1. Objects exist
select 'table:delivery_day_plans' as check, count(*) as ok
from information_schema.tables
where table_schema='public' and table_name='delivery_day_plans'
union all
select 'table:delivery_route_events', count(*)
from information_schema.tables
where table_schema='public' and table_name='delivery_route_events'
union all
select 'column:delivery_stops.truck_id', count(*)
from information_schema.columns
where table_schema='public' and table_name='delivery_stops' and column_name='truck_id'
union all
select 'column:delivery_stops.route_position', count(*)
from information_schema.columns
where table_schema='public' and table_name='delivery_stops' and column_name='route_position'
union all
select 'column:delivery_stops.window_start', count(*)
from information_schema.columns
where table_schema='public' and table_name='delivery_stops' and column_name='window_start'
union all
select 'index:delivery_stops_truck_position', count(*)
from pg_indexes where schemaname='public' and indexname='delivery_stops_truck_position'
union all
select 'trigger:route_events_immutable', count(*)
from pg_trigger where tgname='trg_delivery_route_events_immutable';

-- 2. Functions exist with expected signatures
select 'function:get_delivery_day_plan', count(*)
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname='get_delivery_day_plan'
union all
select 'function:save_delivery_day_route', count(*)
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname='save_delivery_day_route'
union all
select 'function:close_delivery_day', count(*)
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname='close_delivery_day'
union all
select 'function:reopen_delivery_day', count(*)
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname='reopen_delivery_day'
union all
select 'function:suggest_delivery_assignments', count(*)
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname='suggest_delivery_assignments';

-- 3. Privileges: every new RPC revoked from public/anon, granted authenticated
select p.proname,
       has_function_privilege('anon', p.oid, 'EXECUTE') as anon_can_execute,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') as auth_can_execute
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public'
  and p.proname in (
    'get_delivery_day_plan','save_delivery_day_route',
    'close_delivery_day','reopen_delivery_day',
    'suggest_delivery_assignments','delivery_company_today',
    'delivery_caller_employee_id','delivery_assert_day_writable'
  )
order by p.proname;
-- Expected: anon_can_execute = false for all; auth_can_execute = true for
-- the five RPCs, false for the three helpers.

-- 4. Window-order check constraint exists
select conname from pg_constraint
where conrelid='public.delivery_stops'::regclass
  and conname='delivery_stops_window_order';

-- 5. Route event action check accepts all six actions (smoke: insert shape)
select 'route_events_action_check' as check, pg_get_constraintdef(oid) as def
from pg_constraint
where conrelid='public.delivery_route_events'::regclass
  and contype='c' and pg_get_constraintdef(oid) like '%TRUCK_ASSIGNED%';
