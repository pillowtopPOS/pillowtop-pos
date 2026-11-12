-- m138 FUNCTIONAL TEST - MUTATES DATA.
-- For a THROWAWAY database only. Never run against Supabase or real data.
--
-- Same auth shim as m134/m135/m136/m137:
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

-- ======================= PRE-SEED CHECKS (superuser) =======================
\echo '=== P0: CONFIRMATION rows existing before any test data (expect 0) ==='
select count(*) as existing_confirmation_rows
from public.journey_interactions where purpose = 'CONFIRMATION';

select conname, convalidated
from pg_constraint
where conname = 'journey_interactions_contact_outcome_check';

-- ============================ SEED (superuser) ============================
insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111','owner@a.test'),
  ('44444444-4444-4444-4444-444444444444','admin@a.test'),
  ('55555555-5555-5555-5555-555555555555','mgr@a.test'),
  ('66666666-6666-6666-6666-666666666666','mgr2@a.test'),
  ('22222222-2222-2222-2222-222222222222','alice@a.test'),
  ('77777777-7777-7777-7777-777777777777','sal@a.test'),
  ('88888888-8888-8888-8888-888888888888','ned@a.test'),
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
  ('e1000000-0000-0000-0000-000000000006','66666666-6666-6666-6666-666666666666','a1000000-0000-0000-0000-000000000001','manager','Mia','Manager2',true),
  ('e1000000-0000-0000-0000-000000000002','22222222-2222-2222-2222-222222222222','a1000000-0000-0000-0000-000000000001','sales','Alice','Sales',true),
  ('e1000000-0000-0000-0000-000000000007','77777777-7777-7777-7777-777777777777','a1000000-0000-0000-0000-000000000001','sales','Sal','Sales',true),
  ('e1000000-0000-0000-0000-000000000008','88888888-8888-8888-8888-888888888888','a1000000-0000-0000-0000-000000000001','sales','Ned','Denied',true),
  ('e2000000-0000-0000-0000-000000000001','33333333-3333-3333-3333-333333333333','b1000000-0000-0000-0000-000000000001','owner','Bob','Owner',true);

-- Grants shaping the permission matrix:
--  * Moe (manager): employee override grants manage_calendar only ->
--    "only manage_calendar" window case. (A role grant would give it
--    to EVERY manager, so Mia could never be the "neither" case.)
--  * Mia (manager): nothing -> "manager with neither" denied case.
--  * Sal (sales): employee override grants delivery.set_windows only.
--  * Ned (sales): override DENIES log_confirmation_calls.
insert into public.employee_permission_overrides
  (company_id, employee_id, permission_key, granted)
values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','e1000000-0000-0000-0000-000000000005','delivery.manage_calendar',true),
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','e1000000-0000-0000-0000-000000000007','delivery.set_windows',true),
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','e1000000-0000-0000-0000-000000000008','delivery.log_confirmation_calls',false);

-- Truck uuids ascend f...001 < f...002 but sort_order is REVERSED on
-- purpose: the call list must follow sort_order, not uuid order.
insert into public.delivery_trucks (id, company_id, name, default_stop_cap, weekly_pattern, sort_order) values
  ('f1000000-0000-0000-0000-000000000001','aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','Truck 1',10,'{1,2,3,4,5,6,7}',2),
  ('f1000000-0000-0000-0000-000000000002','aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','Truck 2',10,'{1,2,3,4,5,6,7}',1),
  ('f2000000-0000-0000-0000-000000000001','bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb','B Truck',5,'{1,2,3,4,5,6,7}',1);

-- Ben shares Ann's phone on purpose: same customer key for hold tests.
insert into public.customers (id, first_name, last_name, phone, email, street_address, city, state, zip_code) values
  ('c1000000-0000-0000-0000-000000000001','Ann','Able','555-0101','a@x.test','1 Main St','Denver','CO','80201'),
  ('c1000000-0000-0000-0000-000000000002','Ben','Baker','555-0101','b@x.test','2 Oak Ave','Denver','CO','80202'),
  ('c1000000-0000-0000-0000-000000000003','Cid','Cole','555-0103','c@x.test','3 Pine Rd','Aurora','CO','80010'),
  ('c1000000-0000-0000-0000-000000000004','Dee','Drew','555-0104','d@x.test','4 Elm St','Denver','CO','80204'),
  ('c1000000-0000-0000-0000-000000000005','Eli','Eve','555-0105','e@x.test','5 Ash Ave','Aurora','CO','80011'),
  ('c1000000-0000-0000-0000-000000000006','Fay','Fox','555-0106','f@x.test','6 Birch Rd','Denver','CO','80205'),
  ('c1000000-0000-0000-0000-000000000007','Gus','Gray','555-0107','g@x.test','7 Cedar Ln','Aurora','CO','80012'),
  -- Company B customer: SAME name and phone as Ann to prove isolation.
  ('c2000000-0000-0000-0000-000000000001','Ann','Able','555-0101','bee@x.test','9 Elm St','Boulder','CO','80301');

-- Journeys. JA1 assigned Alice, JA2 unassigned (booked_by owner),
-- JA3 assigned Sal, JA4/JA5 later dates, JC1/JC2 non-booked stops,
-- JPAST/JTODAY edge dates, JB1 company B.
insert into public.sleep_journeys (id, customer_id, store_id, assigned_employee_id, current_state, fulfillment_type, price, journey_number)
values
  ('d1000000-0000-0000-0000-0000000000a1','c1000000-0000-0000-0000-000000000001','a1000000-0000-0000-0000-000000000001','e1000000-0000-0000-0000-000000000002','Ready to Schedule','delivery',1000,'SJ-AAA00001'),
  ('d1000000-0000-0000-0000-0000000000a2','c1000000-0000-0000-0000-000000000002','a1000000-0000-0000-0000-000000000001',null,'Ready to Schedule','delivery',1000,'SJ-AAA00002'),
  ('d1000000-0000-0000-0000-0000000000a3','c1000000-0000-0000-0000-000000000003','a1000000-0000-0000-0000-000000000001','e1000000-0000-0000-0000-000000000007','Ready to Schedule','delivery',1000,'SJ-AAA00003'),
  ('d1000000-0000-0000-0000-0000000000a4','c1000000-0000-0000-0000-000000000004','a1000000-0000-0000-0000-000000000001','e1000000-0000-0000-0000-000000000002','Ready to Schedule','delivery',1000,'SJ-AAA00004'),
  ('d1000000-0000-0000-0000-0000000000a5','c1000000-0000-0000-0000-000000000005','a1000000-0000-0000-0000-000000000001',null,'Ready to Schedule','delivery',1000,'SJ-AAA00005'),
  ('d1000000-0000-0000-0000-0000000000a6','c1000000-0000-0000-0000-000000000006','a1000000-0000-0000-0000-000000000001',null,'Ready to Schedule','delivery',1000,'SJ-AAA00006'),
  ('d1000000-0000-0000-0000-0000000000a7','c1000000-0000-0000-0000-000000000007','a1000000-0000-0000-0000-000000000001',null,'Ready to Schedule','delivery',1000,'SJ-AAA00007'),
  ('d2000000-0000-0000-0000-0000000000b1','c2000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000001',null,'Ready to Schedule','delivery',500,'SJ-BBB00001');

insert into public.journey_line_items (journey_id, item_name, quantity, unit_price)
select id, 'Mattress', 1, 1000 from public.sleep_journeys;

alter table public.sleep_journeys disable trigger user;
update public.sleep_journeys set current_state = 'Ready to Schedule';
alter table public.sleep_journeys enable trigger user;

select ((now() at time zone 'America/Denver')::date + 3)::text as d1,
       ((now() at time zone 'America/Denver')::date + 6)::text as d2,
       ((now() at time zone 'America/Denver')::date + 9)::text as d3 \gset
\echo 'DATES d1=' :d1 ' d2=' :d2 ' d3=' :d3

-- Non-BOOKED and edge stops (direct insert, superuser).
insert into public.delivery_stops
  (id, company_id, store_id, journey_id, delivery_date, status,
   cancelled_at, cancel_reason)
values
  ('e5000000-0000-0000-0000-0000000000c1','aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
   'a1000000-0000-0000-0000-000000000001','d1000000-0000-0000-0000-0000000000a6',
   (now() at time zone 'America/Denver')::date + 3,'CANCELLED',now(),'seed'),
  ('e5000000-0000-0000-0000-0000000000c2','aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
   'a1000000-0000-0000-0000-000000000001','d1000000-0000-0000-0000-0000000000a7',
   (now() at time zone 'America/Denver')::date + 3,'SUPERSEDED',null,'seed'),
  ('e5000000-0000-0000-0000-0000000000c3','aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
   'a1000000-0000-0000-0000-000000000001','d1000000-0000-0000-0000-0000000000a5',
   (now() at time zone 'America/Denver')::date - 1,'BOOKED',null,null),
  ('e5000000-0000-0000-0000-0000000000c4','aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
   'a1000000-0000-0000-0000-000000000001','d1000000-0000-0000-0000-0000000000a7',
   (now() at time zone 'America/Denver')::date,'BOOKED',null,null);

-- ======================= REAL ROLES FROM HERE =======================
set role authenticated;
set test.jwt = '{}';

set test.uid = '11111111-1111-1111-1111-111111111111';
select public.book_delivery_stop('d1000000-0000-0000-0000-0000000000a1', :'d1'::date) as s1 \gset
select public.book_delivery_stop('d1000000-0000-0000-0000-0000000000a2', :'d1'::date) as s2 \gset
select public.book_delivery_stop('d1000000-0000-0000-0000-0000000000a3', :'d1'::date) as s3 \gset
select public.book_delivery_stop('d1000000-0000-0000-0000-0000000000a4', :'d2'::date) as s4 \gset
select public.book_delivery_stop('d1000000-0000-0000-0000-0000000000a5', :'d3'::date) as s5 \gset

set test.uid = '33333333-3333-3333-3333-333333333333';
select public.book_delivery_stop('d2000000-0000-0000-0000-0000000000b1', :'d1'::date) as sb \gset
set test.uid = '11111111-1111-1111-1111-111111111111';

-- Give the first two stops windows up front (snapshot tests need them).
select public.set_delivery_stop_windows(:'d1'::date,
  jsonb_build_array(
    jsonb_build_object('stop_id', :'s1', 'window_start','10:00','window_end','13:00'),
    jsonb_build_object('stop_id', :'s2', 'window_start','13:00','window_end','16:00'),
    jsonb_build_object('stop_id', :'s3', 'window_start','09:00','window_end','12:00')
  )) as windows_seed;

\echo '=== T1: set_delivery_stop_windows permission + 137 matrix ==='
set test.uid = '77777777-7777-7777-7777-777777777777';
\echo '-- Sal: ONLY delivery.set_windows override (expect 0: same windows)'
select public.set_delivery_stop_windows(:'d1'::date,
  jsonb_build_array(jsonb_build_object('stop_id', :'s1', 'window_start','10:00','window_end','13:00')));
\echo '-- Sal: set_windows only, real change (expect 1)'
select public.set_delivery_stop_windows(:'d1'::date,
  jsonb_build_array(jsonb_build_object('stop_id', :'s1', 'window_start','10:30','window_end','13:30')));
select public.set_delivery_stop_windows(:'d1'::date,
  jsonb_build_array(jsonb_build_object('stop_id', :'s1', 'window_start','10:00','window_end','13:00')));
set test.uid = '55555555-5555-5555-5555-555555555555';
\echo '-- Moe: ONLY manage_calendar role grant (expect 1)'
select public.set_delivery_stop_windows(:'d1'::date,
  jsonb_build_array(jsonb_build_object('stop_id', :'s2', 'window_start','13:30','window_end','16:30')));
select public.set_delivery_stop_windows(:'d1'::date,
  jsonb_build_array(jsonb_build_object('stop_id', :'s2', 'window_start','13:00','window_end','16:00')));
set test.uid = '66666666-6666-6666-6666-666666666666';
\echo '-- Mia: manager with NEITHER permission (expect ERROR)'
select public.set_delivery_stop_windows(:'d1'::date,
  jsonb_build_array(jsonb_build_object('stop_id', :'s1', 'window_start','11:00','window_end','14:00')));
set test.uid = '11111111-1111-1111-1111-111111111111';

\echo '-- no-op resave returns 0'
select public.set_delivery_stop_windows(:'d1'::date,
  jsonb_build_array(jsonb_build_object('stop_id', :'s1', 'window_start','10:00','window_end','13:00'))) as noop;
reset role;
select count(*) as window_set_events_now from public.delivery_route_events where action='WINDOW_SET';
set role authenticated;

\echo '-- malformed inputs (expect plain message each)'
select public.set_delivery_stop_windows(:'d1'::date,
  jsonb_build_array(jsonb_build_object('stop_id','not-a-uuid','window_start','10:00','window_end','13:00')));
select public.set_delivery_stop_windows(:'d1'::date,
  jsonb_build_array(jsonb_build_object('stop_id', :'s1', 'window_start','bogus','window_end','13:00')));
select public.set_delivery_stop_windows(:'d1'::date, '{"a":1}'::jsonb);
select public.set_delivery_stop_windows(:'d1'::date, '[]'::jsonb);
\echo '-- 137 matrix: cross-company + non-booked + wrong date + rollback'
select public.set_delivery_stop_windows(:'d1'::date,
  jsonb_build_array(
    jsonb_build_object('stop_id', :'s3', 'window_start','08:00','window_end','11:00'),
    jsonb_build_object('stop_id', :'sb', 'window_start','08:00','window_end','11:00')
  ));
select public.set_delivery_stop_windows(:'d1'::date,
  jsonb_build_array(jsonb_build_object('stop_id','e5000000-0000-0000-0000-0000000000c1','window_start','08:00','window_end','11:00')));
select public.set_delivery_stop_windows(:'d1'::date,
  jsonb_build_array(jsonb_build_object('stop_id','e5000000-0000-0000-0000-0000000000c2','window_start','08:00','window_end','11:00')));
select public.set_delivery_stop_windows(:'d1'::date,
  jsonb_build_array(jsonb_build_object('stop_id', :'s4', 'window_start','08:00','window_end','11:00')));
reset role;
select window_start, window_end from public.delivery_stops where id=:'s3';
set role authenticated;

\echo '-- closed day still accepts windows, version untouched'
select public.close_delivery_day(:'d1'::date, 0);
reset role;
select version as v_after_close from public.delivery_day_plans
where company_id='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' and date=:'d1'::date;
set role authenticated;
select public.set_delivery_stop_windows(:'d1'::date,
  jsonb_build_array(jsonb_build_object('stop_id', :'s3', 'window_start','08:00','window_end','11:00'))) as closed_ok;
reset role;
select version as v_after_windows, status from public.delivery_day_plans
where company_id='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' and date=:'d1'::date;
set role authenticated;
\echo '-- reopen d1 for later tests'
select public.reopen_delivery_day(:'d1'::date, 1);

\echo '=== T2: CONFIRMATION never moves scheduling state ==='
set test.uid = '22222222-2222-2222-2222-222222222222';
\echo '-- Alice logs SCHEDULING voicemail on JA1 (expect hold)'
select public.log_delivery_contact('d1000000-0000-0000-0000-0000000000a1','SCHEDULING','voicemail',null,null,null,'sched-key-1');
select public.get_delivery_contact_history('d1000000-0000-0000-0000-0000000000a1',5) as hist_before \gset
reset role;
select hist_before->>'held' as held_before, hist_before->>'hold_until' as hu_before,
       hist_before->>'callback_due' as cbd_before, hist_before->>'bad_number' as bad_before,
       hist_before->'last_contact'->>'contact_outcome' as lc_before
from (select :'hist_before'::jsonb as hist_before) t;
set role authenticated;
set test.uid = '77777777-7777-7777-7777-777777777777';
\echo '-- Sal logs CONFIRMATION confirmed on JA1 stop (coworker coverage)'
select public.log_delivery_confirmation('d1000000-0000-0000-0000-0000000000a1', :'s1', 'confirmed', null, null, 'conf-key-1');
select public.get_delivery_contact_history('d1000000-0000-0000-0000-0000000000a1',5) as hist_after_conf \gset
reset role;
select hist_after_conf->>'held' as held_after, hist_after_conf->>'hold_until' as hu_after,
       hist_after_conf->>'callback_due' as cbd_after, hist_after_conf->>'bad_number' as bad_after,
       hist_after_conf->'last_contact'->>'contact_outcome' as lc_after,
       (hist_after_conf->'last_contact'->>'purpose') as lc_purpose
from (select :'hist_after_conf'::jsonb as hist_after_conf) t;
set role authenticated;
\echo '-- CONFIRMATION wrong_number on the SAME customer key (JA2 shares phone)'
select public.log_delivery_confirmation('d1000000-0000-0000-0000-0000000000a2', :'s2', 'wrong_number');
select public.get_delivery_contact_history('d1000000-0000-0000-0000-0000000000a1',5)->>'bad_number' as bad_after_wrongnum;
\echo '-- CONFIRMATION rows still LISTED in history with purpose label'
select public.get_delivery_contact_history('d1000000-0000-0000-0000-0000000000a1',5)->'contacts' as contacts \gset
reset role;
select c->>'purpose' as purpose, c->>'contact_outcome' as outcome, c->>'employee_name' as emp
from jsonb_array_elements(:'contacts'::jsonb) c limit 5;
set role authenticated;
set test.uid = '22222222-2222-2222-2222-222222222222';
\echo '-- later SCHEDULING contacts behave per m134/135'
select public.log_delivery_contact('d1000000-0000-0000-0000-0000000000a1','SCHEDULING','spoke');
select public.get_delivery_contact_history('d1000000-0000-0000-0000-0000000000a1',5)->>'held' as held_after_spoke;
select public.log_delivery_contact('d1000000-0000-0000-0000-0000000000a1','SCHEDULING','wrong_number');
select public.get_delivery_contact_history('d1000000-0000-0000-0000-0000000000a1',5)->>'bad_number' as bad_after_sched_wrongnum,
       public.get_delivery_contact_history('d1000000-0000-0000-0000-0000000000a1',5)->>'held' as held_after_sched_wrongnum;

\echo '=== T3: log_delivery_contact rejects CONFIRMATION ==='
select public.log_delivery_contact('d1000000-0000-0000-0000-0000000000a1','CONFIRMATION','confirmed');

\echo '=== T4: log_delivery_confirmation rejections ==='
set test.uid = '77777777-7777-7777-7777-777777777777';
\echo '-- bad outcome (expect ERROR)'
select public.log_delivery_confirmation('d1000000-0000-0000-0000-0000000000a3', :'s3', 'confirmedd');
\echo '-- CANCELLED stop (expect ERROR)'
select public.log_delivery_confirmation('d1000000-0000-0000-0000-0000000000a6', 'e5000000-0000-0000-0000-0000000000c1', 'confirmed');
\echo '-- SUPERSEDED stop (expect ERROR)'
select public.log_delivery_confirmation('d1000000-0000-0000-0000-0000000000a7', 'e5000000-0000-0000-0000-0000000000c2', 'confirmed');
\echo '-- stop of another journey (JA3 journey + JA1 stop id) (expect ERROR)'
select public.log_delivery_confirmation('d1000000-0000-0000-0000-0000000000a3', :'s1', 'confirmed');
\echo '-- future occurred_at (expect ERROR)'
select public.log_delivery_confirmation('d1000000-0000-0000-0000-0000000000a3', :'s3', 'confirmed', null, now() + interval '1 hour');
\echo '-- occurred_at older than 7 days (expect ERROR)'
select public.log_delivery_confirmation('d1000000-0000-0000-0000-0000000000a3', :'s3', 'confirmed', null, now() - interval '8 days');
\echo '-- past delivery date stop (expect ERROR)'
select public.log_delivery_confirmation('d1000000-0000-0000-0000-0000000000a5', 'e5000000-0000-0000-0000-0000000000c3', 'confirmed');
\echo '-- company B stop from A (expect ERROR)'
select public.log_delivery_confirmation('d2000000-0000-0000-0000-0000000000b1', :'sb', 'confirmed');
set test.uid = '33333333-3333-3333-3333-333333333333';
\echo '-- company A stop from B (expect ERROR)'
select public.log_delivery_confirmation('d1000000-0000-0000-0000-0000000000a3', :'s3', 'confirmed');
set test.uid = '88888888-8888-8888-8888-888888888888';
\echo '-- user without permission via override (expect ERROR)'
select public.log_delivery_confirmation('d1000000-0000-0000-0000-0000000000a3', :'s3', 'confirmed');
set test.uid = '77777777-7777-7777-7777-777777777777';

\echo '=== T5: coworker coverage + snapshot ==='
\echo '-- Sal (sales) logs for JA3 stop assigned to herself; Alice logs JA3 too'
select public.log_delivery_confirmation('d1000000-0000-0000-0000-0000000000a3', :'s3', 'left_voicemail', 'call back after 6', null, 'conf-key-3') as sal_log \gset
reset role;
select created_by_employee_id, purpose, contact_outcome, stop_id,
       window_snapshot->>'delivery_date' as snap_date,
       window_snapshot->>'window_start' as snap_ws,
       window_snapshot->>'window_end' as snap_we,
       window_snapshot->>'truck_id' as snap_truck
from public.journey_interactions
where idempotency_key = 'conf-key-3';
set role authenticated;
set test.uid = '22222222-2222-2222-2222-222222222222';
\echo '-- Alice logs JA3 (assigned to Sal): allowed, caller recorded'
select public.log_delivery_confirmation('d1000000-0000-0000-0000-0000000000a3', :'s3', 'no_answer', null, null, 'conf-key-4') as alice_log \gset
reset role;
select created_by_employee_id = 'e1000000-0000-0000-0000-000000000002' as logged_by_alice
from public.journey_interactions where idempotency_key = 'conf-key-4';
set role authenticated;
\echo '-- day_only snapshot has null windows (settings are owner-only)'
set test.uid = '11111111-1111-1111-1111-111111111111';
select public.set_delivery_day_settings('10:00','19:00',3,'day_only');
set test.uid = '77777777-7777-7777-7777-777777777777';
select public.log_delivery_confirmation('d1000000-0000-0000-0000-0000000000a2', :'s2', 'confirmed', null, null, 'conf-key-5');
reset role;
select window_snapshot->>'window_start' as ws, window_snapshot->>'window_end' as we,
       window_snapshot->>'delivery_date' as d
from public.journey_interactions where idempotency_key = 'conf-key-5';
set role authenticated;
set test.uid = '11111111-1111-1111-1111-111111111111';
select public.set_delivery_day_settings('09:00','17:00',3,'window');

\echo '=== T6: call list status lifecycle ==='
set test.uid = '11111111-1111-1111-1111-111111111111';
\echo '-- owner all-scope list on d1'
select public.get_delivery_confirmation_list(:'d1'::date, 'all') as list_d1 \gset
reset role;
select jsonb_pretty((:'list_d1'::jsonb)->'items');
set role authenticated;
\echo '-- not_called -> confirmed on s3 (JA3, d1)'
set test.uid = '77777777-7777-7777-7777-777777777777';
select public.log_delivery_confirmation('d1000000-0000-0000-0000-0000000000a3', :'s3', 'confirmed', null, null, 'conf-key-6');
select public.get_delivery_confirmation_list(:'d1'::date, 'all') as list_d1b \gset
reset role;
select i->>'journey_number' as jn, i->>'status' as st, i->>'attempts' as att,
       i->>'window_start' as ws, i->>'outside_day_hours' as ooh
from jsonb_array_elements((:'list_d1b'::jsonb)->'items') i
where i->>'stop_id' = :'s3';
set role authenticated;
\echo '-- window edit makes it confirmed_window_changed'
select public.set_delivery_stop_windows(:'d1'::date,
  jsonb_build_array(jsonb_build_object('stop_id', :'s3', 'window_start','10:00','window_end','14:00')));
select public.get_delivery_confirmation_list(:'d1'::date, 'all') as list_d1c \gset
reset role;
select i->>'status' as st_after_edit
from jsonb_array_elements((:'list_d1c'::jsonb)->'items') i
where i->>'stop_id' = :'s3';
set role authenticated;
\echo '-- re-log confirmed -> confirmed again'
select public.log_delivery_confirmation('d1000000-0000-0000-0000-0000000000a3', :'s3', 'confirmed');
select public.get_delivery_confirmation_list(:'d1'::date, 'all') as list_d1d \gset
reset role;
select i->>'status' as st_relog
from jsonb_array_elements((:'list_d1d'::jsonb)->'items') i
where i->>'stop_id' = :'s3';
set role authenticated;
\echo '-- truck move / reorder does NOT stale it'
reset role;
update public.delivery_stops set truck_id='f1000000-0000-0000-0000-000000000002', route_position=5 where id=:'s3';
set role authenticated;
select public.get_delivery_confirmation_list(:'d1'::date, 'all') as list_d1e \gset
reset role;
select i->>'status' as st_after_move
from jsonb_array_elements((:'list_d1e'::jsonb)->'items') i
where i->>'stop_id' = :'s3';
set role authenticated;
\echo '-- list order follows truck sort_order, then route_position, unrouted last'
reset role;
-- Fourth stop on d1, unrouted (JA6 gets a fresh BOOKED row).
insert into public.delivery_stops
  (id, company_id, store_id, journey_id, delivery_date, status)
values
  ('e5000000-0000-0000-0000-0000000000c5','aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
   'a1000000-0000-0000-0000-000000000001','d1000000-0000-0000-0000-0000000000a6',
   (now() at time zone 'America/Denver')::date + 3,'BOOKED');
-- Truck2 has sort_order 1 (lower uuid is Truck1 with sort_order 2):
-- s2 pos1 and s1 pos2 on Truck2, s3 pos1 on Truck1, JA6 unrouted.
update public.delivery_stops set truck_id='f1000000-0000-0000-0000-000000000002', route_position=1 where id=:'s2';
update public.delivery_stops set truck_id='f1000000-0000-0000-0000-000000000002', route_position=2 where id=:'s1';
update public.delivery_stops set truck_id='f1000000-0000-0000-0000-000000000001', route_position=1 where id=:'s3';
set role authenticated;
set test.uid = '11111111-1111-1111-1111-111111111111';
select public.get_delivery_confirmation_list(:'d1'::date, 'all') as ord_list \gset
reset role;
select (select jsonb_agg(t.item->>'stop_id' order by t.ord)
        from jsonb_array_elements((:'ord_list'::jsonb)->'items')
             with ordinality as t(item, ord)
       ) as actual_order,
       (select jsonb_agg(t.item->>'stop_id' order by t.ord)
        from jsonb_array_elements((:'ord_list'::jsonb)->'items')
             with ordinality as t(item, ord)
       ) = jsonb_build_array(:'s2', :'s1', :'s3',
             'e5000000-0000-0000-0000-0000000000c5') as order_ok;
set role authenticated;
set test.uid = '11111111-1111-1111-1111-111111111111';
\echo '-- reschedule: new stop shows not_called'
set test.uid = '11111111-1111-1111-1111-111111111111';
select public.reschedule_delivery_stop(:'s3', :'d2'::date) as s3_new \gset
select public.get_delivery_confirmation_list(:'d1'::date, 'all') as list_d1f \gset
select public.get_delivery_confirmation_list(:'d2'::date, 'all') as list_d2f \gset
reset role;
select i->>'stop_id' as st, i->>'status' as status_d1
from jsonb_array_elements((:'list_d1f'::jsonb)->'items') i where i->>'journey_id'='d1000000-0000-0000-0000-0000000000a3';
select i->>'stop_id' as st2, i->>'status' as status_d2, i->>'stop_id' = :'s3_new' as is_new
from jsonb_array_elements((:'list_d2f'::jsonb)->'items') i where i->>'journey_id'='d1000000-0000-0000-0000-0000000000a3';
set role authenticated;
\echo '-- confirmed then no_answer later -> no_answer (on s4/JA4 d2)'
set test.uid = '22222222-2222-2222-2222-222222222222';
select public.log_delivery_confirmation('d1000000-0000-0000-0000-0000000000a4', :'s4', 'confirmed');
select public.log_delivery_confirmation('d1000000-0000-0000-0000-0000000000a4', :'s4', 'no_answer');
select public.get_delivery_confirmation_list(:'d2'::date, 'all') as list_d2g \gset
reset role;
select i->>'status' as st_final, i->>'attempts' as att
from jsonb_array_elements((:'list_d2g'::jsonb)->'items') i where i->>'stop_id' = :'s4';
set role authenticated;
\echo '-- day_only: windows never returned (settings are owner-only)'
set test.uid = '11111111-1111-1111-1111-111111111111';
select public.set_delivery_day_settings('10:00','19:00',3,'day_only');
select public.get_delivery_confirmation_list(:'d2'::date, 'all') as list_d2h \gset
reset role;
select i->>'window_start' as ws, i->>'window_end' as we, i->>'status' as st
from jsonb_array_elements((:'list_d2h'::jsonb)->'items') i limit 3;
select (:'list_d2h'::jsonb)->>'day_mode' as mode;
set role authenticated;
select public.set_delivery_day_settings('09:00','17:00',3,'window');

\echo '=== T7: scope ==='
set test.uid = '22222222-2222-2222-2222-222222222222';
\echo '-- Alice mine on d2 (JA4 assigned Alice)'
select public.get_delivery_confirmation_list(:'d2'::date, 'mine') as alice_mine \gset
reset role;
select count(*) as alice_items,
       count(*) filter (where i->>'assigned_employee_id' = 'e1000000-0000-0000-0000-000000000002') as alice_owned
from jsonb_array_elements((:'alice_mine'::jsonb)->'items') i;
set role authenticated;
\echo '-- owner mine on d1: JA2 unassigned falls back to booked_by (owner booked it)'
set test.uid = '11111111-1111-1111-1111-111111111111';
select public.get_delivery_confirmation_list(:'d1'::date, 'mine') as owner_mine \gset
reset role;
select i->>'journey_number' as jn, i->>'status' as st
from jsonb_array_elements((:'owner_mine'::jsonb)->'items') i;
set role authenticated;
\echo '-- bad scope (expect ERROR)'
select public.get_delivery_confirmation_list(:'d1'::date, 'everyone');
set test.uid = '33333333-3333-3333-3333-333333333333';
\echo '-- company B all scope: only JB1, B customer has same name+phone as A'
select public.get_delivery_confirmation_list(:'d1'::date, 'all') as b_list \gset
reset role;
select i->>'journey_number' as jn, i->>'customer_name' as cust, i->>'customer_phone' as ph
from jsonb_array_elements((:'b_list'::jsonb)->'items') i;
select count(*) as b_item_count from jsonb_array_elements((:'b_list'::jsonb)->'items') i;
set role authenticated;
\echo '-- B mine scope sees nothing of A'
select public.get_delivery_confirmation_list(:'d1'::date, 'mine') as b_mine \gset
reset role;
select jsonb_array_length((:'b_mine'::jsonb)->'items') as b_mine_count;
set role authenticated;

\echo '=== T8: date logic ==='
set test.uid = '11111111-1111-1111-1111-111111111111';
\echo '-- p_date null picks first date with stops (d1, 3 days out)'
select public.get_delivery_confirmation_list(null, 'all') as auto_list \gset
reset role;
select (:'auto_list'::jsonb)->>'date' as picked, (:'auto_list'::jsonb)->'available_dates' as avail;
set role authenticated;
\echo '-- explicit empty date returns items []'
select public.get_delivery_confirmation_list(((now() at time zone 'America/Denver')::date + 4), 'all') as empty_list \gset
reset role;
select jsonb_array_length((:'empty_list'::jsonb)->'items') as empty_count, (:'empty_list'::jsonb)->>'date' as d;
set role authenticated;
\echo '-- explicit today is allowed and returns JTODAY stop'
select public.get_delivery_confirmation_list((now() at time zone 'America/Denver')::date, 'all') as today_list \gset
reset role;
select i->>'journey_number' as jn from jsonb_array_elements((:'today_list'::jsonb)->'items') i;
set role authenticated;

\echo '=== T9: idempotency ==='
set test.uid = '22222222-2222-2222-2222-222222222222';
select public.log_delivery_confirmation('d1000000-0000-0000-0000-0000000000a4', :'s4', 'confirmed', null, null, 'idem-1') as first_call \gset
select public.log_delivery_confirmation('d1000000-0000-0000-0000-0000000000a4', :'s4', 'confirmed', null, null, 'idem-1') as second_call \gset
reset role;
select :'first_call'::jsonb->>'deduplicated' as d1, :'second_call'::jsonb->>'deduplicated' as d2,
       :'first_call'::jsonb->>'interaction_id' = :'second_call'::jsonb->>'interaction_id' as same_id;
set role authenticated;
set test.uid = '77777777-7777-7777-7777-777777777777';
\echo '-- same key, different employee (expect ERROR)'
select public.log_delivery_confirmation('d1000000-0000-0000-0000-0000000000a4', :'s4', 'confirmed', null, null, 'idem-1');
\echo '-- same key, different journey (expect ERROR)'
select public.log_delivery_confirmation('d1000000-0000-0000-0000-0000000000a3', :'s3_new', 'confirmed', null, null, 'idem-1');
set test.uid = '22222222-2222-2222-2222-222222222222';

\echo '=== T10: null-employee CONFIRMATION row ==='
reset role;
insert into public.journey_interactions
  (journey_id, customer_id, interaction_type, channel, direction,
   topic, topic_label, summary, outcome, waiting_on,
   occurred_at, created_by_employee_id, source_domain, is_internal,
   purpose, contact_outcome, stop_id, window_snapshot, company_id)
values
  ('d1000000-0000-0000-0000-0000000000a2','c1000000-0000-0000-0000-000000000002',
   'called_customer','phone_outbound','outbound','delivery','Delivery confirmation',
   'Delivery confirmation call: customer confirmed.','resolved','nothing',
   now(),null,'manual',false,'CONFIRMATION','confirmed',
   :'s2','{"delivery_date":"2099-01-01","window_start":null,"window_end":null,"truck_id":null}',
   'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
set role authenticated;
\echo '-- confirmation list still returns it, by_name null'
set test.uid = '11111111-1111-1111-1111-111111111111';
select public.get_delivery_confirmation_list(:'d1'::date, 'all') as list_null_emp \gset
reset role;
select i->>'status' as st, i->'last_call'->>'by_name' as by_name, i->>'attempts' as att
from jsonb_array_elements((:'list_null_emp'::jsonb)->'items') i where i->>'stop_id' = :'s2';
set role authenticated;
\echo '-- history lists it with null employee_name'
select public.get_delivery_contact_history('d1000000-0000-0000-0000-0000000000a2',10)->'contacts' as h_null \gset
reset role;
select c->>'purpose' as p, c->>'employee_name' as emp
from jsonb_array_elements(:'h_null'::jsonb) c where c->>'purpose'='CONFIRMATION' limit 3;
set role authenticated;
\echo '-- key_state/history/list_ready still work'
select public.get_delivery_contact_history('d1000000-0000-0000-0000-0000000000a2',5)->>'held' as held_ok;
select jsonb_array_length(public.list_ready_journeys(true)) as ready_rows;

\echo '=== T11: privileges, seeds, m134 lesson ==='
set role anon;
select public.log_delivery_confirmation('d1000000-0000-0000-0000-0000000000a1', :'s1', 'confirmed');
select public.get_delivery_confirmation_list(:'d1'::date, 'all');
select public.set_delivery_stop_windows(:'d1'::date, '[]'::jsonb);
reset role;
set role authenticated;
set test.uid = '22222222-2222-2222-2222-222222222222';
\echo '-- m134 lesson check: m138 adds no function to any index,'
\echo '   default or check constraint, so no caller needs new EXECUTE.'
\echo '   (Direct table DML as authenticated is not exercised here:'
\echo '   this bare-Postgres harness does not replicate Supabase table grants.)'
reset role;
\echo '-- brand new company D: owner/admin get set_windows, nobody else'
insert into public.companies (id, name, business_timezone)
values ('dddddddd-dddd-dddd-dddd-dddddddddddd','Company D','America/Denver');
select role, permission_key from public.role_permission_grants
where company_id='dddddddd-dddd-dddd-dddd-dddddddddddd'
  and permission_key='delivery.set_windows' order by role;
select count(*) as d_set_windows_grants from public.role_permission_grants
where company_id='dddddddd-dddd-dddd-dddd-dddddddddddd'
  and permission_key='delivery.set_windows';
select count(*) as d_logconf_grants from public.role_permission_grants
where company_id='dddddddd-dddd-dddd-dddd-dddddddddddd'
  and permission_key='delivery.log_confirmation_calls';

\echo '=== T12: execute privilege matrix ==='
select p.proname,
       has_function_privilege('anon', p.oid, 'EXECUTE') as anon_exec,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') as auth_exec
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname in
  ('log_delivery_confirmation','get_delivery_confirmation_list',
   'set_delivery_stop_windows','set_delivery_day_settings',
   'log_delivery_contact','delivery_contact_key_state')
order by p.proname;

\echo '=== T13: ready journeys shape spot check ==='
select r->>'journey_id' as j, r->>'held' as held, r->>'bad_number' as bad,
       r->'last_contact'->>'purpose' as lc_purpose,
       (r->'last_contact'->>'employee_name') as lc_emp
from jsonb_array_elements(public.list_ready_journeys(true)) r
where r->>'journey_id' like 'd1000000%' limit 5;
