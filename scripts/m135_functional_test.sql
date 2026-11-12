-- m135 FUNCTIONAL TEST — MUTATES DATA.
-- For a THROWAWAY database only. Never run against Supabase or real data.
--
-- Same auth shim as m134:
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
-- ALL RPC calls below run as the REAL role: set role authenticated with
-- a jwt sub (test.uid), never as superuser. Every "ERROR:" line is an
-- EXPECTED rejection.

\set ON_ERROR_STOP off
\pset footer off

-- ============================ SEED (superuser) ============================
insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111','owner@a.test'),
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
  ('e1000000-0000-0000-0000-000000000002','22222222-2222-2222-2222-222222222222','a1000000-0000-0000-0000-000000000001','sales','Sam','Sales',true),
  ('e2000000-0000-0000-0000-000000000001','33333333-3333-3333-3333-333333333333','b1000000-0000-0000-0000-000000000001','owner','Bob','Owner',true);

insert into public.delivery_trucks (id, company_id, name, default_stop_cap, weekly_pattern, sort_order) values
  ('f1000000-0000-0000-0000-000000000001','aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','Truck 1',10,'{1,2,3,4,5,6,7}',1);

-- Customer keys (each journey pair shares one customer_id = one key):
--   P: PA+PB  spoke-hold, sibling newer contact
--   Q: QA+QB  spoke+callback, hold_days toggles
--   R: RA     callback_after today -> callback_due
--   S: SA     wrong_number
--   T: TA+TB  spoke then sibling stop booking clears hold
--   U: UA     spoke 3 days ago does not hold
--   B-co: BB  company B, same phone as P (leak test)
insert into public.customers (id, first_name, last_name, phone, email, street_address, city, state, zip_code) values
  ('c1000000-0000-0000-0000-000000000001','Pat','Poe','555-111-0001','p@x.test','1 Main St','Denver','CO','80201'),
  ('c1000000-0000-0000-0000-000000000002','Quinn','Ray','555-111-0002','q@x.test','2 Main St','Denver','CO','80202'),
  ('c1000000-0000-0000-0000-000000000003','Rae','Lynn','555-111-0003','r@x.test','3 Main St','Denver','CO','80203'),
  ('c1000000-0000-0000-0000-000000000004','Sid','Nell','555-111-0004','s@x.test','4 Main St','Denver','CO','80204'),
  ('c1000000-0000-0000-0000-000000000005','Tess','Orne','555-111-0005','t@x.test','5 Main St','Denver','CO','80205'),
  ('c1000000-0000-0000-0000-000000000006','Uma','Voss','555-111-0006','u@x.test','6 Main St','Denver','CO','80206'),
  ('c2000000-0000-0000-0000-000000000001','Bea','Cross','555-111-0001','b@x.test','1 Main St','Boulder','CO','80301');

insert into public.sleep_journeys (id, customer_id, store_id, assigned_employee_id, current_state, fulfillment_type, price, journey_number) values
  ('d1000000-0000-0000-0000-0000000000a1','c1000000-0000-0000-0000-000000000001','a1000000-0000-0000-0000-000000000001','e1000000-0000-0000-0000-000000000002','Ready to Schedule','delivery',1000,'JA-001'),
  ('d1000000-0000-0000-0000-0000000000a2','c1000000-0000-0000-0000-000000000001','a1000000-0000-0000-0000-000000000001','e1000000-0000-0000-0000-000000000001','Ready to Schedule','delivery',1000,'JA-002'),
  ('d1000000-0000-0000-0000-0000000000a3','c1000000-0000-0000-0000-000000000002','a1000000-0000-0000-0000-000000000001',null,'Ready to Schedule','delivery',1000,'JA-003'),
  ('d1000000-0000-0000-0000-0000000000a4','c1000000-0000-0000-0000-000000000002','a1000000-0000-0000-0000-000000000001',null,'Ready to Schedule','delivery',1000,'JA-004'),
  ('d1000000-0000-0000-0000-0000000000a5','c1000000-0000-0000-0000-000000000003','a1000000-0000-0000-0000-000000000001',null,'Ready to Schedule','delivery',1000,'JA-005'),
  ('d1000000-0000-0000-0000-0000000000a6','c1000000-0000-0000-0000-000000000004','a1000000-0000-0000-0000-000000000001',null,'Ready to Schedule','delivery',1000,'JA-006'),
  ('d1000000-0000-0000-0000-0000000000a7','c1000000-0000-0000-0000-000000000005','a1000000-0000-0000-0000-000000000001',null,'Ready to Schedule','delivery',1000,'JA-007'),
  ('d1000000-0000-0000-0000-0000000000a8','c1000000-0000-0000-0000-000000000005','a1000000-0000-0000-0000-000000000001',null,'Ready to Schedule','delivery',1000,'JA-008'),
  ('d1000000-0000-0000-0000-0000000000a9','c1000000-0000-0000-0000-000000000006','a1000000-0000-0000-0000-000000000001',null,'Ready to Schedule','delivery',1000,'JA-009'),
  ('d2000000-0000-0000-0000-0000000000b1','c2000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000001',null,'Ready to Schedule','delivery',1000,'JB-001');

insert into public.journey_line_items (journey_id, item_name, quantity, unit_price)
select j.id, 'Mattress', 1, 1000
from public.sleep_journeys j;

-- Line items re-derive state to Quoted; pin the test state.
alter table public.sleep_journeys disable trigger user;
update public.sleep_journeys set current_state = 'Ready to Schedule';
alter table public.sleep_journeys enable trigger user;
select current_state, count(*) from public.sleep_journeys group by 1;

-- ======================= REAL ROLES FROM HERE =======================
set role authenticated;
set test.uid = '11111111-1111-1111-1111-111111111111';
set test.jwt = '{}';

\echo '=== T0: baseline - 9 ready rows in company A, none from B ==='
select count(*) as a_rows from jsonb_array_elements(public.list_ready_journeys(true)) r;
select count(*) as b_leak_rows
from jsonb_array_elements(public.list_ready_journeys(true)) r
where r->>'journey_id' = 'd2000000-0000-0000-0000-0000000000b1';

\echo '=== T1: spoke now HOLDS (m135) - held=true, hold_until set ==='
select public.log_delivery_contact(
  'd1000000-0000-0000-0000-0000000000a1','SCHEDULING','spoke',null,null,null,'m135-spoke-1') as spoke_id;
select (public.get_delivery_contact_history('d1000000-0000-0000-0000-0000000000a1',5))->>'held' as held,
       (public.get_delivery_contact_history('d1000000-0000-0000-0000-0000000000a1',5))->>'hold_until' as hold_until,
       (public.get_delivery_contact_history('d1000000-0000-0000-0000-0000000000a1',5))->'last_contact'->>'contact_outcome' as lc_outcome;
select r->>'journey_id' as jn, r->>'held' as held, r->>'hold_until' as hold_until
from jsonb_array_elements(public.list_ready_journeys(true)) r
where r->>'journey_id' in ('d1000000-0000-0000-0000-0000000000a1','d1000000-0000-0000-0000-0000000000a2') order by 1;

\echo '=== T2: spoke + callback_after ACCEPTED; hold_until = start of that day ==='
select ((now() at time zone 'America/Denver')::date + 5) as cb5 \gset
select public.log_delivery_contact(
  'd1000000-0000-0000-0000-0000000000a3','SCHEDULING','spoke',null,
  :'cb5'::date,null,'m135-spoke-cb') as spoke_cb_id;
select (public.get_delivery_contact_history('d1000000-0000-0000-0000-0000000000a3',5))->>'held' as held,
       ((public.get_delivery_contact_history('d1000000-0000-0000-0000-0000000000a3',5))->>'hold_until')::timestamptz as hold_until_utc;

\echo '=== T3: wrong_number + callback_after still REJECTED (EXPECTED error) ==='
select public.log_delivery_contact(
  'd1000000-0000-0000-0000-0000000000a6','SCHEDULING','wrong_number',null,
  ((now() at time zone 'America/Denver')::date + 2),null,'m135-wn-cb');

\echo '=== T4: wrong_number -> bad_number, no hold; newer spoke clears bad_number and holds ==='
select public.log_delivery_contact(
  'd1000000-0000-0000-0000-0000000000a6','SCHEDULING','wrong_number',null,null,null,'m135-wn-1') as wn_id;
select (public.get_delivery_contact_history('d1000000-0000-0000-0000-0000000000a6',5))->>'bad_number' as bad_after_wn,
       (public.get_delivery_contact_history('d1000000-0000-0000-0000-0000000000a6',5))->>'held' as held_after_wn;
select public.log_delivery_contact(
  'd1000000-0000-0000-0000-0000000000a6','SCHEDULING','spoke',null,null,null,'m135-spoke-2') as spoke2_id;
select (public.get_delivery_contact_history('d1000000-0000-0000-0000-0000000000a6',5))->>'bad_number' as bad_after_spoke,
       (public.get_delivery_contact_history('d1000000-0000-0000-0000-0000000000a6',5))->>'held' as held_after_spoke;

\echo '=== T5: newer voicemail on SIBLING order replaces spoke as latest (still held) ==='
select public.log_delivery_contact(
  'd1000000-0000-0000-0000-0000000000a2','SCHEDULING','voicemail',null,null,null,'m135-vm-sib') as sib_vm_id;
select (public.get_delivery_contact_history('d1000000-0000-0000-0000-0000000000a1',5))->'last_contact'->>'contact_outcome' as pa_lc_outcome,
       (public.get_delivery_contact_history('d1000000-0000-0000-0000-0000000000a1',5))->'last_contact'->>'on_this_order' as pa_on_this,
       (public.get_delivery_contact_history('d1000000-0000-0000-0000-0000000000a1',5))->>'held' as pa_held;

\echo '=== T6: spoke on TA, then stop booked on SIBLING TB clears the hold ==='
select public.log_delivery_contact(
  'd1000000-0000-0000-0000-0000000000a7','SCHEDULING','spoke',null,null,null,'m135-spoke-t') as ta_spoke;
select ((now() at time zone 'America/Denver')::date + 5) as bookdate \gset
select (public.get_delivery_contact_history('d1000000-0000-0000-0000-0000000000a7',5))->>'held' as ta_held_before;
select public.book_delivery_stop('d1000000-0000-0000-0000-0000000000a8', :'bookdate'::date) as tb_stop;
select (public.get_delivery_contact_history('d1000000-0000-0000-0000-0000000000a7',5))->>'held' as ta_held_after;

\echo '=== T7: hold_days = 0 disables spoke hold; back to 2 restores ==='
select public.set_delivery_contact_hold_days(0);
select (public.get_delivery_contact_history('d1000000-0000-0000-0000-0000000000a3',5))->>'held' as qa_held_days0;
select public.set_delivery_contact_hold_days(2);
select (public.get_delivery_contact_history('d1000000-0000-0000-0000-0000000000a3',5))->>'held' as qa_held_days2;

\echo '=== T8: hold_days = 2, spoke 3 days ago does NOT hold ==='
select public.log_delivery_contact(
  'd1000000-0000-0000-0000-0000000000a9','SCHEDULING','spoke',null,null,
  now() - interval '3 days','m135-spoke-old') as ua_old_spoke;
select (public.get_delivery_contact_history('d1000000-0000-0000-0000-0000000000a9',5))->>'held' as ua_held,
       (public.get_delivery_contact_history('d1000000-0000-0000-0000-0000000000a9',5))->>'hold_until' as ua_hold_until;

\echo '=== T9: callback_after = today -> callback_due true, held false ==='
select public.log_delivery_contact(
  'd1000000-0000-0000-0000-0000000000a5','SCHEDULING','spoke',null,
  (now() at time zone 'America/Denver')::date,null,'m135-spoke-today') as ra_spoke;
select (public.get_delivery_contact_history('d1000000-0000-0000-0000-0000000000a5',5))->>'callback_due' as ra_cb_due,
       (public.get_delivery_contact_history('d1000000-0000-0000-0000-0000000000a5',5))->>'held' as ra_held;

\echo '=== T10: two companies, same phone - no leak either way ==='
set test.uid = '33333333-3333-3333-3333-333333333333';
select public.log_delivery_contact(
  'd2000000-0000-0000-0000-0000000000b1','SCHEDULING','spoke','B spoke',null,null,'m135-b-spoke') as b_spoke;
select (public.get_delivery_contact_history('d2000000-0000-0000-0000-0000000000b1',10))->>'held' as b_held,
       jsonb_array_length((public.get_delivery_contact_history('d2000000-0000-0000-0000-0000000000b1',50))->'contacts') as b_hist_len;
set test.uid = '11111111-1111-1111-1111-111111111111';
select count(*) as b_rows_in_pa_history
from jsonb_array_elements((public.get_delivery_contact_history('d1000000-0000-0000-0000-0000000000a1',50))->'contacts') h
where h->>'journey_id' = 'd2000000-0000-0000-0000-0000000000b1';
select (public.get_delivery_contact_history('d1000000-0000-0000-0000-0000000000a1',5))->>'held' as pa_held_after_b;
set test.uid = '33333333-3333-3333-3333-333333333333';
select public.log_delivery_contact(
  'd1000000-0000-0000-0000-0000000000a1','SCHEDULING','voicemail');
set test.uid = '11111111-1111-1111-1111-111111111111';

\echo '=== T11: privilege re-check after replace ==='
select p.proname,
       has_function_privilege('anon', p.oid, 'EXECUTE') as anon_exec,
       has_function_privilege('public', p.oid, 'EXECUTE') as public_exec,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') as auth_exec,
       has_function_privilege('service_role', p.oid, 'EXECUTE') as service_exec
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname='public' and p.proname in (
  'log_delivery_contact','delivery_contact_key_state')
order by 1;

reset role;
