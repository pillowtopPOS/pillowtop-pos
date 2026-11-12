-- m137 VERIFY - read-only catalog checks. Run after applying
-- supabase/migrations/137_delivery_day_settings_and_stop_windows.sql.

\pset footer off

select p.proname,
       pg_get_function_arguments(p.oid) as args,
       has_function_privilege('anon', p.oid, 'EXECUTE') as anon_exec,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') as auth_exec,
       has_function_privilege('public', p.oid, 'EXECUTE') as public_exec
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('set_delivery_day_settings', 'set_delivery_stop_windows',
                    'is_valid_permission_key', 'trg_seed_delivery_permissions')
order by p.proname;

select public.is_valid_permission_key('delivery.log_confirmation_calls')
  as new_key_valid;

select count(*) as companies_with_new_key_grants
from public.role_permission_grants
where permission_key = 'delivery.log_confirmation_calls';

select column_name, data_type, is_nullable
from information_schema.columns
where table_schema = 'public' and table_name = 'delivery_route_events'
  and column_name = 'details';

select p.proname, p.prosecdef as is_secdef
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('set_delivery_day_settings', 'set_delivery_stop_windows')
order by p.proname;
