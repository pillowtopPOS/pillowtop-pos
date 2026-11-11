-- m132 FUNCTIONAL TEST — MUTATES DATA.
-- For a THROWAWAY database only (local Postgres harness). Never run
-- against Supabase or any database with real data.
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
  ('11111111-1111-1111-1111-111111111111','mgr@a.test'),
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

-- Two trucks, cap 3 each -> pooled capacity 6 for the test date.
insert into public.delivery_trucks (id, company_id, name, default_stop_cap, weekly_pattern, sort_order) values
  ('f1000000-0000-0000-0000-000000000001','aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','Truck 1',3,'{1,2,3,4,5,6,7}',1),
  ('f1000000-0000-0000-0000-000000000002','aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','Truck 2',3,'{1,2,3,4,5,6,7}',2),
  ('f2000000-0000-0000-0000-000000000001','bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb','B Truck',5,'{1,2,3,4,5,6,7}',1);

insert into public.customers (id, first_name, last_name, phone, email, street_address, city, state, zip_code) values
  ('c1000000-0000-0000-0000-000000000001','Ann','Able','555-0101','a@x.test','1 Main St','Denver','CO','80201'),
  ('c1000000-0000-0000-0000-000000000002','Ben','Baker','555-0102','b@x.test','2 Oak Ave','Denver','CO','80202'),
  ('c1000000-0000-0000-0000-000000000003','Cid','Cole','555-0103','c@x.test','3 Pine Rd','Aurora','CO','80010'),
  ('c1000000-0000-0000-0000-000000000004','Dee','Drew','555-0104','d@x.test','4 Elm St','Denver','CO','80204'),
  ('c1000000-0000-0000-0000-000000000005','Eli','Eve','555-0105','e@x.test','5 Ash Ave','Aurora','CO','80011'),
  ('c1000000-0000-0000-0000-000000000006','Fay','Fox','555-0106','f@x.test','6 Birch Rd','Denver','CO','80205'),
  ('c1000000-0000-0000-0000-000000000007','Gus','Gray','555-0107','g@x.test','7 Cedar Ln','Aurora','CO','80012'),
  ('c1000000-0000-0000-0000-000000000008','Hal','Hart','555-0108','h@x.test','8 Spruce Dr','Denver','CO','80206'),
  ('c2000000-0000-0000-0000-000000000001','Ivy','Ives','555-0201','i@x.test','9 Elm St','Boulder','CO','80301');

-- Eight Ready to Schedule delivery journeys in company A (J1-J8), one in B.
insert into public.sleep_journeys (id, customer_id, store_id, current_state, fulfillment_type, price, journey_number)
values
  ('d1000000-0000-0000-0000-0000000000a1','c1000000-0000-0000-0000-000000000001','a1000000-0000-0000-0000-000000000001','Ready to Schedule','delivery',1000,'SJ-AAA00001'),
  ('d1000000-0000-0000-0000-0000000000a2','c1000000-0000-0000-0000-000000000002','a1000000-0000-0000-0000-000000000001','Ready to Schedule','delivery',1000,'SJ-AAA00002'),
  ('d1000000-0000-0000-0000-0000000000a3','c1000000-0000-0000-0000-000000000003','a1000000-0000-0000-0000-000000000001','Ready to Schedule','delivery',1000,'SJ-AAA00003'),
  ('d1000000-0000-0000-0000-0000000000a4','c1000000-0000-0000-0000-000000000004','a1000000-0000-0000-0000-000000000001','Ready to Schedule','delivery',1000,'SJ-AAA00004'),
  ('d1000000-0000-0000-0000-0000000000a5','c1000000-0000-0000-0000-000000000005','a1000000-0000-0000-0000-000000000001','Ready to Schedule','delivery',1000,'SJ-AAA00005'),
  ('d1000000-0000-0000-0000-0000000000a6','c1000000-0000-0000-0000-000000000006','a1000000-0000-0000-0000-000000000001','Ready to Schedule','delivery',1000,'SJ-AAA00006'),
  ('d1000000-0000-0000-0000-0000000000a7','c1000000-0000-0000-0000-000000000007','a1000000-0000-0000-0000-000000000001','Ready to Schedule','delivery',1000,'SJ-AAA00007'),
  ('d1000000-0000-0000-0000-0000000000a8','c1000000-0000-0000-0000-000000000008','a1000000-0000-0000-0000-000000000001','Ready to Schedule','delivery',1000,'SJ-AAA00008');

insert into public.sleep_journeys (id, customer_id, store_id, current_state, fulfillment_type, price, journey_number)
values ('d2000000-0000-0000-0000-0000000000b1','c2000000-0000-0000-0000-000000000001',
        'b1000000-0000-0000-0000-000000000001','Ready to Schedule','delivery',500,'SJ-BBB00001');

-- Test dates in company business tz (5 and 10 days out).
select ((now() at time zone 'America/Denver')::date + 5)::text as testdate,
       ((now() at time zone 'America/Denver')::date + 10)::text as testdate2 \gset
\echo 'TEST DATE:' :testdate ' SECOND DATE:' :testdate2

-- Book four stops on the test date as owner.
set test.uid = '11111111-1111-1111-1111-111111111111';
select public.book_delivery_stop('d1000000-0000-0000-0000-0000000000a1', :'testdate'::date) as stop1 \gset
select public.book_delivery_stop('d1000000-0000-0000-0000-0000000000a2', :'testdate'::date) as stop2 \gset
select public.book_delivery_stop('d1000000-0000-0000-0000-0000000000a3', :'testdate'::date) as stop3 \gset
select public.book_delivery_stop('d1000000-0000-0000-0000-0000000000a4', :'testdate'::date) as stop4 \gset

\echo '=== T1: get_delivery_day_plan as owner ==='
select jsonb_pretty(public.get_delivery_day_plan(:'testdate'::date)->'plan') as plan,
       jsonb_array_length(public.get_delivery_day_plan(:'testdate'::date)->'stops') as stops,
       jsonb_array_length(public.get_delivery_day_plan(:'testdate'::date)->'trucks') as trucks,
       public.get_delivery_day_plan(:'testdate'::date)->>'capacity' as capacity,
       public.get_delivery_day_plan(:'testdate'::date)->>'booked_count' as booked
from (select 1) x;

\echo '=== T2: read allowed for sales without manage_calendar ==='
set test.uid = '22222222-2222-2222-2222-222222222222';
select jsonb_array_length(public.get_delivery_day_plan(:'testdate'::date)->'stops') as stops_visible_to_sales;

\echo '=== T3: writes rejected for sales (expect 3 permission ERRORs) ==='
select public.save_delivery_day_route(:'testdate'::date, 0, '[]'::jsonb);
select public.close_delivery_day(:'testdate'::date, 0);
select public.reopen_delivery_day(:'testdate'::date, 0);

\echo '=== T4: cross-company — B sees only own data, cannot write A stops ==='
set test.uid = '33333333-3333-3333-3333-333333333333';
select jsonb_array_length(public.get_delivery_day_plan(:'testdate'::date)->'stops') as b_sees_stops;
select public.save_delivery_day_route(:'testdate'::date, 0,
  jsonb_build_array(jsonb_build_object('stop_id', :'stop1', 'truck_id', null, 'route_position', null)));

\echo '=== T5: initial route save — all 4 stops on Truck 1 (v0 -> v1) ==='
set test.uid = '11111111-1111-1111-1111-111111111111';
select public.save_delivery_day_route(:'testdate'::date, 0,
  jsonb_build_array(
    jsonb_build_object('stop_id', :'stop1', 'truck_id', 'f1000000-0000-0000-0000-000000000001', 'route_position', 1),
    jsonb_build_object('stop_id', :'stop2', 'truck_id', 'f1000000-0000-0000-0000-000000000001', 'route_position', 2),
    jsonb_build_object('stop_id', :'stop3', 'truck_id', 'f1000000-0000-0000-0000-000000000001', 'route_position', 3),
    jsonb_build_object('stop_id', :'stop4', 'truck_id', 'f1000000-0000-0000-0000-000000000001', 'route_position', 4)
  )) as new_version;
select id, truck_id, route_position from public.delivery_stops where status='BOOKED' order by truck_id, route_position;
select action, from_truck_id, to_truck_id, from_position, to_position from public.delivery_route_events order by created_at;

\echo '=== T6: version conflict — stale expected_version 0 rejected ==='
select public.save_delivery_day_route(:'testdate'::date, 0, '[]'::jsonb);

\echo '=== T7: duplicate positions on one truck rejected ==='
select public.save_delivery_day_route(:'testdate'::date, 1,
  jsonb_build_array(
    jsonb_build_object('stop_id', :'stop1', 'truck_id', 'f1000000-0000-0000-0000-000000000001', 'route_position', 1),
    jsonb_build_object('stop_id', :'stop2', 'truck_id', 'f1000000-0000-0000-0000-000000000001', 'route_position', 1)
  ));

\echo '=== T8: reorder with gaps — submitted positions 1,3,5 renumber to 1,2,3 (v1 -> v2) ==='
select public.save_delivery_day_route(:'testdate'::date, 1,
  jsonb_build_array(
    jsonb_build_object('stop_id', :'stop1', 'truck_id', 'f1000000-0000-0000-0000-000000000001', 'route_position', 1),
    jsonb_build_object('stop_id', :'stop2', 'truck_id', 'f1000000-0000-0000-0000-000000000001', 'route_position', 3),
    jsonb_build_object('stop_id', :'stop3', 'truck_id', 'f1000000-0000-0000-0000-000000000001', 'route_position', 5),
    jsonb_build_object('stop_id', :'stop4', 'truck_id', 'f1000000-0000-0000-0000-000000000002', 'route_position', 1)
  )) as v_gaps;
select id, truck_id, route_position from public.delivery_stops where status='BOOKED' order by truck_id, route_position;

\echo '=== T9: swap two stops on one truck — stop1 takes pos2, stop2 takes pos1 (v2 -> v3) ==='
select public.save_delivery_day_route(:'testdate'::date, 2,
  jsonb_build_array(
    jsonb_build_object('stop_id', :'stop1', 'truck_id', 'f1000000-0000-0000-0000-000000000001', 'route_position', 2),
    jsonb_build_object('stop_id', :'stop2', 'truck_id', 'f1000000-0000-0000-0000-000000000001', 'route_position', 1),
    jsonb_build_object('stop_id', :'stop3', 'truck_id', 'f1000000-0000-0000-0000-000000000001', 'route_position', 3),
    jsonb_build_object('stop_id', :'stop4', 'truck_id', 'f1000000-0000-0000-0000-000000000002', 'route_position', 1)
  )) as v_swap;
select ds.id, ds.route_position, cu.first_name from public.delivery_stops ds
join public.sleep_journeys sj on sj.id=ds.journey_id
join public.customers cu on cu.id=sj.customer_id
where ds.status='BOOKED' and ds.truck_id='f1000000-0000-0000-0000-000000000001' order by ds.route_position;

\echo '=== T10: move bottom stop to top of Truck 1 (v3 -> v4) ==='
select public.save_delivery_day_route(:'testdate'::date, 3,
  jsonb_build_array(
    jsonb_build_object('stop_id', :'stop1', 'truck_id', 'f1000000-0000-0000-0000-000000000001', 'route_position', 2),
    jsonb_build_object('stop_id', :'stop2', 'truck_id', 'f1000000-0000-0000-0000-000000000001', 'route_position', 3),
    jsonb_build_object('stop_id', :'stop3', 'truck_id', 'f1000000-0000-0000-0000-000000000001', 'route_position', 1),
    jsonb_build_object('stop_id', :'stop4', 'truck_id', 'f1000000-0000-0000-0000-000000000002', 'route_position', 1)
  )) as v_bottom_top;
select ds.id, ds.route_position, cu.first_name from public.delivery_stops ds
join public.sleep_journeys sj on sj.id=ds.journey_id
join public.customers cu on cu.id=sj.customer_id
where ds.status='BOOKED' and ds.truck_id='f1000000-0000-0000-0000-000000000001' order by ds.route_position;

\echo '=== T11: all four on Truck 1, then full reverse 4-3-2-1 (v4 -> v6) ==='
select public.save_delivery_day_route(:'testdate'::date, 4,
  jsonb_build_array(
    jsonb_build_object('stop_id', :'stop1', 'truck_id', 'f1000000-0000-0000-0000-000000000001', 'route_position', 1),
    jsonb_build_object('stop_id', :'stop2', 'truck_id', 'f1000000-0000-0000-0000-000000000001', 'route_position', 2),
    jsonb_build_object('stop_id', :'stop3', 'truck_id', 'f1000000-0000-0000-0000-000000000001', 'route_position', 3),
    jsonb_build_object('stop_id', :'stop4', 'truck_id', 'f1000000-0000-0000-0000-000000000001', 'route_position', 4)
  )) as v_all_on_t1;
select public.save_delivery_day_route(:'testdate'::date, 5,
  jsonb_build_array(
    jsonb_build_object('stop_id', :'stop1', 'truck_id', 'f1000000-0000-0000-0000-000000000001', 'route_position', 4),
    jsonb_build_object('stop_id', :'stop2', 'truck_id', 'f1000000-0000-0000-0000-000000000001', 'route_position', 3),
    jsonb_build_object('stop_id', :'stop3', 'truck_id', 'f1000000-0000-0000-0000-000000000001', 'route_position', 2),
    jsonb_build_object('stop_id', :'stop4', 'truck_id', 'f1000000-0000-0000-0000-000000000001', 'route_position', 1)
  )) as v_reverse;
select ds.id, ds.route_position, cu.first_name from public.delivery_stops ds
join public.sleep_journeys sj on sj.id=ds.journey_id
join public.customers cu on cu.id=sj.customer_id
where ds.status='BOOKED' order by ds.route_position;

\echo '=== T12: move a stop to another truck into an occupied position (v6 -> v8) ==='
select public.save_delivery_day_route(:'testdate'::date, 6,
  jsonb_build_array(
    jsonb_build_object('stop_id', :'stop1', 'truck_id', 'f1000000-0000-0000-0000-000000000001', 'route_position', 1),
    jsonb_build_object('stop_id', :'stop2', 'truck_id', 'f1000000-0000-0000-0000-000000000001', 'route_position', 2),
    jsonb_build_object('stop_id', :'stop3', 'truck_id', 'f1000000-0000-0000-0000-000000000001', 'route_position', 3),
    jsonb_build_object('stop_id', :'stop4', 'truck_id', 'f1000000-0000-0000-0000-000000000002', 'route_position', 1)
  )) as v_t2_first;
-- stop1 moves to Truck 2 pos 1 (already occupied by stop4) -> renumber.
select public.save_delivery_day_route(:'testdate'::date, 7,
  jsonb_build_array(
    jsonb_build_object('stop_id', :'stop1', 'truck_id', 'f1000000-0000-0000-0000-000000000002', 'route_position', 1),
    jsonb_build_object('stop_id', :'stop2', 'truck_id', 'f1000000-0000-0000-0000-000000000001', 'route_position', 1),
    jsonb_build_object('stop_id', :'stop3', 'truck_id', 'f1000000-0000-0000-0000-000000000001', 'route_position', 2),
    jsonb_build_object('stop_id', :'stop4', 'truck_id', 'f1000000-0000-0000-0000-000000000002', 'route_position', 2)
  )) as v_move_occupied;
select ds.id, ds.truck_id, ds.route_position, cu.first_name from public.delivery_stops ds
join public.sleep_journeys sj on sj.id=ds.journey_id
join public.customers cu on cu.id=sj.customer_id
where ds.status='BOOKED' order by ds.truck_id, ds.route_position;

\echo '=== T13: past date writes rejected (expect 3 ERRORs) ==='
select public.save_delivery_day_route(((now() at time zone 'America/Denver')::date - 1), 0, '[]'::jsonb);
select public.close_delivery_day(((now() at time zone 'America/Denver')::date - 1), 0);
select public.reopen_delivery_day(((now() at time zone 'America/Denver')::date - 1), 0);

\echo '=== T14: stale payload — release stop4, then save listing it (expect ERROR) ==='
update public.delivery_stops set status='CANCELLED', cancelled_at=now(), cancel_reason='test release' where id=:'stop4';
select public.save_delivery_day_route(:'testdate'::date, 8,
  jsonb_build_array(
    jsonb_build_object('stop_id', :'stop1', 'truck_id', 'f1000000-0000-0000-0000-000000000002', 'route_position', 1),
    jsonb_build_object('stop_id', :'stop2', 'truck_id', 'f1000000-0000-0000-0000-000000000001', 'route_position', 1),
    jsonb_build_object('stop_id', :'stop3', 'truck_id', 'f1000000-0000-0000-0000-000000000001', 'route_position', 2),
    jsonb_build_object('stop_id', :'stop4', 'truck_id', 'f1000000-0000-0000-0000-000000000002', 'route_position', 2)
  ));

\echo '=== T15: close the day, double-close rejected, save-on-closed rejected ==='
select public.close_delivery_day(:'testdate'::date, 8) as closed_version;
select public.close_delivery_day(:'testdate'::date, 9);
select public.save_delivery_day_route(:'testdate'::date, 9, '[]'::jsonb);

\echo '=== T16: booking into CLOSED day still works, arrives unrouted ==='
select public.book_delivery_stop('d1000000-0000-0000-0000-0000000000a5', :'testdate'::date) as late_stop \gset
select id, status, truck_id, route_position from public.delivery_stops where id=:'late_stop';

\echo '=== T17: reopen keeps assignments, then save works again ==='
select public.reopen_delivery_day(:'testdate'::date, 9) as reopened_version;
select id, truck_id, route_position from public.delivery_stops where status='BOOKED' order by truck_id nulls last, route_position;
select action from public.delivery_route_events where action in ('PLAN_CLOSED','PLAN_REOPENED') order by created_at;
-- Book two more stops (J6, J7) now that stop4 freed capacity, route them on Truck 2.
select public.book_delivery_stop('d1000000-0000-0000-0000-0000000000a6', :'testdate'::date) as stop6 \gset
select public.book_delivery_stop('d1000000-0000-0000-0000-0000000000a7', :'testdate'::date) as stop7 \gset
select public.save_delivery_day_route(:'testdate'::date, 10,
  jsonb_build_array(
    jsonb_build_object('stop_id', :'stop1', 'truck_id', 'f1000000-0000-0000-0000-000000000002', 'route_position', 1),
    jsonb_build_object('stop_id', :'stop2', 'truck_id', 'f1000000-0000-0000-0000-000000000001', 'route_position', 1),
    jsonb_build_object('stop_id', :'stop3', 'truck_id', 'f1000000-0000-0000-0000-000000000001', 'route_position', 2),
    jsonb_build_object('stop_id', :'late_stop', 'truck_id', 'f1000000-0000-0000-0000-000000000002', 'route_position', 2),
    jsonb_build_object('stop_id', :'stop6', 'truck_id', 'f1000000-0000-0000-0000-000000000002', 'route_position', 3),
    jsonb_build_object('stop_id', :'stop7', 'truck_id', 'f1000000-0000-0000-0000-000000000002', 'route_position', 4)
  )) as v_after_reopen;

\echo '=== T18: released routed stop frees truck+position for a new BOOKED stop ==='
select public.cancel_delivery_stop(:'stop1', 'test cancel');
select public.book_delivery_stop('d1000000-0000-0000-0000-0000000000a8', :'testdate'::date) as stop8 \gset
select (public.get_delivery_day_plan(:'testdate'::date)->'plan'->>'version')::int as v_now \gset
select public.save_delivery_day_route(:'testdate'::date, :v_now::int,
  jsonb_build_array(
    jsonb_build_object('stop_id', :'stop2', 'truck_id', 'f1000000-0000-0000-0000-000000000001', 'route_position', 1),
    jsonb_build_object('stop_id', :'stop3', 'truck_id', 'f1000000-0000-0000-0000-000000000001', 'route_position', 2),
    jsonb_build_object('stop_id', :'late_stop', 'truck_id', 'f1000000-0000-0000-0000-000000000002', 'route_position', 1),
    jsonb_build_object('stop_id', :'stop6', 'truck_id', 'f1000000-0000-0000-0000-000000000002', 'route_position', 2),
    jsonb_build_object('stop_id', :'stop7', 'truck_id', 'f1000000-0000-0000-0000-000000000002', 'route_position', 3),
    jsonb_build_object('stop_id', :'stop8', 'truck_id', 'f1000000-0000-0000-0000-000000000002', 'route_position', 4)
  )) as v_reuse;
select id, status, truck_id, route_position from public.delivery_stops
where delivery_date=:'testdate'::date order by status, truck_id nulls last, route_position;

\echo '=== T19: derive_journey_state releases a routed stop on a CLOSED day ==='
select (public.get_delivery_day_plan(:'testdate'::date)->'plan'->>'version')::int as v_pre_close \gset
select public.close_delivery_day(:'testdate'::date, :v_pre_close::int) as v \gset
-- Release stop7 via a real journey event (Scheduled -> Waiting for Inventory).
insert into public.journey_events (journey_id, event_type, event_data, triggered_by)
select journey_id, 'inventory_required', '{"item_name":"Test"}', 'system'
from public.delivery_stops where id=:'stop7';
select ds.id, ds.status, ds.truck_id, ds.route_position, ds.cancel_reason
from public.delivery_stops ds where ds.id=:'stop7';
select jsonb_pretty(public.get_delivery_day_plan(:'testdate'::date)->'released_after_review') as released;

\echo '=== T20: reschedule a routed stop to another day -> released_after_review moved ==='
select public.reschedule_delivery_stop(:'stop6', :'testdate2'::date) as moved_stop \gset
select jsonb_pretty(public.get_delivery_day_plan(:'testdate'::date)->'released_after_review') as released_after_move;

\echo '=== T21: immutable route log (expect 2 ERRORs) ==='
update public.delivery_route_events set action='UNROUTED' where id=(select id from public.delivery_route_events limit 1);
delete from public.delivery_route_events where id=(select id from public.delivery_route_events limit 1);

\echo '=== T22: execute privileges ==='
select p.proname,
       has_function_privilege('anon', p.oid, 'EXECUTE') as anon_exec,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') as auth_exec
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname in
  ('get_delivery_day_plan','save_delivery_day_route','close_delivery_day',
   'reopen_delivery_day','suggest_delivery_assignments','delivery_company_today',
   'delivery_caller_employee_id','delivery_assert_day_writable')
order by p.proname;

\echo '=== T23: suggest_delivery_assignments ==='
select jsonb_pretty(public.suggest_delivery_assignments(:'testdate'::date));
