-- m128 verify: company-wide week_start_day + week-start RPCs.
-- Run in the Supabase SQL editor after installing
-- supabase/migrations/128_company_week_start.sql.

\set QUIET on
\pset footer off

-- 1. Column exists ---------------------------------------------------------
do $$
declare v_def text;
begin
  select column_default into v_def
  from information_schema.columns
  where table_schema = 'public' and table_name = 'companies'
    and column_name = 'week_start_day';
  if v_def is null then
    raise notice 'FAIL: companies.week_start_day missing';
  else
    raise notice 'OK: week_start_day exists (default %)', v_def;
  end if;
end $$;

-- 2. RPCs exist and are executable -----------------------------------------
do $$
declare v_ok boolean;
begin
  select bool_and(has_function_privilege('authenticated', p.oid, 'execute'))
  into v_ok
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in (
      'get_company_week_start', 'set_company_week_start',
      'company_week_start_date'
    );
  if v_ok then
    raise notice 'OK: week-start RPCs exist and are executable';
  else
    raise notice 'FAIL: a week-start RPC is missing or not executable';
  end if;
end $$;

-- 3. company_week_start_date math — replace <company id> with a real one.
--    p_scope is accepted and ignored (future per-feature overrides).
--    Expect (Monday start, the default):
--      '2026-11-08' (Sun) -> 2026-11-02
--      '2026-11-09' (Mon) -> 2026-11-09
--    After set_company_week_start(7) (Sunday start):
--      '2026-11-08' -> 2026-11-08
--      '2026-11-09' -> 2026-11-08
--    Test:
--    select public.company_week_start_date('<company-id>'::uuid, '2026-11-08'::date, 'delivery');
--    select public.company_week_start_date('<company-id>'::uuid, '2026-11-09'::date, 'delivery');

-- 4. Behavioral (as a logged-in owner/admin via the app or harness):
--    select public.get_company_week_start();        -- expect 1
--    select public.set_company_week_start(7);       -- owner/admin only
--    select public.get_company_week_start();        -- expect 7
--    select public.set_company_week_start(3);       -- expect error
--    select public.set_company_week_start(1);       -- restore
