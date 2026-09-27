-- ============================================================
-- PillowTop POS: Seed Sleep Trial test journeys
-- Run in the Supabase SQL editor. Safe to run twice.
-- ============================================================
--
-- Creates four TEST journeys at the Main Street store, all in
-- "Sleep Trial" state, covering the trial-status display matrix:
--
--   TEST Trial A — delivered 107d ago, 120/115 snapshot
--                  -> Not Yet Eligible + ending soon (13 left)
--   TEST Trial B — delivered 107d ago, 120/60 snapshot
--                  -> Exchange Eligible + ending soon
--   TEST Trial C — delivered  30d ago, 120/60 snapshot
--                  -> Not Yet Eligible, not ending soon
--                  (use for early exchange exception tests)
--   TEST Trial D — delivered  80d ago, 120/60 snapshot
--                  -> Exchange Eligible, not ending soon
--
-- (Ending-soon expectations assume the store's
--  trial_ending_warning_days is the default 14.)
--
-- DESIGN NOTES
--
-- * Real path for state: current_state is derived by the
--   derive_journey_state trigger on journey_events, and delivered_at
--   is stamped by the set_journey_delivered_at trigger from the
--   delivery_completed event's event_data. The seed inserts the real
--   event chain (quote_created -> payment_completed SUCCEEDED ->
--   delivery_scheduled -> delivery_completed) and lets those triggers
--   do their normal work rather than writing current_state/delivered_at
--   directly.
--
-- * The delivered_at floor check requires journey.created_at::date - 1
--   <= delivered_at, so journeys and events are backdated consistently
--   (journey created 3 days before delivery).
--
-- * Snapshot columns are set explicitly on the journey INSERT. The
--   delivered_at trigger fills them via coalesce(..., store value),
--   so pre-set values are preserved.
--
-- * Payments are journey_events with outcome='SUCCEEDED' and
--   event_data.amount — there is no payments table. One full-price
--   payment_completed per journey keeps balance due at zero.
--
-- * Automation note: processAutomaticTransitions() would pick these
--   up only once delivered_at + trial_length_nights <= now(). None of
--   the four are expired today (nearest is Trial A at +13 days), so
--   nothing fires now — but if left long enough the automation WILL
--   insert trial_completed and move them to Completed. That is real
--   behavior, not a bug.
--
-- * No written_sales rows are created: real payments go through the
--   record_payment_event RPC, which also calls
--   ensure_written_sale_established. The seed bypasses that, so these
--   journeys will not appear in written-sales reporting. (Payments
--   recorded through the UI during testing WILL create written_sales
--   rows — the cleanup script removes them.)

do $$
declare
  v_store uuid;
  v_emp   uuid;
  v_cust  uuid;
  v_j     uuid;
begin
  -- Main Street store + an active employee there
  select id into v_store
  from public.stores
  where name ilike '%main street%'
  order by case when location_type = 'STORE' then 0 else 1 end, created_at
  limit 1;

  if v_store is null then
    raise exception 'Seed aborted: no store matching "main street" found';
  end if;

  select id into v_emp
  from public.employees
  where home_store_id = v_store and is_active
  order by created_at
  limit 1;

  if v_emp is null then
    raise exception 'Seed aborted: no active employee at the Main Street store';
  end if;

  -- ----------------------------------------------------------
  -- TEST Trial A: 120/115, delivered 107d -> NE + ending soon
  -- ----------------------------------------------------------
  insert into public.customers (first_name, last_name, phone, email,
    street_address, city, state, zip_code)
  select 'TEST', 'Trial A', '555-0100', 'test.trial.a@example.com',
    '100 Test Lane', 'Westminster', 'CO', '80031'
  where not exists (
    select 1 from public.customers
    where first_name = 'TEST' and last_name = 'Trial A'
  );
  select id into v_cust from public.customers
  where first_name = 'TEST' and last_name = 'Trial A';

  if not exists (select 1 from public.sleep_journeys where customer_id = v_cust) then
    insert into public.sleep_journeys (
      customer_id, store_id, assigned_employee_id,
      product_summary, price,
      trial_length_nights, minimum_adjustment_nights, trial_policy_snapshot,
      created_at, updated_at
    ) values (
      v_cust, v_store, v_emp,
      'TEST — PillowSoft Queen Hybrid', 1499.00,
      120, 115,
      jsonb_build_object(
        'captured_at', (current_date - 107)::timestamptz,
        'trial_length_nights', 120,
        'minimum_adjustment_nights', 115,
        'source', 'seed_sleep_trial_test_journeys'
      ),
      (current_date - 110)::timestamptz,
      (current_date - 110)::timestamptz
    )
    returning id into v_j;

    insert into public.journey_events (journey_id, event_type, outcome, event_data, triggered_by, created_at) values
      (v_j, 'quote_created', null,
        jsonb_build_object('amount', 1499.00), 'seed', (current_date - 110)::timestamptz),
      (v_j, 'payment_completed', 'SUCCEEDED',
        jsonb_build_object('amount', 1499.00, 'payment_method', 'TEST seed payment'), 'seed', (current_date - 110)::timestamptz),
      (v_j, 'delivery_scheduled', null,
        jsonb_build_object('delivery_date', (current_date - 107)::text), 'seed', (current_date - 108)::timestamptz),
      (v_j, 'delivery_completed', null,
        jsonb_build_object('delivered_at', (current_date - 107)::text), 'seed', (current_date - 107)::timestamptz);
  end if;

  -- ----------------------------------------------------------
  -- TEST Trial B: 120/60, delivered 107d -> Eligible + ending soon
  -- ----------------------------------------------------------
  insert into public.customers (first_name, last_name, phone, email,
    street_address, city, state, zip_code)
  select 'TEST', 'Trial B', '555-0101', 'test.trial.b@example.com',
    '101 Test Lane', 'Westminster', 'CO', '80031'
  where not exists (
    select 1 from public.customers
    where first_name = 'TEST' and last_name = 'Trial B'
  );
  select id into v_cust from public.customers
  where first_name = 'TEST' and last_name = 'Trial B';

  if not exists (select 1 from public.sleep_journeys where customer_id = v_cust) then
    insert into public.sleep_journeys (
      customer_id, store_id, assigned_employee_id,
      product_summary, price,
      trial_length_nights, minimum_adjustment_nights, trial_policy_snapshot,
      created_at, updated_at
    ) values (
      v_cust, v_store, v_emp,
      'TEST — PillowSoft Queen Hybrid', 1499.00,
      120, 60,
      jsonb_build_object(
        'captured_at', (current_date - 107)::timestamptz,
        'trial_length_nights', 120,
        'minimum_adjustment_nights', 60,
        'source', 'seed_sleep_trial_test_journeys'
      ),
      (current_date - 110)::timestamptz,
      (current_date - 110)::timestamptz
    )
    returning id into v_j;

    insert into public.journey_events (journey_id, event_type, outcome, event_data, triggered_by, created_at) values
      (v_j, 'quote_created', null,
        jsonb_build_object('amount', 1499.00), 'seed', (current_date - 110)::timestamptz),
      (v_j, 'payment_completed', 'SUCCEEDED',
        jsonb_build_object('amount', 1499.00, 'payment_method', 'TEST seed payment'), 'seed', (current_date - 110)::timestamptz),
      (v_j, 'delivery_scheduled', null,
        jsonb_build_object('delivery_date', (current_date - 107)::text), 'seed', (current_date - 108)::timestamptz),
      (v_j, 'delivery_completed', null,
        jsonb_build_object('delivered_at', (current_date - 107)::text), 'seed', (current_date - 107)::timestamptz);
  end if;

  -- ----------------------------------------------------------
  -- TEST Trial C: 120/60, delivered 30d -> NE, not ending soon
  -- ----------------------------------------------------------
  insert into public.customers (first_name, last_name, phone, email,
    street_address, city, state, zip_code)
  select 'TEST', 'Trial C', '555-0102', 'test.trial.c@example.com',
    '102 Test Lane', 'Westminster', 'CO', '80031'
  where not exists (
    select 1 from public.customers
    where first_name = 'TEST' and last_name = 'Trial C'
  );
  select id into v_cust from public.customers
  where first_name = 'TEST' and last_name = 'Trial C';

  if not exists (select 1 from public.sleep_journeys where customer_id = v_cust) then
    insert into public.sleep_journeys (
      customer_id, store_id, assigned_employee_id,
      product_summary, price,
      trial_length_nights, minimum_adjustment_nights, trial_policy_snapshot,
      created_at, updated_at
    ) values (
      v_cust, v_store, v_emp,
      'TEST — PillowSoft Queen Hybrid', 1499.00,
      120, 60,
      jsonb_build_object(
        'captured_at', (current_date - 30)::timestamptz,
        'trial_length_nights', 120,
        'minimum_adjustment_nights', 60,
        'source', 'seed_sleep_trial_test_journeys'
      ),
      (current_date - 33)::timestamptz,
      (current_date - 33)::timestamptz
    )
    returning id into v_j;

    insert into public.journey_events (journey_id, event_type, outcome, event_data, triggered_by, created_at) values
      (v_j, 'quote_created', null,
        jsonb_build_object('amount', 1499.00), 'seed', (current_date - 33)::timestamptz),
      (v_j, 'payment_completed', 'SUCCEEDED',
        jsonb_build_object('amount', 1499.00, 'payment_method', 'TEST seed payment'), 'seed', (current_date - 33)::timestamptz),
      (v_j, 'delivery_scheduled', null,
        jsonb_build_object('delivery_date', (current_date - 30)::text), 'seed', (current_date - 31)::timestamptz),
      (v_j, 'delivery_completed', null,
        jsonb_build_object('delivered_at', (current_date - 30)::text), 'seed', (current_date - 30)::timestamptz);
  end if;

  -- ----------------------------------------------------------
  -- TEST Trial D: 120/60, delivered 80d -> Eligible, not ending soon
  -- ----------------------------------------------------------
  insert into public.customers (first_name, last_name, phone, email,
    street_address, city, state, zip_code)
  select 'TEST', 'Trial D', '555-0103', 'test.trial.d@example.com',
    '103 Test Lane', 'Westminster', 'CO', '80031'
  where not exists (
    select 1 from public.customers
    where first_name = 'TEST' and last_name = 'Trial D'
  );
  select id into v_cust from public.customers
  where first_name = 'TEST' and last_name = 'Trial D';

  if not exists (select 1 from public.sleep_journeys where customer_id = v_cust) then
    insert into public.sleep_journeys (
      customer_id, store_id, assigned_employee_id,
      product_summary, price,
      trial_length_nights, minimum_adjustment_nights, trial_policy_snapshot,
      created_at, updated_at
    ) values (
      v_cust, v_store, v_emp,
      'TEST — PillowSoft Queen Hybrid', 1499.00,
      120, 60,
      jsonb_build_object(
        'captured_at', (current_date - 80)::timestamptz,
        'trial_length_nights', 120,
        'minimum_adjustment_nights', 60,
        'source', 'seed_sleep_trial_test_journeys'
      ),
      (current_date - 83)::timestamptz,
      (current_date - 83)::timestamptz
    )
    returning id into v_j;

    insert into public.journey_events (journey_id, event_type, outcome, event_data, triggered_by, created_at) values
      (v_j, 'quote_created', null,
        jsonb_build_object('amount', 1499.00), 'seed', (current_date - 83)::timestamptz),
      (v_j, 'payment_completed', 'SUCCEEDED',
        jsonb_build_object('amount', 1499.00, 'payment_method', 'TEST seed payment'), 'seed', (current_date - 83)::timestamptz),
      (v_j, 'delivery_scheduled', null,
        jsonb_build_object('delivery_date', (current_date - 80)::text), 'seed', (current_date - 81)::timestamptz),
      (v_j, 'delivery_completed', null,
        jsonb_build_object('delivered_at', (current_date - 80)::text), 'seed', (current_date - 80)::timestamptz);
  end if;
end;
$$;

-- Verification: each test journey with its trial snapshot and the
-- trigger-derived state/delivered_at.
select
  c.first_name || ' ' || c.last_name as customer,
  sj.current_state,
  sj.delivered_at,
  sj.trial_length_nights,
  sj.minimum_adjustment_nights,
  (current_date - sj.delivered_at) as nights_in_trial,
  (sj.trial_length_nights - (current_date - sj.delivered_at)) as nights_remaining,
  sj.price,
  s.name as store,
  e.name as employee
from public.sleep_journeys sj
join public.customers c on c.id = sj.customer_id
join public.stores s on s.id = sj.store_id
left join public.employees e on e.id = sj.assigned_employee_id
where c.first_name = 'TEST' and c.last_name like 'Trial %'
order by c.last_name;
