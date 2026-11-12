-- m136 verification — READ ONLY. Run after 136 in the Supabase SQL editor.
-- Every check should return the expected value; nothing here writes.

-- 1. Function still exists with the same signature.
select 'function:list_ready_journeys(boolean)', count(*)
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname='list_ready_journeys';

-- 2. Privileges re-asserted: revoked from public/anon, granted to
--    authenticated.
select p.proname,
       has_function_privilege('anon', p.oid, 'EXECUTE') as anon_can_execute,
       has_function_privilege('public', p.oid, 'EXECUTE') as public_can_execute,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') as auth_can_execute,
       has_function_privilege('service_role', p.oid, 'EXECUTE') as service_can_execute
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname='list_ready_journeys';
-- expected: anon f, public f, authenticated t, service_role f

-- 3. The function body emits the two new keys (and still the m134/m135
--    contact keys).
select 'body_has_customer_phone',
       pg_get_functiondef(p.oid) ilike '%''customer_phone''%' as ok
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname='list_ready_journeys'
union all
select 'body_has_customer_email',
       pg_get_functiondef(p.oid) ilike '%''customer_email''%' as ok
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname='list_ready_journeys'
union all
select 'body_has_held',
       pg_get_functiondef(p.oid) ilike '%''held''%' as ok
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname='list_ready_journeys'
union all
select 'body_has_last_contact',
       pg_get_functiondef(p.oid) ilike '%''last_contact''%' as ok
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname='list_ready_journeys';
-- all expected: ok = t

-- 4. Materialized CTEs still present (perf guard).
select 'body_has_materialized',
       pg_get_functiondef(p.oid) ilike '%materialized%' as ok
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname='list_ready_journeys';
