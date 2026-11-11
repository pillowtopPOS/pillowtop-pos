-- m134 verification — READ ONLY. Run after 134 in the Supabase SQL editor.
-- Every check should return the expected value; nothing here writes.

-- 1. Columns on journey_interactions
select 'column:journey_interactions.purpose' as check, count(*) as ok
from information_schema.columns
where table_schema='public' and table_name='journey_interactions' and column_name='purpose'
union all
select 'column:journey_interactions.contact_outcome', count(*)
from information_schema.columns
where table_schema='public' and table_name='journey_interactions' and column_name='contact_outcome'
union all
select 'column:journey_interactions.callback_after', count(*)
from information_schema.columns
where table_schema='public' and table_name='journey_interactions' and column_name='callback_after'
union all
select 'column:journey_interactions.stop_id', count(*)
from information_schema.columns
where table_schema='public' and table_name='journey_interactions' and column_name='stop_id'
union all
select 'column:journey_interactions.window_snapshot', count(*)
from information_schema.columns
where table_schema='public' and table_name='journey_interactions' and column_name='window_snapshot'
union all
select 'column:journey_interactions.company_id', count(*)
from information_schema.columns
where table_schema='public' and table_name='journey_interactions' and column_name='company_id'
union all
select 'column:companies.delivery_contact_hold_days', count(*)
from information_schema.columns
where table_schema='public' and table_name='companies' and column_name='delivery_contact_hold_days';

-- 2. Constraints
select 'constraint:purpose_check', count(*)
from pg_constraint
where conname='journey_interactions_purpose_check'
union all
select 'constraint:contact_outcome_check', count(*)
from pg_constraint
where conname='journey_interactions_contact_outcome_check'
union all
select 'constraint:hold_days_range', count(*)
from pg_constraint
where conrelid='public.companies'::regclass
  and pg_get_constraintdef(oid) ilike '%delivery_contact_hold_days%';

-- 3. Indexes
select 'index:journey_interactions_company_customer_occurred', count(*)
from pg_indexes where schemaname='public' and indexname='journey_interactions_company_customer_occurred'
union all
select 'index:journey_interactions_company_occurred', count(*)
from pg_indexes where schemaname='public' and indexname='journey_interactions_company_occurred'
union all
select 'index:delivery_stops_journey_created', count(*)
from pg_indexes where schemaname='public' and indexname='delivery_stops_journey_created'
union all
select 'index:customers_norm_phone_idx', count(*)
from pg_indexes where schemaname='public' and indexname='customers_norm_phone_idx';

-- 4. Functions exist with expected signatures
select 'function:delivery_norm_phone', count(*)
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname='delivery_norm_phone'
union all
select 'function:delivery_contact_key_state', count(*)
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname='delivery_contact_key_state'
union all
select 'function:log_delivery_contact', count(*)
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname='log_delivery_contact'
union all
select 'function:get_delivery_contact_history', count(*)
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname='get_delivery_contact_history'
union all
select 'function:get_delivery_contact_hold_days', count(*)
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname='get_delivery_contact_hold_days'
union all
select 'function:set_delivery_contact_hold_days', count(*)
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname='set_delivery_contact_hold_days'
union all
select 'function:list_ready_journeys(boolean)', count(*)
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname='list_ready_journeys';

-- 5. Privileges. delivery_norm_phone sits inside the
--    customers_norm_phone_idx expression, so Postgres evaluates it on
--    every customers INSERT/UPDATE under the CALLING user's rights:
--    anon/public must NOT execute it, authenticated and service_role
--    MUST (otherwise order entry breaks with "permission denied for
--    function"). The RPCs are revoked from public/anon and granted to
--    authenticated. delivery_contact_key_state is internal-only: it is
--    revoked from everyone and only runs inside security-definer
--    functions, which check EXECUTE as the definer.
select p.proname,
       has_function_privilege('anon', p.oid, 'EXECUTE') as anon_can_execute,
       has_function_privilege('public', p.oid, 'EXECUTE') as public_can_execute,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') as auth_can_execute,
       has_function_privilege('service_role', p.oid, 'EXECUTE') as service_can_execute
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public'
  and p.proname in (
    'delivery_norm_phone','delivery_contact_key_state',
    'log_delivery_contact','get_delivery_contact_history',
    'get_delivery_contact_hold_days','set_delivery_contact_hold_days',
    'list_ready_journeys')
order by p.proname;

-- 6. RLS on journey_interactions, no policies on the new columns' data
--    path (access is RPC-only; there must still be no INSERT/UPDATE/DELETE
--    policies that would let a client write contact rows directly).
select 'rls:journey_interactions', count(*)
from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relname='journey_interactions' and c.relrowsecurity;

select polname, polcmd
from pg_policy pol
join pg_class c on c.oid=pol.polrelid
join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relname='journey_interactions';

-- 7. Defaults: existing/new rows untouched; purpose defaults GENERAL,
--    hold days default 2.
select 'default:purpose', column_default
from information_schema.columns
where table_schema='public' and table_name='journey_interactions' and column_name='purpose';

select 'default:hold_days', column_default
from information_schema.columns
where table_schema='public' and table_name='companies' and column_name='delivery_contact_hold_days';
