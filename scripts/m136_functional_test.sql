-- m136 FUNCTIONAL TEST — MUTATES DATA.
-- For a THROWAWAY database only. Never run against Supabase or real data.
--
-- Same auth shim as m134/m135. ALL RPC calls run as the REAL role:
-- set role authenticated with a jwt sub (test.uid). Seed runs as
-- superuser before the role switch. Every "ERROR:" line is EXPECTED.

\set ON_ERROR_STOP off
\pset footer off
\timing on

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
  ('a1000000-0000-0000-0000-000000000002','aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','A Store 2','AA2','America/Denver',true),
  ('b1000000-0000-0000-0000-000000000001','bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb','B Store','BBB','America/Denver',true);

insert into public.employees (id, auth_user_id, home_store_id, role, first_name, last_name, is_active) values
  ('e1000000-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','a1000000-0000-0000-0000-000000000001','owner','Amy','Owner',true),
  ('e1000000-0000-0000-0000-000000000002','22222222-2222-2222-2222-222222222222','a1000000-0000-0000-0000-000000000001','sales','Sam','Sales',true),
  ('e2000000-0000-0000-0000-000000000001','33333333-3333-3333-3333-333333333333','b1000000-0000-0000-0000-000000000001','owner','Bob','Owner',true);

-- c1: normal phone+email. c2: WHITESPACE phone+email -> null.
-- c3: normal phone, WHITESPACE email -> email null (email is NOT NULL
-- in the schema, so whitespace is the only "blank" case). c4 (company
-- B): different customer, must never appear in A rows.
insert into public.customers (id, first_name, last_name, phone, email, street_address, city, state, zip_code) values
  ('c1000000-0000-0000-0000-000000000001','Ann','Able','555-222-0001','ann@x.test','1 Main St','Denver','CO','80201'),
  ('c1000000-0000-0000-0000-000000000002','Bo','Blank','   ','   ','2 Main St','Denver','CO','80202'),
  ('c1000000-0000-0000-0000-000000000003','Cy','Fone','555-222-0003','   ','3 Main St','Denver','CO','80203'),
  ('c2000000-0000-0000-0000-000000000001','Di','Dee','555-222-9999','dee@x.test','9 Main St','Boulder','CO','80301');

insert into public.sleep_journeys (id, customer_id, store_id, assigned_employee_id, current_state, fulfillment_type, price, journey_number) values
  ('d1000000-0000-0000-0000-0000000000a1','c1000000-0000-0000-0000-000000000001','a1000000-0000-0000-0000-000000000001','e1000000-0000-0000-0000-000000000002','Ready to Schedule','delivery',1000,'JA-001'),
  ('d1000000-0000-0000-0000-0000000000a2','c1000000-0000-0000-0000-000000000002','a1000000-0000-0000-0000-000000000001',null,'Ready to Schedule','delivery',1000,'JA-002'),
  ('d1000000-0000-0000-0000-0000000000a3','c1000000-0000-0000-0000-000000000003','a1000000-0000-0000-0000-000000000002',null,'Ready to Schedule','delivery',1000,'JA-003'),
  ('d2000000-0000-0000-0000-0000000000b1','c2000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000001',null,'Ready to Schedule','delivery',1000,'JB-001');

insert into public.journey_line_items (journey_id, item_name, quantity, unit_price)
select j.id, 'Mattress', 1, 1000 from public.sleep_journeys j;

-- ~500 extra ready journeys in company A for the timing check, spread
-- across the three A customers so the key-state CTE still dedupes.
insert into public.sleep_journeys (id, customer_id, store_id, current_state, fulfillment_type, price)
select ('d1000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid,
       (array['c1000000-0000-0000-0000-000000000001',
              'c1000000-0000-0000-0000-000000000002',
              'c1000000-0000-0000-0000-000000000003'])[1 + (i % 3)]::uuid,
       'a1000000-0000-0000-0000-000000000001',
       'Ready to Schedule','delivery',1000
from generate_series(1, 490) i;
insert into public.journey_line_items (journey_id, item_name, quantity, unit_price)
select id, 'Mattress', 1, 1000 from public.sleep_journeys
where id::text like 'd1000000-0000-0000-0000-%';

alter table public.sleep_journeys disable trigger user;
update public.sleep_journeys set current_state = 'Ready to Schedule';
alter table public.sleep_journeys enable trigger user;
select current_state, count(*) from public.sleep_journeys group by 1;

-- ======================= REAL ROLES FROM HERE =======================
set role authenticated;
set test.uid = '11111111-1111-1111-1111-111111111111';
set test.jwt = '{}';

\echo '=== T1: rows carry customer_phone + customer_email, per-order correct ==='
select r->>'journey_id' as jn, r->>'customer_name' as cust,
       r->>'customer_phone' as phone, r->>'customer_email' as email
from jsonb_array_elements(public.list_ready_journeys(true)) r
where r->>'journey_id' in (
  'd1000000-0000-0000-0000-0000000000a1',
  'd1000000-0000-0000-0000-0000000000a2',
  'd1000000-0000-0000-0000-0000000000a3')
order by 1;

\echo '=== T2: whitespace phone/email come back null ==='
select r->>'customer_phone' as phone_is_null, r->>'customer_email' as email_is_null
from jsonb_array_elements(public.list_ready_journeys(true)) r
where r->>'journey_id' = 'd1000000-0000-0000-0000-0000000000a2';

\echo '=== T3: existing keys still present ==='
select r->>'journey_id' as jn,
       r->>'held' as held, r->>'bad_number' as bad,
       r->>'callback_due' as cbdue, r->>'hold_until' as hu,
       (r->'last_contact' is not null) as has_lc,
       r->>'customer_name' as cname, r->>'store_name' as sname,
       r->>'item_summary' as items
from jsonb_array_elements(public.list_ready_journeys(true)) r
where r->>'journey_id' = 'd1000000-0000-0000-0000-0000000000a1';

\echo '=== T4: company scoping - B rows/phones never visible; allStores stays in company ==='
select count(*) as total_rows,
       count(*) filter (where r->>'customer_phone' = '555-222-9999') as b_phone_leak,
       count(*) filter (where r->>'customer_email' = 'dee@x.test') as b_email_leak
from jsonb_array_elements(public.list_ready_journeys(true)) r;
set test.uid = '33333333-3333-3333-3333-333333333333';
select count(*) as b_rows, count(*) filter (where r->>'journey_id' like 'd1%') as a_leak
from jsonb_array_elements(public.list_ready_journeys(true)) r;
select r->>'customer_phone' as b_phone, r->>'customer_email' as b_email
from jsonb_array_elements(public.list_ready_journeys(true)) r;
set test.uid = '11111111-1111-1111-1111-111111111111';

\echo '=== T5: scoped (non-allStores) still returns the new keys ==='
-- Owner with no active-store claim sees only own assignments (none
-- here). Set the claim the app writes at store-select so the scoped
-- path returns rows.
set test.jwt = '{"user_metadata":{"active_store_id":"a1000000-0000-0000-0000-000000000001"}}';
select count(*) as scoped_rows,
       count(*) filter (where r->>'customer_phone' is not null or r->>'customer_email' is not null) as with_contact
from jsonb_array_elements(public.list_ready_journeys(false)) r;
set test.jwt = '{}';

\echo '=== T6: anon cannot execute ==='
set role anon;
select public.list_ready_journeys(true);
reset role;
set role authenticated;

\echo '=== T7: timing - ~493 ready journeys ==='
select count(*) as rows_to_time from jsonb_array_elements(public.list_ready_journeys(true)) r \gset
\timing on
select count(*) as timed_rows from jsonb_array_elements(public.list_ready_journeys(true)) r;
\timing off

reset role;
