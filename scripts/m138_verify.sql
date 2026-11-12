-- m138 VERIFY - read-only catalog checks. Run after applying
-- supabase/migrations/138_delivery_confirmation_calls.sql.

\pset footer off

select p.proname,
       pg_get_function_arguments(p.oid) as args,
       p.prosecdef as is_secdef,
       has_function_privilege('anon', p.oid, 'EXECUTE') as anon_exec,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') as auth_exec
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('log_delivery_confirmation',
                    'get_delivery_confirmation_list',
                    'set_delivery_stop_windows',
                    'set_delivery_day_settings',
                    'log_delivery_contact',
                    'delivery_contact_key_state',
                    'is_valid_permission_key',
                    'trg_seed_delivery_permissions')
order by p.proname;

select public.is_valid_permission_key('delivery.set_windows')
  as set_windows_key_valid,
       public.is_valid_permission_key('delivery.log_confirmation_calls')
  as log_conf_key_valid;

select conname, convalidated,
       pg_get_constraintdef(oid) as def
from pg_constraint
where conname = 'journey_interactions_contact_outcome_check';

select count(*) as confirmation_rows_now
from public.journey_interactions where purpose = 'CONFIRMATION';

select count(*) as set_windows_grants
from public.role_permission_grants
where permission_key = 'delivery.set_windows';
