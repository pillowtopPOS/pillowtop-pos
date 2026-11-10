-- m128 verify: delivery_week_start column + week-start RPCs.
-- Run in the Supabase SQL editor after installing
-- supabase/migrations/128_delivery_week_start.sql.

\set QUIET on
\pset footer off

-- 1. Column exists with the right default/check ---------------------------
do $$
declare v_def text;
begin
  select column_default into v_def
  from information_schema.columns
  where table_schema = 'public' and table_name = 'companies'
    and column_name = 'delivery_week_start';
  if v_def is null then
    raise notice 'FAIL: companies.delivery_week_start missing';
  elsif v_def like '%1%' then
    raise notice 'OK: delivery_week_start exists (default %)', v_def;
  else
    raise notice 'FAIL: unexpected default %', v_def;
  end if;
end $$;

-- 2. Both RPCs exist and are executable -----------------------------
do $$
declare v_ok boolean;
begin
  select bool_and(has_function_privilege('authenticated', p.oid, 'execute'))
  into v_ok
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in ('get_delivery_week_start', 'set_delivery_week_start');
  if v_ok then
    raise notice 'OK: week-start RPCs exist and are executable';
  else
    raise notice 'FAIL: a week-start RPC is missing or not executable';
  end if;
end $$;

-- 3. Behavioral (as a logged-in employee via the app or harness):
--    select public.get_delivery_week_start();   -- expect 1
--    select public.set_delivery_week_start(7);  -- owner/admin only
--    select public.get_delivery_week_start();   -- expect 7
--    select public.set_delivery_week_start(3);  -- expect error
--    select public.set_delivery_week_start(1);  -- restore
