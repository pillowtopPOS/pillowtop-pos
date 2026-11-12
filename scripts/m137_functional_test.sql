-- m137 FUNCTIONAL TEST - MUTATES DATA.
-- For a THROWAWAY database only. Never run against Supabase or real data.
--
-- Same auth shim as m134/m135/m136:
--   create schema auth;
--   create table auth.users (id uuid primary key, email text);
--   create function auth.uid() returns uuid language sql stable as
--     $$ select nullif(current_setting('test.uid', true),'')::uuid $$;
--   create function auth.jwt() returns jsonb language sql stable as
--     $$ select coalesce(nullif(current_setting('test.jwt', true),''),'{}')::jsonb $$;
--   grant usage on schema auth to anon, authenticated, service_role;
--   grant select on auth.users to anon, authenticated, service_role;
--   grant execute on function auth.uid() to anon, authenticated, service_role;
--   grant execute on function auth.jwt() to anon, authenticated, service_role;
--
-- Switch users with:  set test.uid = '<auth user uuid>';
-- Every "ERROR:" line below is an EXPECTED rejection.

\set ON_ERROR_STOP off
\pset footer off
\timing off

-- ============================ SEED (superuser) ============================
insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111','owner@a.test'),
  ('44444444-4444-4444-4444-444444444444','admin@a.test'),
  ('55555555-5555-5555-5555-555555555555','mgr@a.test'),
  ('22222222-2222-2222-2222-222222222222','sales@a.test'),
  ('33333333-3333-3333-3333-333333333333','owner@b.test');

insert into public.companies (id, name, business_timezone) values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','Company A','America/Denver'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb','Company B','America/Denver');

insert into public.stores (id, company_id, name, store_code, timezone, is_active) values
  ('a1000000-0000-0000-0000-000000000001','aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','A Store','AAA','America/Denver',true),
  ('b1000000-0000-0000-0000-000000000001','bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb','B Store','BBB','America/Denver',true);

insert into public.employees (id, auth_user_id, home_store_id, role, first_name, last_name, is_active) values
  ('e1000000-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','a1000000-0000-0000-0000-000000000001','owner','Amy','Owner',true),
  ('e1000000-0000-0000-0000-000000000004','44444444-4444-4444-4444-444444444444','a1000000-0000-0000-0000-000000000001','admin','Ada','Admin',true),
  ('e1000000-0000-0000-0000-000000000005','55555555-5555-5555-5555-555555555555','a1000000-0000-0000-0000-000000000001','manager','Moe','Manager',true),
  ('e1000000-0000-0000-0000-000000000002','22222222-2222-2222-2222-222222222222','a1000000-0000-0000-0000-000000000001','sales','Sam','Sales',true),
  ('e2000000-0000-0000-0000-000000000001','33333333-3333-3333-3333-333333333333','b1000000-0000-0000-0000-000000000001','owner','Bob','Owner',true);

-- m126 left delivery.manage_calendar owner/admin only. This company has
-- granted it to its manager explicitly; the window RPC must honor that.
insert into public.role_permission_grants (company_id, role, permission_key)
values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','manager','delivery.manage_calendar')
on conflict do nothing;

insert into public.delivery_trucks (id, company_id, name, default_stop_cap, weekly_pattern, sort_order) values
  ('f1000000-0000-0000-0000-000000000001','aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','Truck 1',10,'{1,2,3,4,5,6,7}',1),
  ('f2000000-0000-0000-0000-000000000001','bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb','B Truck',5,'{1,2,3,4,5,6,7}',1);

insert into public.customers (id, first_name, last_name, phone, email, street_address, city, state, zip_code) values
  ('c1000000-0000-0000-0000-000000000001','Ann','Able','555-0101','a@x.test','1 Main St','Denver','CO','80201'),
  ('c1000000-0000-0000-0000-000000000002','Ben','Baker','555-0102','b@x.test','2 Oak Ave','Denver','CO','80202'),
  ('c1000000-0000-0000-0000-000000000003','Cid','Cole','555-0103','c@x.test','3 Pine Rd','Aurora','CO','80010'),
  ('c1000000-0000-0000-0000-000000000004','Dee','Drew','555-0104','d@x.test','4 Elm St','Denver','CO','80204'),
  ('c1000000-0000-0000-0000-000000000005','Eli','Eve','555-0105','e@x.test','5 Ash Ave','Aurora','CO','80011'),
  ('c1000000-0000-0000-0000-000000000006','Fay','Fox','555-0106','f@x.test','6 Birch Rd','Denver','CO','80205'),
  ('c2000000-0000-0000-0000-000000000001','Ivy','Ives','555-0201','i@x.test','9 Elm St','Boulder','CO','80301');

-- J1-J3 book on day1, J4 on day2, J5/J6 get non-BOOKED stops on day1,
-- JB1 books on day1 in company B.
insert into public.sleep_journeys (id, customer_id, store_id, current_state, fulfillment_type, price, journey_number)
values
  ('d1000000-0000-0000-0000-0000000000a1','c1000000-0000-0000-0000-000000000001','a1000000-0000-0000-0000-000000000001','Ready to Schedule','delivery',1000,'SJ-AAA00001'),
  ('d1000000-0000-0000-0000-0000000000a2','c1000000-0000-0000-0000-000000000002','a1000000-0000-0000-0000-000000000001','Ready to Schedule','delivery',1000,'SJ-AAA00002'),
  ('d1000000-0000-0000-0000-0000000000a3','c1000000-0000-0000-0000-000000000003','a1000000-0000-0000-0000-000000000001','Ready to Schedule','delivery',1000,'SJ-AAA00003'),
  ('d1000000-0000-0000-0000-0000000000a4','c1000000-0000-0000-0000-000000000004','a1000000-0000-0000-0000-000000000001','Ready to Schedule','delivery',1000,'SJ-AAA00004'),
  ('d1000000-0000-0000-0000-0000000000a5','c1000000-0000-0000-0000-000000000005','a1000000-0000-0000-0000-000000000001','Ready to Schedule','delivery',1000,'SJ-AAA00005'),
  ('d1000000-0000-0000-0000-0000000000a6','c1000000-0000-0000-0000-000000000006','a1000000-0000-0000-0000-000000000001','Ready to Schedule','delivery',1000,'SJ-AAA00006');

insert into public.sleep_journeys (id, customer_id, store_id, current_state, fulfillment_type, price, journey_number)
values ('d2000000-0000-0000-0000-0000000000b1','c2000000-0000-0000-0000-000000000001',
        'b1000000-0000-0000-0000-000000000001','Ready to Schedule','delivery',500,'SJ-BBB00001');

insert into public.journey_line_items (journey_id, item_name, quantity, unit_price)
select id, 'Mattress', 1, 1000 from public.sleep_journeys;

-- derive_journey_state recomputes current_state on write; force the
-- bookable state the same way m136 does.
alter table public.sleep_journeys disable trigger user;
update public.sleep_journeys set current_state = 'Ready to Schedule';
alter table public.sleep_journeys enable trigger user;

select ((now() at time zone 'America/Denver')::date + 5)::text as testdate,
       ((now() at time zone 'America/Denver')::date + 10)::text as testdate2 \gset
\echo 'TEST DATE:' :testdate ' SECOND DATE:' :testdate2

-- Non-BOOKED stops on day1 for the rejection tests (direct insert,
-- superuser only; the RPC path is covered by the BOOKED rows below).
insert into public.delivery_stops
  (id, company_id, store_id, journey_id, delivery_date, status,
   cancelled_at, cancel_reason)
values
  ('e5000000-0000-0000-0000-0000000000c1','aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
   'a1000000-0000-0000-0000-000000000001','d1000000-0000-0000-0000-0000000000a5',
   (now() at time zone 'America/Denver')::date + 5,'CANCELLED',now(),'seed'),
  ('e5000000-0000-0000-0000-0000000000c2','aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
   'a1000000-0000-0000-0000-000000000001','d1000000-0000-0000-0000-0000000000a6',
   (now() at time zone 'America/Denver')::date + 5,'SUPERSEDED',null,'seed');

-- ======================= REAL ROLES FROM HERE =======================
set role authenticated;
set test.uid = '11111111-1111-1111-1111-111111111111';
set test.jwt = '{}';

select public.book_delivery_stop('d1000000-0000-0000-0000-0000000000a1', :'testdate'::date) as stop1 \gset
select public.book_delivery_stop('d1000000-0000-0000-0000-0000000000a2', :'testdate'::date) as stop2 \gset
select public.book_delivery_stop('d1000000-0000-0000-0000-0000000000a3', :'testdate'::date) as stop3 \gset
select public.book_delivery_stop('d1000000-0000-0000-0000-0000000000a4', :'testdate2'::date) as stop4_day2 \gset

set test.uid = '33333333-3333-3333-3333-333333333333';
select public.book_delivery_stop('d2000000-0000-0000-0000-0000000000b1', :'testdate'::date) as stop_b \gset
set test.uid = '11111111-1111-1111-1111-111111111111';

\echo '=== T1: set_delivery_day_settings role gate ==='
select public.set_delivery_day_settings('10:00','19:00',3,'window');
reset role;
select delivery_day_start, delivery_day_end, delivery_window_hours, delivery_day_mode
from public.companies where id='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
set role authenticated;
set test.uid = '44444444-4444-4444-4444-444444444444';
\echo '-- admin sets (expect success)'
select public.set_delivery_day_settings('09:00','17:00',4,'window');
set test.uid = '55555555-5555-5555-5555-555555555555';
\echo '-- manager sets (expect ERROR)'
select public.set_delivery_day_settings('09:00','17:00',3,'window');
set test.uid = '22222222-2222-2222-2222-222222222222';
\echo '-- sales sets (expect ERROR)'
select public.set_delivery_day_settings('09:00','17:00',3,'window');
set test.uid = '11111111-1111-1111-1111-111111111111';

\echo '=== T2: validation failures (each expect ERROR, values unchanged) ==='
select public.set_delivery_day_settings('17:00','09:00',3,'window');      -- end before start
select public.set_delivery_day_settings('09:00','17:00',0,'window');       -- window too small
select public.set_delivery_day_settings('09:00','17:00',9,'window');       -- window too big
select public.set_delivery_day_settings('10:00','12:00',3,'window');       -- window longer than day
select public.set_delivery_day_settings('09:00','17:00',3,'bogus');        -- bad mode
select public.set_delivery_day_settings(null,'17:00',3,'window');          -- null start
select public.set_delivery_day_settings('09:00','17:00',3,null);           -- null mode
reset role;
select delivery_day_start, delivery_day_end, delivery_window_hours, delivery_day_mode
from public.companies where id='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
set role authenticated;

\echo '=== T3: permission seed, backfill shape, has_permission ==='
reset role;
select role, permission_key from public.role_permission_grants
where company_id='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  and permission_key='delivery.log_confirmation_calls' order by role;
-- New company created AFTER the migration: trigger must seed the key.
insert into public.companies (id, name, business_timezone)
values ('cccccccc-cccc-cccc-cccc-cccccccccccc','Company C','America/Denver');
select role, count(*) from public.role_permission_grants
where company_id='cccccccc-cccc-cccc-cccc-cccccccccccc'
  and permission_key='delivery.log_confirmation_calls' group by role order by role;
set role authenticated;
set test.uid = '22222222-2222-2222-2222-222222222222';
select public.has_permission('delivery.log_confirmation_calls') as sales_can_log_confirm;
select public.has_permission('delivery.manage_calendar') as sales_can_manage_cal;
set test.uid = '11111111-1111-1111-1111-111111111111';

\echo '=== T4: set_delivery_stop_windows permission gate ==='
set test.uid = '22222222-2222-2222-2222-222222222222';
\echo '-- sales without manage_calendar (expect ERROR)'
select public.set_delivery_stop_windows(:'testdate'::date,
  jsonb_build_array(jsonb_build_object('stop_id', :'stop1', 'window_start','10:00','window_end','13:00')));
set test.uid = '55555555-5555-5555-5555-555555555555';
\echo '-- manager WITH granted manage_calendar (expect 1)'
select public.set_delivery_stop_windows(:'testdate'::date,
  jsonb_build_array(jsonb_build_object('stop_id', :'stop1', 'window_start','10:00','window_end','13:00')));
set test.uid = '11111111-1111-1111-1111-111111111111';

\echo '=== T5: owner sets windows on two stops (expect 2) ==='
select public.set_delivery_stop_windows(:'testdate'::date,
  jsonb_build_array(
    jsonb_build_object('stop_id', :'stop1', 'window_start','09:30','window_end','12:30'),
    jsonb_build_object('stop_id', :'stop2', 'window_start','13:00','window_end','16:00')
  )) as changed;
reset role;
select id, window_start, window_end from public.delivery_stops
where id in (:'stop1', :'stop2') order by id;
select count(*) as window_set_events,
       (select jsonb_array_length(details->'changes')
        from public.delivery_route_events
        where action='WINDOW_SET' order by created_at desc limit 1) as changes_in_last
from public.delivery_route_events where action='WINDOW_SET';
select action, details->'changes'->0->>'from_start' as from_s,
       details->'changes'->0->>'to_start' as to_s
from public.delivery_route_events where action='WINDOW_SET'
order by created_at desc limit 1;
set role authenticated;

\echo '=== T6: rejection cases, all-or-nothing rollback ==='
\echo '-- company B stop inside A call (expect ERROR, A stop1 unchanged)'
select public.set_delivery_stop_windows(:'testdate'::date,
  jsonb_build_array(
    jsonb_build_object('stop_id', :'stop3', 'window_start','09:00','window_end','12:00'),
    jsonb_build_object('stop_id', :'stop_b', 'window_start','09:00','window_end','12:00')
  ));
reset role;
select window_start, window_end from public.delivery_stops where id=:'stop3';
set role authenticated;

\echo '-- CANCELLED stop (expect ERROR)'
select public.set_delivery_stop_windows(:'testdate'::date,
  jsonb_build_array(jsonb_build_object('stop_id','e5000000-0000-0000-0000-0000000000c1','window_start','09:00','window_end','12:00')));
\echo '-- SUPERSEDED stop (expect ERROR)'
select public.set_delivery_stop_windows(:'testdate'::date,
  jsonb_build_array(jsonb_build_object('stop_id','e5000000-0000-0000-0000-0000000000c2','window_start','09:00','window_end','12:00')));
\echo '-- stop on another date (expect ERROR)'
select public.set_delivery_stop_windows(:'testdate'::date,
  jsonb_build_array(jsonb_build_object('stop_id', :'stop4_day2', 'window_start','09:00','window_end','12:00')));
\echo '-- nonexistent stop (expect ERROR)'
select public.set_delivery_stop_windows(:'testdate'::date,
  jsonb_build_array(jsonb_build_object('stop_id','99999999-9999-9999-9999-999999999999','window_start','09:00','window_end','12:00')));
reset role;
select count(*) as window_set_events_after_rejects from public.delivery_route_events where action='WINDOW_SET';
set role authenticated;

\echo '=== T7: malformed payloads (each expect ERROR) ==='
select public.set_delivery_stop_windows(:'testdate'::date, '[]'::jsonb);
select public.set_delivery_stop_windows(:'testdate'::date, '{"stop_id":"x"}'::jsonb);
select public.set_delivery_stop_windows(:'testdate'::date,
  jsonb_build_array(jsonb_build_object('stop_id', :'stop3', 'window_start','09:00')));
select public.set_delivery_stop_windows(:'testdate'::date,
  jsonb_build_array(jsonb_build_object('stop_id', :'stop3', 'window_start','13:00','window_end','09:00')));
select public.set_delivery_stop_windows(:'testdate'::date,
  jsonb_build_array(jsonb_build_object('stop_id', :'stop3', 'window_start','09:00','window_end','09:00')));

\echo '=== T8: clear windows with nulls (expect 2 changed) ==='
select public.set_delivery_stop_windows(:'testdate'::date,
  jsonb_build_array(
    jsonb_build_object('stop_id', :'stop1', 'window_start',null,'window_end',null),
    jsonb_build_object('stop_id', :'stop2', 'window_start',null,'window_end',null)
  )) as cleared;
reset role;
select id, window_start, window_end from public.delivery_stops
where id in (:'stop1', :'stop2') order by id;
set role authenticated;

\echo '=== T9: outside-day-hours window is allowed ==='
select public.set_delivery_day_settings('09:00','17:00',3,'window');
select public.set_delivery_stop_windows(:'testdate'::date,
  jsonb_build_array(jsonb_build_object('stop_id', :'stop3', 'window_start','20:00','window_end','23:00')))
as outside_hours_ok;

\echo '=== T10: day_only mode does not block window writes ==='
select public.set_delivery_day_settings('10:00','19:00',3,'day_only');
select public.set_delivery_stop_windows(:'testdate'::date,
  jsonb_build_array(jsonb_build_object('stop_id', :'stop3', 'window_start','11:00','window_end','14:00')))
as day_only_ok;
select public.set_delivery_day_settings('09:00','17:00',3,'window');

\echo '=== T11: closed day still accepts windows, version untouched ==='
reset role;
select version from public.delivery_day_plans
where company_id='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  and date=:'testdate'::date;
set role authenticated;
select public.close_delivery_day(:'testdate'::date, 0);
reset role;
select version as version_after_close from public.delivery_day_plans
where company_id='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  and date=:'testdate'::date;
set role authenticated;
select public.set_delivery_stop_windows(:'testdate'::date,
  jsonb_build_array(jsonb_build_object('stop_id', :'stop1', 'window_start','08:30','window_end','11:30')))
as closed_day_ok;
reset role;
select version as version_after_windows, status from public.delivery_day_plans
where company_id='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  and date=:'testdate'::date;
set role authenticated;

\echo '=== T12: past day stays read-only ==='
select public.set_delivery_stop_windows(((now() at time zone 'America/Denver')::date - 1),
  jsonb_build_array(jsonb_build_object('stop_id', :'stop1', 'window_start','08:00','window_end','10:00')));

\echo '=== T13: anon denied ==='
set role anon;
select public.set_delivery_day_settings('09:00','17:00',3,'window');
select public.set_delivery_stop_windows(:'testdate'::date, '[]'::jsonb);
reset role;

\echo '=== T14: execute privileges ==='
select p.proname,
       has_function_privilege('anon', p.oid, 'EXECUTE') as anon_exec,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') as auth_exec
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname in
  ('set_delivery_day_settings','set_delivery_stop_windows')
order by p.proname;
