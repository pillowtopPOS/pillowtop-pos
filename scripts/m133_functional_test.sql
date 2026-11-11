-- m133 FUNCTIONAL TEST — MUTATES DATA.
-- For a THROWAWAY database only. Never run against Supabase or real data.
--
-- Verifies the route-position index is unique per (truck, DATE), not per
-- truck globally: Truck 1 position 1 may be used on two different days,
-- while two stops at the same position on the same truck/day are rejected.
--
-- Requires the same auth shim as m132_functional_test.sql (see its header).

\set ON_ERROR_STOP off
\pset footer off

-- ============================ SEED ============================
insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111','mgr@a.test');

insert into public.companies (id, name, business_timezone) values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','Company A','America/Denver');

insert into public.stores (id, company_id, name, store_code, timezone, is_active) values
  ('a1000000-0000-0000-0000-000000000001','aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','A Store','AAA','America/Denver',true);

insert into public.employees (id, auth_user_id, home_store_id, role, first_name, last_name, is_active) values
  ('e1000000-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','a1000000-0000-0000-0000-000000000001','owner','Amy','Owner',true);

insert into public.delivery_trucks (id, company_id, name, default_stop_cap, weekly_pattern, sort_order) values
  ('f1000000-0000-0000-0000-000000000001','aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','Truck 1',5,'{1,2,3,4,5,6,7}',1);

insert into public.customers (id, first_name, last_name, phone, email, street_address, city, state, zip_code) values
  ('c1000000-0000-0000-0000-000000000001','Ann','Able','555-0101','a@x.test','1 Main St','Denver','CO','80201'),
  ('c1000000-0000-0000-0000-000000000002','Ben','Baker','555-0102','b@x.test','2 Oak Ave','Denver','CO','80202'),
  ('c1000000-0000-0000-0000-000000000003','Cid','Cole','555-0103','c@x.test','3 Pine Rd','Aurora','CO','80010');

insert into public.sleep_journeys (id, customer_id, store_id, current_state, fulfillment_type, price, journey_number)
values
  ('d1000000-0000-0000-0000-0000000000a1','c1000000-0000-0000-0000-000000000001','a1000000-0000-0000-0000-000000000001','Ready to Schedule','delivery',1000,'SJ-AAA00001'),
  ('d1000000-0000-0000-0000-0000000000a2','c1000000-0000-0000-0000-000000000002','a1000000-0000-0000-0000-000000000001','Ready to Schedule','delivery',1000,'SJ-AAA00002'),
  ('d1000000-0000-0000-0000-0000000000a3','c1000000-0000-0000-0000-000000000003','a1000000-0000-0000-0000-000000000001','Ready to Schedule','delivery',1000,'SJ-AAA00003');

select ((now() at time zone 'America/Denver')::date + 5)::text as day1,
       ((now() at time zone 'America/Denver')::date + 6)::text as day2 \gset
\echo 'DAY1:' :day1 ' DAY2:' :day2

set test.uid = '11111111-1111-1111-1111-111111111111';
select public.book_delivery_stop('d1000000-0000-0000-0000-0000000000a1', :'day1'::date) as s1_day1 \gset
select public.book_delivery_stop('d1000000-0000-0000-0000-0000000000a2', :'day1'::date) as s2_day1 \gset
select public.book_delivery_stop('d1000000-0000-0000-0000-0000000000a3', :'day2'::date) as s1_day2 \gset

\echo '=== T1: Truck 1 position 1 on day1 ==='
select public.save_delivery_day_route(:'day1'::date, 0,
  jsonb_build_array(
    jsonb_build_object('stop_id', :'s1_day1', 'truck_id', 'f1000000-0000-0000-0000-000000000001', 'route_position', 1),
    jsonb_build_object('stop_id', :'s2_day1', 'truck_id', null, 'route_position', null)
  )) as v_day1;

\echo '=== T2: Truck 1 position 1 on day2 — must SUCCEED (was the m132 bug) ==='
select public.save_delivery_day_route(:'day2'::date, 0,
  jsonb_build_array(
    jsonb_build_object('stop_id', :'s1_day2', 'truck_id', 'f1000000-0000-0000-0000-000000000001', 'route_position', 1)
  )) as v_day2;

select id, delivery_date, truck_id, route_position from public.delivery_stops
where status='BOOKED' order by delivery_date, route_position;

\echo '=== T3: two stops same position on one truck same day — still rejected ==='
select public.save_delivery_day_route(:'day1'::date, 1,
  jsonb_build_array(
    jsonb_build_object('stop_id', :'s1_day1', 'truck_id', 'f1000000-0000-0000-0000-000000000001', 'route_position', 1),
    jsonb_build_object('stop_id', :'s2_day1', 'truck_id', 'f1000000-0000-0000-0000-000000000001', 'route_position', 1)
  ));

\echo '=== T4: sanity — same truck different positions same day works ==='
select public.save_delivery_day_route(:'day1'::date, 1,
  jsonb_build_array(
    jsonb_build_object('stop_id', :'s1_day1', 'truck_id', 'f1000000-0000-0000-0000-000000000001', 'route_position', 1),
    jsonb_build_object('stop_id', :'s2_day1', 'truck_id', 'f1000000-0000-0000-0000-000000000001', 'route_position', 2)
  )) as v_day1_final;
