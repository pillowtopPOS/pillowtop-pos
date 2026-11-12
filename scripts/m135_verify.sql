-- m135 verification — READ ONLY. Run after 135 in the Supabase SQL editor.
-- Every check should return the expected value; nothing here writes.

-- 1. Both functions still exist (create or replace keeps signatures).
select 'function:delivery_contact_key_state', count(*)
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname='delivery_contact_key_state'
union all
select 'function:log_delivery_contact', count(*)
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname='log_delivery_contact';

-- 2. Privileges re-asserted: key_state internal-only (revoked from
--    everyone, runs only inside security-definer callers);
--    log_delivery_contact revoked from public/anon, granted to
--    authenticated.
select p.proname,
       has_function_privilege('anon', p.oid, 'EXECUTE') as anon_can_execute,
       has_function_privilege('public', p.oid, 'EXECUTE') as public_can_execute,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') as auth_can_execute,
       has_function_privilege('service_role', p.oid, 'EXECUTE') as service_can_execute
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public'
  and p.proname in ('delivery_contact_key_state','log_delivery_contact')
order by p.proname;
-- expected: delivery_contact_key_state f f f f ; log_delivery_contact f f t f

-- 3. callback_after column comment reflects m135 (spoke allowed,
--    wrong_number rejected).
select left(col_description('public.journey_interactions'::regclass,
       (select attnum from pg_attribute
        where attrelid='public.journey_interactions'::regclass
          and attname='callback_after')), 200) as callback_after_comment;
-- expected: mentions "spoke" in the allowed list and "wrong_number" as rejected

-- 4. Function bodies contain the m135 changes (spoke in the hold set,
--    wrong_number-only callback rejection).
select 'key_state_has_spoke_hold',
       pg_get_functiondef(p.oid) ilike '%''spoke''%' as has_spoke
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname='delivery_contact_key_state';

select 'log_rejects_wrong_number_only',
       pg_get_functiondef(p.oid) ilike '%does not apply to a wrong number%' as has_new_msg
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname='log_delivery_contact';
