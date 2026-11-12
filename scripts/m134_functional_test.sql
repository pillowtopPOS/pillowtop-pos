-- m134 FUNCTIONAL TEST — MUTATES DATA.
-- For a THROWAWAY database only. Never run against Supabase or real data.
--
-- Requires the auth shim used for local harness testing:
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

-- ============================ SEED ============================
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

-- c1/c2 share a normalized phone (different customer_id — the
-- "same person, two orders" case). c3/c4 share a JUNK phone that must
-- never match. c6 in company B shares c1's phone (leak test).
insert into public.customers (id, first_name, last_name, phone, email, street_address, city, state, zip_code) values
  ('c1000000-0000-0000-0000-000000000001','Hilda','Hale','555-555-0101','h1@x.test','1 Main St','Denver','CO','80201'),
  ('c1000000-0000-0000-0000-000000000002','Hilda','Hale-dup','1-555-555-0101','h2@x.test','9 Other Rd','Denver','CO','80202'),
  ('c1000000-0000-0000-0000-000000000003','Junk','A','111-111-1111','j3@x.test','3 Pine','Denver','CO','80010'),
  ('c1000000-0000-0000-0000-000000000004','Junk','B','111-111-1111','j4@x.test','4 Elm','Denver','CO','80011'),
  ('c1000000-0000-0000-0000-000000000005','Solo','Five','555-555-0199','s5@x.test','5 Ash','Denver','CO','80012'),
  ('c1000000-0000-0000-0000-000000000006','General','Six','555-555-0200','g6@x.test','6 Birch','Denver','CO','80013'),
  ('c1000000-0000-0000-0000-000000000007','Old','Seven','555-555-0300','o7@x.test','7 Cedar','Denver','CO','80014'),
  ('c2000000-0000-0000-0000-000000000001','Hilda','Bee','555-555-0101','hb@x.test','1 Main St','Boulder','CO','80301');

insert into public.sleep_journeys (id, customer_id, store_id, assigned_employee_id, current_state, fulfillment_type, price, journey_number) values
  ('d1000000-0000-0000-0000-0000000000a1','c1000000-0000-0000-0000-000000000001','a1000000-0000-0000-0000-000000000001','e1000000-0000-0000-0000-000000000002','Ready to Schedule','delivery',1000,'d1000000-0000-0000-0000-0000000000a1'),
  ('d1000000-0000-0000-0000-0000000000a2','c1000000-0000-0000-0000-000000000002','a1000000-0000-0000-0000-000000000001','e1000000-0000-0000-0000-000000000001','Ready to Schedule','delivery',1000,'d1000000-0000-0000-0000-0000000000a2'),
  ('d1000000-0000-0000-0000-0000000000a3','c1000000-0000-0000-0000-000000000003','a1000000-0000-0000-0000-000000000001',null,'Ready to Schedule','delivery',1000,'d1000000-0000-0000-0000-0000000000a3'),
  ('d1000000-0000-0000-0000-0000000000a4','c1000000-0000-0000-0000-000000000004','a1000000-0000-0000-0000-000000000001',null,'Ready to Schedule','delivery',1000,'SJ-A00004'),
  ('d1000000-0000-0000-0000-0000000000a5','c1000000-0000-0000-0000-000000000005','a1000000-0000-0000-0000-000000000001',null,'Ready to Schedule','delivery',1000,'d1000000-0000-0000-0000-0000000000a5'),
  ('d1000000-0000-0000-0000-0000000000a6','c1000000-0000-0000-0000-000000000006','a1000000-0000-0000-0000-000000000001',null,'Ready to Schedule','delivery',1000,'d1000000-0000-0000-0000-0000000000a6'),
  ('d1000000-0000-0000-0000-0000000000a7','c1000000-0000-0000-0000-000000000007','a1000000-0000-0000-0000-000000000001',null,'Ready to Schedule','delivery',1000,'SJ-A00007'),
  ('d2000000-0000-0000-0000-0000000000b1','c2000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000001',null,'Ready to Schedule','delivery',1000,'SJ-B00001');

insert into public.journey_line_items (journey_id, item_name, quantity, unit_price)
select j.id, 'Mattress', 1, 1000
from public.sleep_journeys j;

-- Adding line items re-derives state to Quoted, and writing
-- current_state directly re-fires the state observers which derive it
-- right back. Pin the test state with user triggers off (throwaway DB).
alter table public.sleep_journeys disable trigger user;
update public.sleep_journeys set current_state = 'Ready to Schedule';
alter table public.sleep_journeys enable trigger user;
select current_state, count(*) from public.sleep_journeys group by 1;

set test.uid = '11111111-1111-1111-1111-111111111111';
set test.jwt = '{}';

\echo '=== S0: baseline — 7 ready rows in A visible to owner (allStores), none in B ==='
select jsonb_array_length(public.list_ready_journeys(true)) as a_rows \gset
select jsonb_array_length(public.list_ready_journeys(false)) as a_rows_scoped \gset
select r->>'journey_id' as jn, r->'last_contact' as lc, r->>'held' as held, r->>'bad_number' as bn
from jsonb_array_elements(public.list_ready_journeys(true)) r
where r->>'journey_id' in ('d1000000-0000-0000-0000-0000000000a1','d1000000-0000-0000-0000-0000000000a2') order by 1;

\echo '=== S1: log voicemail on J1 + idempotent repeat ==='
select public.log_delivery_contact(
  'd1000000-0000-0000-0000-0000000000a1','SCHEDULING','voicemail',
  'Called about delivery day', null, null, 'm134-key-1', null, null) as contact_v1 \gset
select public.log_delivery_contact(
  'd1000000-0000-0000-0000-0000000000a1','SCHEDULING','voicemail',
  'Called about delivery day', null, null, 'm134-key-1', null, null) as contact_v1_repeat;
select purpose, contact_outcome, callback_after, company_id, outcome, waiting_on, topic, channel, direction,
       left(summary,60) as summary, commitment_made, is_internal, source_domain
from public.journey_interactions where id = :'contact_v1';

\echo '=== S2: My Work row state — J1 held, J2 (same phone, other order) held via key ==='
select r->>'journey_id' as jn,
       r->'last_contact'->>'contact_outcome' as lc_outcome,
       r->'last_contact'->>'journey_id' as lc_journey,
       r->'last_contact'->>'on_this_order' as on_this,
       r->>'held' as held, r->>'hold_until' as hold_until, r->>'callback_due' as cb_due, r->>'bad_number' as bn
from jsonb_array_elements(public.list_ready_journeys(true)) r
where r->>'journey_id' in ('d1000000-0000-0000-0000-0000000000a1','d1000000-0000-0000-0000-0000000000a2','d1000000-0000-0000-0000-0000000000a3') order by 1;

\echo '=== S3: history on J2 sees J1 contact (cross-order, same phone) ==='
select h->>'journey_number' as h_jn, h->>'on_this_order' as on_this, h->>'contact_outcome' as oc, h->>'employee_name' as emp
from jsonb_array_elements((public.get_delivery_contact_history('d1000000-0000-0000-0000-0000000000a2',20))->'contacts') h;
select (public.get_delivery_contact_history('d1000000-0000-0000-0000-0000000000a2',20))->>'recent_contact_minutes' as rec_min,
       (public.get_delivery_contact_history('d1000000-0000-0000-0000-0000000000a2',20))->>'held' as held;

\echo '=== S4: outcome + callback validation (all EXPECTED errors) ==='
select public.log_delivery_contact('d1000000-0000-0000-0000-0000000000a5','SCHEDULING','bogus');
select public.log_delivery_contact('d1000000-0000-0000-0000-0000000000a5','GENERAL','voicemail');
select public.log_delivery_contact('d1000000-0000-0000-0000-0000000000a5','SCHEDULING','not_ready');
select public.log_delivery_contact('d1000000-0000-0000-0000-0000000000a5','SCHEDULING','not_ready',null,(public.delivery_company_today()-1));
select public.log_delivery_contact('d1000000-0000-0000-0000-0000000000a5','SCHEDULING','not_ready',null,(public.delivery_company_today()+91));
-- m135 update: callback_after is now ALLOWED on spoke; only wrong_number
-- rejects it. Kept as an expected error using wrong_number instead.
select public.log_delivery_contact('d1000000-0000-0000-0000-0000000000a5','SCHEDULING','wrong_number',null,(public.delivery_company_today()+2));
select public.log_delivery_contact('d1000000-0000-0000-0000-0000000000a5','SCHEDULING','voicemail',null,null,now()+interval '1 hour');
select public.log_delivery_contact('d1000000-0000-0000-0000-0000000000a5','SCHEDULING','voicemail',null,null,now()-interval '8 days');
select public.log_delivery_contact('d1000000-0000-0000-0000-0000000000a5','SCHEDULING','voicemail',null,null,null,'x',gen_random_uuid(),null);

\echo '=== S5: valid callback variants — callback allowed on ALL hold outcomes ==='
select public.log_delivery_contact('d1000000-0000-0000-0000-0000000000a3','SCHEDULING','voicemail',null,(public.delivery_company_today()+2)) as vm_cb_ok;
select public.log_delivery_contact('d1000000-0000-0000-0000-0000000000a3','SCHEDULING','texted',null,(public.delivery_company_today()+2)) as txt_cb_ok;
select public.log_delivery_contact('d1000000-0000-0000-0000-0000000000a3','SCHEDULING','no_answer',null,(public.delivery_company_today()+2)) as na_cb_ok;
select public.log_delivery_contact('d1000000-0000-0000-0000-0000000000a3','SCHEDULING','wrong_number',null,(public.delivery_company_today()+2));
select (public.get_delivery_contact_history('d1000000-0000-0000-0000-0000000000a3',5))->>'hold_until' as j3_hold_until;
select public.log_delivery_contact('d1000000-0000-0000-0000-0000000000a5','SCHEDULING','not_ready','Needs to think', (public.delivery_company_today()+3)) as nr_ok;
select public.log_delivery_contact('d1000000-0000-0000-0000-0000000000a5','SCHEDULING','will_call_back') as wcb_ok;
select public.log_delivery_contact('d1000000-0000-0000-0000-0000000000a5','SCHEDULING','will_call_back',null,(public.delivery_company_today()+1)) as wcb_cb_ok;
select r->>'journey_id' as jn, r->>'held' as held, r->>'hold_until' as hold_until, r->>'callback_due' as cb_due
from jsonb_array_elements(public.list_ready_journeys(true)) r where r->>'journey_id'='d1000000-0000-0000-0000-0000000000a5';

\echo '=== S6: callback_due — will_call_back with callback_after = TODAY ==='
select public.log_delivery_contact('d1000000-0000-0000-0000-0000000000a4','SCHEDULING','will_call_back',null,public.delivery_company_today()) as cb_today;
select (public.get_delivery_contact_history('d1000000-0000-0000-0000-0000000000a4',5))->>'callback_due' as cb_due,
       (public.get_delivery_contact_history('d1000000-0000-0000-0000-0000000000a4',5))->>'held' as held;

\echo '=== S7: wrong_number -> bad_number, no hold; newer contact clears ==='
select public.log_delivery_contact('d1000000-0000-0000-0000-0000000000a4','SCHEDULING','wrong_number') as wn1;
select (public.get_delivery_contact_history('d1000000-0000-0000-0000-0000000000a4',5))->>'bad_number' as bad_after_wn,
       (public.get_delivery_contact_history('d1000000-0000-0000-0000-0000000000a4',5))->>'held' as held_after_wn;
select public.log_delivery_contact('d1000000-0000-0000-0000-0000000000a4','SCHEDULING','voicemail') as vm_after_wn;
select (public.get_delivery_contact_history('d1000000-0000-0000-0000-0000000000a4',5))->>'bad_number' as bad_after_vm,
       (public.get_delivery_contact_history('d1000000-0000-0000-0000-0000000000a4',5))->>'held' as held_after_vm;
-- m135 update: spoke now HOLDS like the other hold outcomes, so
-- held_after_spoke is expected true (was false under m134).
select public.log_delivery_contact('d1000000-0000-0000-0000-0000000000a4','SCHEDULING','spoke') as spoke_last;
select (public.get_delivery_contact_history('d1000000-0000-0000-0000-0000000000a4',5))->>'held' as held_after_spoke;

\echo '=== S8: junk phones never match (J3 vs J4 share 111-111-1111) ==='
select public.log_delivery_contact('d1000000-0000-0000-0000-0000000000a3','SCHEDULING','voicemail') as junk3;
select count(*) as j4_sees_j3
from jsonb_array_elements((public.get_delivery_contact_history('d1000000-0000-0000-0000-0000000000a4',50))->'contacts') h
where h->>'journey_id' = 'd1000000-0000-0000-0000-0000000000a3';

\echo '=== S9: GENERAL interactions produce no tag ==='
select public.record_journey_interaction('d1000000-0000-0000-0000-0000000000a6','internal_note','just a note','gen-key-1') as gen_id;
select r->>'journey_id' as jn, r->'last_contact' as lc, r->>'held' as held
from jsonb_array_elements(public.list_ready_journeys(true)) r where r->>'journey_id'='d1000000-0000-0000-0000-0000000000a6';
select jsonb_array_length((public.get_delivery_contact_history('d1000000-0000-0000-0000-0000000000a6',50))->'contacts') as hist_len;

\echo '=== S10: hold_days = 0 disables; permission check ==='
set test.uid = '22222222-2222-2222-2222-222222222222';
select public.set_delivery_contact_hold_days(0);
set test.uid = '11111111-1111-1111-1111-111111111111';
select public.set_delivery_contact_hold_days(0);
select (public.get_delivery_contact_history('d1000000-0000-0000-0000-0000000000a1',5))->>'held' as held_days0;
select public.set_delivery_contact_hold_days(2);
select public.set_delivery_contact_hold_days(15);
select public.get_delivery_contact_hold_days();

\echo '=== S11: occurred_at age — yesterday holds, 3-days-ago expired (J7) ==='
select public.log_delivery_contact('d1000000-0000-0000-0000-0000000000a7','SCHEDULING','voicemail',null,null,now()-interval '3 days') as old3;
select (public.get_delivery_contact_history('d1000000-0000-0000-0000-0000000000a7',5))->>'held' as held_3d,
       (public.get_delivery_contact_history('d1000000-0000-0000-0000-0000000000a7',5))->>'hold_until' as hu_3d;
select public.log_delivery_contact('d1000000-0000-0000-0000-0000000000a7','SCHEDULING','voicemail',null,null,now()-interval '1 day') as old1;
select (public.get_delivery_contact_history('d1000000-0000-0000-0000-0000000000a7',5))->>'held' as held_1d,
       (public.get_delivery_contact_history('d1000000-0000-0000-0000-0000000000a7',5))->>'hold_until' as hu_1d;

\echo '=== S12: booking a SIBLING order clears the hold (J2 books, J1 unholds) ==='
select current_state, count(*) from public.sleep_journeys group by 1;
select r->>'journey_id' as jn, r->>'held' as held_before
from jsonb_array_elements(public.list_ready_journeys(true)) r where r->>'journey_id' in ('d1000000-0000-0000-0000-0000000000a1','d1000000-0000-0000-0000-0000000000a2') order by 1;
select ((now() at time zone 'America/Denver')::date + 5)::text as bookdate \gset
select public.book_delivery_stop('d1000000-0000-0000-0000-0000000000a2', :'bookdate'::date) as j2_stop \gset
select r->>'journey_id' as jn, r->>'held' as held_after, r->'last_contact'->>'journey_number' as lc_jn
from jsonb_array_elements(public.list_ready_journeys(true)) r where r->>'journey_id'='d1000000-0000-0000-0000-0000000000a1';

\echo '=== S13: entered_in_error contact is ignored ==='
select public.mark_interaction_entered_in_error(:'contact_v1'::uuid, 'wrong outcome logged') as marked;
select (public.get_delivery_contact_history('d1000000-0000-0000-0000-0000000000a1',10))->>'held' as held_after_error,
       (public.get_delivery_contact_history('d1000000-0000-0000-0000-0000000000a1',10))->'last_contact' as lc_after_error;

\echo '=== S14: two companies — same phone, no leak ==='
set test.uid = '33333333-3333-3333-3333-333333333333';
select public.log_delivery_contact('d2000000-0000-0000-0000-0000000000b1','SCHEDULING','voicemail','B call') as b_contact;
set test.uid = '11111111-1111-1111-1111-111111111111';
select count(*) as b_rows_in_a1_history
from jsonb_array_elements((public.get_delivery_contact_history('d1000000-0000-0000-0000-0000000000a1',50))->'contacts') h
where h->>'journey_id' = 'd2000000-0000-0000-0000-0000000000b1';
select public.log_delivery_contact('d2000000-0000-0000-0000-0000000000b1','SCHEDULING','voicemail');
set test.uid = '33333333-3333-3333-3333-333333333333';
select count(*) as b_rows_visible_to_b
from jsonb_array_elements((public.get_delivery_contact_history('d2000000-0000-0000-0000-0000000000b1',50))->'contacts') h;

\echo '=== S15: sales user sees subset without allStores, still gets contact fields ==='
set test.uid = '22222222-2222-2222-2222-222222222222';
select count(*) as sales_scoped_rows from jsonb_array_elements(public.list_ready_journeys(false)) r;
select r->>'journey_id' as jn, r->>'held' as held, r->'last_contact'->>'contact_outcome' as lc
from jsonb_array_elements(public.list_ready_journeys(false)) r;

\echo '=== S16: CONFIRMATION purpose + stop_id/window_snapshot ==='
set test.uid = '11111111-1111-1111-1111-111111111111';
select public.book_delivery_stop('d1000000-0000-0000-0000-0000000000a6', :'bookdate'::date) as j6_stop \gset
select public.log_delivery_contact('d1000000-0000-0000-0000-0000000000a6','CONFIRMATION','confirmed','window ok',null,null,null,:'j6_stop', '{"window_start":"08:00","window_end":"12:00"}'::jsonb) as conf_id \gset
select purpose, contact_outcome, stop_id, window_snapshot, company_id, outcome, topic
from public.journey_interactions where id = :'conf_id';
select public.log_delivery_contact('d1000000-0000-0000-0000-0000000000a6','CONFIRMATION','confirmed',null,null,null,null,gen_random_uuid());

\echo '=== S17: privilege check - anon/public cannot execute new RPCs ==='
select p.proname,
       has_function_privilege('anon', p.oid, 'EXECUTE') as anon_exec,
       has_function_privilege('public', p.oid, 'EXECUTE') as public_exec,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') as auth_exec,
       has_function_privilege('service_role', p.oid, 'EXECUTE') as service_exec
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname='public' and p.proname in (
  'log_delivery_contact','get_delivery_contact_history',
  'get_delivery_contact_hold_days','set_delivery_contact_hold_days',
  'delivery_contact_key_state','delivery_norm_phone','list_ready_journeys')
order by 1;

\echo '=== S18: delivery_norm_phone under real roles (index expr runs as caller) ==='
-- Mirror Supabase defaults the local harness lacks: authenticated and
-- service_role hold table DML on public tables (SELECT is needed for
-- RETURNING); service_role bypasses RLS.
grant select, insert, update on public.customers to authenticated, service_role;
-- The customers RLS policies call is_journey_visible/is_store_visible,
-- which read sleep_journeys/stores/employees; Supabase grants SELECT on
-- these to authenticated, the local harness does not.
grant select on public.sleep_journeys, public.stores, public.employees, public.companies
  to authenticated, service_role;
alter role service_role bypassrls;

set role authenticated;
set test.uid = '11111111-1111-1111-1111-111111111111';
-- Fixed id: RETURNING would re-read the row under the SELECT policy,
-- which requires a visible journey the brand-new customer does not have.
insert into public.customers (id, first_name, last_name, phone, email, street_address, city, state, zip_code)
values ('c1000000-0000-0000-0000-000000000099','Role','Insert','555-123-4567','ri@x.test','1 Test St','Denver','CO','80201');
update public.customers set phone = '555-987-6543' where id = 'c1000000-0000-0000-0000-000000000007';
update public.customers set phone = '555-111-2222' where id = 'c1000000-0000-0000-0000-000000000099';
-- customers.phone is NOT NULL, so the null-phone case is expected to
-- fail on the constraint (still exercises the index path attempt).
insert into public.customers (first_name, last_name, phone, email, street_address, city, state, zip_code)
values ('Role','NullPhone',null,'rn@x.test','2 Test St','Denver','CO','80201');

set role service_role;
insert into public.customers (first_name, last_name, phone, email, street_address, city, state, zip_code)
values ('Role','Service','555-222-3333','rs@x.test','3 Test St','Denver','CO','80201');
select public.delivery_norm_phone('555-123-4567') as service_norm_ok;

set role anon;
select public.delivery_norm_phone('555-123-4567');
reset role;
select id, phone from public.customers where id = 'c1000000-0000-0000-0000-000000000099';

\echo '=== S19: idempotency key is scoped to order + employee ==='
set test.uid = '11111111-1111-1111-1111-111111111111';
select public.log_delivery_contact('d1000000-0000-0000-0000-0000000000a1','SCHEDULING','voicemail',null,null,null,'m134-key-2',null,null) as k2_first \gset
select public.log_delivery_contact('d1000000-0000-0000-0000-0000000000a1','SCHEDULING','voicemail',null,null,null,'m134-key-2',null,null) as k2_repeat;
select count(*) as k2_rows from public.journey_interactions where idempotency_key = 'm134-key-2';
select public.log_delivery_contact('d1000000-0000-0000-0000-0000000000a2','SCHEDULING','voicemail',null,null,null,'m134-key-2',null,null);
set test.uid = '22222222-2222-2222-2222-222222222222';
select public.log_delivery_contact('d1000000-0000-0000-0000-0000000000a1','SCHEDULING','voicemail',null,null,null,'m134-key-2',null,null);
set test.uid = '33333333-3333-3333-3333-333333333333';
select public.log_delivery_contact('d2000000-0000-0000-0000-0000000000b1','SCHEDULING','voicemail',null,null,null,'m134-key-2',null,null);
