-- m129 verify — safe to run twice. Read-only checks.

-- 1. Enum value exists.
select 'enum delivery_unscheduled' as check,
       exists (
         select 1 from pg_enum e
         join pg_type t on t.oid = e.enumtypid
         where t.typname = 'journey_event_type'
           and e.enumlabel = 'delivery_unscheduled'
       ) as ok;

-- 2. Column + default.
select 'companies.delivery_cutoff_time' as check,
       column_name is not null as ok
from information_schema.columns
where table_schema = 'public'
  and table_name = 'companies'
  and column_name = 'delivery_cutoff_time';

select 'cutoff default is 15:00' as check,
       (select column_default from information_schema.columns
        where table_schema='public' and table_name='companies'
          and column_name='delivery_cutoff_time') as default_value;

-- 3. Tables + RLS.
select 'delivery_stops RLS' as check, relrowsecurity as ok
from pg_class where relname = 'delivery_stops' and relnamespace = 'public'::regnamespace;
select 'delivery_stop_events RLS' as check, relrowsecurity as ok
from pg_class where relname = 'delivery_stop_events' and relnamespace = 'public'::regnamespace;

-- 4. Unique active-stop index.
select 'one BOOKED stop per journey' as check, indexname
from pg_indexes
where schemaname = 'public' and tablename = 'delivery_stops'
  and indexname = 'delivery_stops_one_booked_per_journey';

-- 5. Permission key valid + seeded owner/admin.
select 'book_inside_cutoff valid key' as check,
       public.is_valid_permission_key('delivery.book_inside_cutoff') as ok;
select role, permission_key
from public.role_permission_grants
where permission_key = 'delivery.book_inside_cutoff'
order by company_id, role;

-- 6. RPCs exist.
select proname
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and proname in (
    'book_delivery_stop',
    'reschedule_delivery_stop',
    'cancel_delivery_stop',
    'get_earliest_bookable_date',
    'delivery_day_capacity',
    'guard_delivery_event_insert'
  )
order by proname;

-- 7. Guard trigger present.
select 'guard trigger' as check, tgname
from pg_trigger
where tgrelid = 'public.journey_events'::regclass
  and tgname = 'trg_guard_delivery_event_insert';

-- 8. Immutable trigger present.
select 'immutable trigger' as check, tgname
from pg_trigger
where tgrelid = 'public.delivery_stop_events'::regclass
  and tgname = 'trg_delivery_stop_events_immutable';

-- 9. event_to_state maps the new event (returns text).
select 'event_to_state(delivery_unscheduled)' as check,
       public.event_to_state('delivery_unscheduled'::public.journey_event_type)::text as state;
