-- ============================================================================
-- eb-4a verify: migration 099
-- VERIFIED Oct 29 in Supabase: 18/18 passed. This file includes the four
-- corrections that run needed: business_timezone on companies, generated
-- name on employees (insert first_name/last_name), no company_id on
-- sleep_journeys, and a full customer address (Delivery default, rule 036). (receive_returned_unit, void_returned_receipt,
-- create_quarantine_area). Run each block ONE AT A TIME in the Supabase SQL
-- editor. Every block ends in ONE select; results land in public.eb4a_results.
--
-- Impersonation: set_config('request.jwt.claim.sub', '<auth.users.id>', true)
-- makes auth.uid() return that user for the transaction.
--
-- Fixture ids: eb4a0000-0000-4000-8000-00000000xxNN.
--   company      ...0001 | warehouse ...0002 | store ...0003
--   employees    Ada owner/store ...0004 | Wally employee/warehouse ...0005
--                Ned employee/store ...0006
--   other co     ...c001 | other store ...c002 | Oscar owner ...c003
--   customer     ...0007 | product ...0008
--   journey      ...0009 | child journey ...0011
--   trial items  ...0tNN | actions ...00NN (one trial item per action:
--                sleep_trial_actions_one_open_per_item allows ONE open
--                action per trial_item_id, 087:336)
-- ============================================================================

-- OPTIONAL PRECHECK (not required): confirm auth.users NOT NULL columns in
-- this project before running the fixture.
--   select column_name, is_nullable, column_default
--   from information_schema.columns
--   where table_schema = 'auth' and table_name = 'users'
--     and is_nullable = 'NO' order by ordinal_position;

-- ---------------------------------------------------------------------------
-- 0. RESULTS TABLE + FIXTURE
-- ---------------------------------------------------------------------------

create table if not exists public.eb4a_results (
  id serial primary key,
  test_name text,
  expected text,
  actual text,
  passed boolean
);
truncate public.eb4a_results;

insert into public.companies (id, name, business_timezone) values
  ('eb4a0000-0000-4000-8000-000000000001', 'EB4A Verify Co', 'America/Chicago'),
  ('eb4a0000-0000-4000-8000-00000000c001', 'EB4A Other Co', 'America/Chicago')
on conflict (id) do nothing;

insert into public.stores (id, company_id, name, location_type, is_active) values
  ('eb4a0000-0000-4000-8000-000000000002', 'eb4a0000-0000-4000-8000-000000000001', 'EB4A Warehouse', 'WAREHOUSE', true),
  ('eb4a0000-0000-4000-8000-000000000003', 'eb4a0000-0000-4000-8000-000000000001', 'EB4A Store', 'STORE', true),
  ('eb4a0000-0000-4000-8000-00000000c002', 'eb4a0000-0000-4000-8000-00000000c001', 'EB4A Other Store', 'STORE', true)
on conflict (id) do nothing;

-- auth.users rows are required: employees.auth_user_id is an FK to auth.users.
-- Columns used: id, instance_id, aud, role, email, encrypted_password,
-- email_confirmed_at, created_at, updated_at (the NOT NULL set on stock
-- Supabase; if this project requires more, the precheck above lists them).
insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at
) values
  ('eb4a0000-0000-4000-8000-00000000a004', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'eb4a-ada@example.com', '', now(), now(), now()),
  ('eb4a0000-0000-4000-8000-00000000a005', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'eb4a-wally@example.com', '', now(), now(), now()),
  ('eb4a0000-0000-4000-8000-00000000a006', '00000000-0000-4000-8000-000000000000', 'authenticated', 'authenticated', 'eb4a-ned@example.com', '', now(), now(), now()),
  ('eb4a0000-0000-4000-8000-00000000ac03', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'eb4a-oscar@example.com', '', now(), now(), now())
on conflict (id) do nothing;

-- employees: no company_id column; company comes via home_store_id -> stores.
-- role is the employee_role enum: owner | admin | employee.
insert into public.employees (id, auth_user_id, home_store_id, first_name, last_name, role, is_active) values
  ('eb4a0000-0000-4000-8000-000000000004', 'eb4a0000-0000-4000-8000-00000000a004', 'eb4a0000-0000-4000-8000-000000000003', 'Ada', 'Exchange', 'owner', true),
  ('eb4a0000-0000-4000-8000-000000000005', 'eb4a0000-0000-4000-8000-00000000a005', 'eb4a0000-0000-4000-8000-000000000002', 'Wally', 'Warehouse', 'employee', true),
  ('eb4a0000-0000-4000-8000-000000000006', 'eb4a0000-0000-4000-8000-00000000a006', 'eb4a0000-0000-4000-8000-000000000003', 'Ned', 'Norights', 'employee', true),
  ('eb4a0000-0000-4000-8000-00000000c003', 'eb4a0000-0000-4000-8000-00000000ac03', 'eb4a0000-0000-4000-8000-00000000c002', 'Oscar', 'Other', 'owner', true)
on conflict (id) do nothing;

-- The grants seed trigger (066:270-275) gives sleep_trial.start_exchange and
-- sleep_trial.complete_exchange to EVERY role including 'employee'. Strip them
-- for the fixture company so Ned (a plain employee) is really refused.
delete from public.role_permission_grants
where company_id = 'eb4a0000-0000-4000-8000-000000000001'
  and role = 'employee'
  and permission_key in ('sleep_trial.start_exchange', 'sleep_trial.complete_exchange');

insert into public.role_permission_grants (company_id, role, permission_key) values
  ('eb4a0000-0000-4000-8000-000000000001', 'owner', 'sleep_trial.start_exchange'),
  ('eb4a0000-0000-4000-8000-000000000001', 'owner', 'sleep_trial.complete_exchange')
on conflict do nothing;

-- customers: no company_id; required first_name, last_name, phone, email.
insert into public.customers (id, first_name, last_name, phone, email, street_address, city, state, zip_code) values
  ('eb4a0000-0000-4000-8000-000000000007', 'Carl', 'Customer', '555-0101', 'eb4a-carl@example.com', '1 Main St', 'Dallas', 'TX', '75201')
on conflict (id) do nothing;

insert into public.products (id, company_id, sku, item_name, price) values
  ('eb4a0000-0000-4000-8000-000000000008', 'eb4a0000-0000-4000-8000-000000000001', 'EB4A-MATT', 'EB4A Mattress', 999.00)
on conflict (id) do nothing;

insert into public.sleep_journeys (id, store_id, customer_id, current_state, sale_kind) values
  ('eb4a0000-0000-4000-8000-000000000009', 'eb4a0000-0000-4000-8000-000000000003', 'eb4a0000-0000-4000-8000-000000000007', 'Sleep Trial', 'STANDARD'),
  ('eb4a0000-0000-4000-8000-000000000011', 'eb4a0000-0000-4000-8000-000000000003', 'eb4a0000-0000-4000-8000-000000000007', 'Sold', 'EXCHANGE')
on conflict (id) do nothing;

update public.sleep_journeys
set parent_journey_id = 'eb4a0000-0000-4000-8000-000000000009'
where id = 'eb4a0000-0000-4000-8000-000000000011';

-- One trial item per action (the one-open-action-per-item index).
insert into public.sleep_trial_items (id, company_id, journey_id, product_id, product_name_snapshot, status) values
  ('eb4a0000-0000-4000-8000-000000000010', 'eb4a0000-0000-4000-8000-000000000001', 'eb4a0000-0000-4000-8000-000000000009', 'eb4a0000-0000-4000-8000-000000000008', 'EB4A Mattress', 'EXCHANGE_IN_PROGRESS'),
  ('eb4a0000-0000-4000-8000-000000000013', 'eb4a0000-0000-4000-8000-000000000001', 'eb4a0000-0000-4000-8000-000000000009', 'eb4a0000-0000-4000-8000-000000000008', 'EB4A Mattress', 'EXCHANGE_IN_PROGRESS'),
  ('eb4a0000-0000-4000-8000-000000000014', 'eb4a0000-0000-4000-8000-000000000001', 'eb4a0000-0000-4000-8000-000000000009', 'eb4a0000-0000-4000-8000-000000000008', 'EB4A Mattress', 'EXCHANGE_IN_PROGRESS'),
  ('eb4a0000-0000-4000-8000-000000000016', 'eb4a0000-0000-4000-8000-000000000001', 'eb4a0000-0000-4000-8000-000000000009', 'eb4a0000-0000-4000-8000-000000000008', 'EB4A Mattress', 'EXCHANGE_IN_PROGRESS'),
  ('eb4a0000-0000-4000-8000-000000000017', 'eb4a0000-0000-4000-8000-000000000001', 'eb4a0000-0000-4000-8000-000000000009', 'eb4a0000-0000-4000-8000-000000000008', 'EB4A Mattress', 'EXCHANGE_IN_PROGRESS'),
  ('eb4a0000-0000-4000-8000-000000000018', 'eb4a0000-0000-4000-8000-000000000001', 'eb4a0000-0000-4000-8000-000000000009', 'eb4a0000-0000-4000-8000-000000000008', 'EB4A Mattress', 'EXCHANGE_IN_PROGRESS'),
  ('eb4a0000-0000-4000-8000-000000000019', 'eb4a0000-0000-4000-8000-000000000001', 'eb4a0000-0000-4000-8000-000000000009', 'eb4a0000-0000-4000-8000-000000000008', 'EB4A Mattress', 'EXCHANGE_IN_PROGRESS')
on conflict (id) do nothing;

-- Actions: 0012 warehouse receive path (receive/void/cancel tests),
-- 0013 store path, 0014 date guards, 0016 Wally, 0017 Ned, 0018 deactivated
-- Wally, 0019 cancel-lock, 0020 no-employee-row.
insert into public.sleep_trial_actions (
  id, company_id, journey_id, trial_item_id, action, status,
  child_journey_id, committed_at, committed_by
) values
  ('eb4a0000-0000-4000-8000-000000000012', 'eb4a0000-0000-4000-8000-000000000001', 'eb4a0000-0000-4000-8000-000000000009', 'eb4a0000-0000-4000-8000-000000000010', 'EXCHANGE', 'COMMITTED', 'eb4a0000-0000-4000-8000-000000000011', now() - interval '2 days', 'eb4a0000-0000-4000-8000-000000000004'),
  ('eb4a0000-0000-4000-8000-000000000021', 'eb4a0000-0000-4000-8000-000000000001', 'eb4a0000-0000-4000-8000-000000000009', 'eb4a0000-0000-4000-8000-000000000013', 'EXCHANGE', 'COMMITTED', 'eb4a0000-0000-4000-8000-000000000011', now() - interval '2 days', 'eb4a0000-0000-4000-8000-000000000004'),
  ('eb4a0000-0000-4000-8000-000000000022', 'eb4a0000-0000-4000-8000-000000000001', 'eb4a0000-0000-4000-8000-000000000009', 'eb4a0000-0000-4000-8000-000000000014', 'EXCHANGE', 'COMMITTED', null, now() - interval '2 days', 'eb4a0000-0000-4000-8000-000000000004'),
  ('eb4a0000-0000-4000-8000-000000000023', 'eb4a0000-0000-4000-8000-000000000001', 'eb4a0000-0000-4000-8000-000000000009', 'eb4a0000-0000-4000-8000-000000000016', 'EXCHANGE', 'COMMITTED', null, now() - interval '2 days', 'eb4a0000-0000-4000-8000-000000000004'),
  ('eb4a0000-0000-4000-8000-000000000024', 'eb4a0000-0000-4000-8000-000000000001', 'eb4a0000-0000-4000-8000-000000000009', 'eb4a0000-0000-4000-8000-000000000017', 'EXCHANGE', 'COMMITTED', null, now() - interval '2 days', 'eb4a0000-0000-4000-8000-000000000004'),
  ('eb4a0000-0000-4000-8000-000000000025', 'eb4a0000-0000-4000-8000-000000000001', 'eb4a0000-0000-4000-8000-000000000009', 'eb4a0000-0000-4000-8000-000000000018', 'EXCHANGE', 'COMMITTED', null, now() - interval '2 days', 'eb4a0000-0000-4000-8000-000000000004'),
  ('eb4a0000-0000-4000-8000-000000000026', 'eb4a0000-0000-4000-8000-000000000001', 'eb4a0000-0000-4000-8000-000000000009', 'eb4a0000-0000-4000-8000-000000000019', 'EXCHANGE', 'COMMITTED', null, now() - interval '2 days', 'eb4a0000-0000-4000-8000-000000000004')
on conflict (id) do nothing;

select 'fixture ready' as result,
  (select count(*) from public.sleep_trial_actions
    where company_id = 'eb4a0000-0000-4000-8000-000000000001') as actions,
  (select count(*) from public.stores
    where parent_location_id = 'eb4a0000-0000-4000-8000-000000000002'
      and location_type = 'WAREHOUSE_QUARANTINE') as wh_quarantine_rows;
-- Expect: actions=7, wh_quarantine_rows=1 (auto-provisioned by the 023 trigger).

-- ---------------------------------------------------------------------------
-- 1. RECEIVE at warehouse (Ada). Expect position +1, 1 ledger row,
--    1 AWAITING_INSPECTION, activity lines on BOTH journeys.
-- ---------------------------------------------------------------------------
do $$
declare
  v_inspection uuid;
  v_qty int; v_ledger int; v_insp int; v_lines int;
begin
  perform set_config('request.jwt.claim.sub', 'eb4a0000-0000-4000-8000-00000000a004', true);
  v_inspection := public.receive_returned_unit(
    'eb4a0000-0000-4000-8000-000000000012',
    'eb4a0000-0000-4000-8000-000000000002', current_date);
  select on_hand_quantity into v_qty from public.inventory_positions
    where variant_id = 'eb4a0000-0000-4000-8000-000000000008' and disposition = 'Returned';
  select count(*) into v_ledger from public.stock_ledger_entries
    where correlation_id = 'eb4a0000-0000-4000-8000-000000000012' and reason = 'return_received';
  select count(*) into v_insp from public.returned_unit_inspections
    where action_id = 'eb4a0000-0000-4000-8000-000000000012' and status = 'AWAITING_INSPECTION';
  select count(*) into v_lines from public.journey_interactions
    where source_record_id = 'eb4a0000-0000-4000-8000-000000000012'
      and summary like 'Original mattress received%';
  insert into public.eb4a_results (test_name, expected, actual, passed) values (
    'receive at warehouse',
    'qty=1 ledger=1 inspection=1 lines=2',
    'qty=' || v_qty || ' ledger=' || v_ledger || ' insp=' || v_insp || ' lines=' || v_lines,
    v_qty = 1 and v_ledger = 1 and v_insp = 1 and v_lines = 2);
end $$;

select * from public.eb4a_results order by id desc limit 1;

-- ---------------------------------------------------------------------------
-- 2. RECEIVE AGAIN (idempotent): no second +1, no second inspection.
-- ---------------------------------------------------------------------------
do $$
declare
  v_second uuid; v_first uuid;
  v_qty int; v_insp int;
begin
  perform set_config('request.jwt.claim.sub', 'eb4a0000-0000-4000-8000-00000000a004', true);
  select id into v_first from public.returned_unit_inspections
    where action_id = 'eb4a0000-0000-4000-8000-000000000012' and status = 'AWAITING_INSPECTION';
  v_second := public.receive_returned_unit(
    'eb4a0000-0000-4000-8000-000000000012',
    'eb4a0000-0000-4000-8000-000000000002', current_date);
  select on_hand_quantity into v_qty from public.inventory_positions
    where variant_id = 'eb4a0000-0000-4000-8000-000000000008' and disposition = 'Returned';
  select count(*) into v_insp from public.returned_unit_inspections
    where action_id = 'eb4a0000-0000-4000-8000-000000000012' and status = 'AWAITING_INSPECTION';
  insert into public.eb4a_results (test_name, expected, actual, passed) values (
    'receive twice idempotent',
    'same inspection id, qty=1, insp=1',
    'same=' || (v_second = v_first) || ' qty=' || v_qty || ' insp=' || v_insp,
    v_second = v_first and v_qty = 1 and v_insp = 1);
end $$;

select * from public.eb4a_results order by id desc limit 1;

-- ---------------------------------------------------------------------------
-- 3. RECEIVE AT A STORE refused (100: warehouse receiving only).
-- ---------------------------------------------------------------------------
do $$
declare
  v_msg text;
begin
  perform set_config('request.jwt.claim.sub', 'eb4a0000-0000-4000-8000-00000000a004', true);
  begin
    perform public.receive_returned_unit(
      'eb4a0000-0000-4000-8000-000000000021',
      'eb4a0000-0000-4000-8000-000000000003', current_date);
    insert into public.eb4a_results (test_name, expected, actual, passed)
    values ('receive at store refused', 'pick the warehouse', 'no error raised', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    insert into public.eb4a_results (test_name, expected, actual, passed)
    values ('receive at store refused', 'received at the warehouse. Pick the warehouse',
      v_msg, v_msg like '%received at the warehouse%Pick the warehouse%');
  end;
end $$;

select * from public.eb4a_results order by id desc limit 1;

-- ---------------------------------------------------------------------------
-- 4. create_quarantine_area on a STORE refused; twice on the warehouse
--    returns the same (auto-provisioned) id; then receive there works.
-- ---------------------------------------------------------------------------
do $$
declare
  v_msg text;
begin
  perform set_config('request.jwt.claim.sub', 'eb4a0000-0000-4000-8000-00000000a004', true);
  begin
    perform public.create_quarantine_area('eb4a0000-0000-4000-8000-000000000003');
    insert into public.eb4a_results (test_name, expected, actual, passed)
    values ('quarantine on store refused', 'warehouse only', 'no error raised', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    insert into public.eb4a_results (test_name, expected, actual, passed)
    values ('quarantine on store refused', 'can only be created for a warehouse',
      v_msg, v_msg like '%can only be created for a warehouse%');
  end;
end $$;

do $$
declare
  v_q1 uuid; v_q2 uuid; v_insp uuid;
  v_qty int;
begin
  perform set_config('request.jwt.claim.sub', 'eb4a0000-0000-4000-8000-00000000a004', true);
  v_q1 := public.create_quarantine_area('eb4a0000-0000-4000-8000-000000000002');
  v_q2 := public.create_quarantine_area('eb4a0000-0000-4000-8000-000000000002');
  v_insp := public.receive_returned_unit(
    'eb4a0000-0000-4000-8000-000000000021',
    'eb4a0000-0000-4000-8000-000000000002', current_date);
  select on_hand_quantity into v_qty from public.inventory_positions
    where variant_id = 'eb4a0000-0000-4000-8000-000000000008' and disposition = 'Returned'
      and location_id = v_q1;
  insert into public.eb4a_results (test_name, expected, actual, passed) values (
    'create_quarantine_area twice + receive at warehouse',
    'same id both calls, qty=1 at warehouse quarantine',
    'same=' || (v_q1 = v_q2) || ' qty=' || v_qty,
    v_q1 = v_q2 and v_qty = 1);
end $$;

select * from public.eb4a_results order by id desc limit 1;

-- ---------------------------------------------------------------------------
-- 5. FUTURE DATE refused (action 0022).
-- ---------------------------------------------------------------------------
do $$
declare
  v_msg text;
begin
  perform set_config('request.jwt.claim.sub', 'eb4a0000-0000-4000-8000-00000000a004', true);
  begin
    perform public.receive_returned_unit(
      'eb4a0000-0000-4000-8000-000000000022',
      'eb4a0000-0000-4000-8000-000000000002', current_date + 1);
    insert into public.eb4a_results (test_name, expected, actual, passed)
    values ('future date refused', 'future error', 'no error raised', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    insert into public.eb4a_results (test_name, expected, actual, passed)
    values ('future date refused', 'cannot be in the future',
      v_msg, v_msg like '%cannot be in the future%');
  end;
end $$;

select * from public.eb4a_results order by id desc limit 1;

-- ---------------------------------------------------------------------------
-- 6. DATE BEFORE COMMIT refused (same action, still unreceived).
-- ---------------------------------------------------------------------------
do $$
declare
  v_msg text;
begin
  perform set_config('request.jwt.claim.sub', 'eb4a0000-0000-4000-8000-00000000a004', true);
  begin
    perform public.receive_returned_unit(
      'eb4a0000-0000-4000-8000-000000000022',
      'eb4a0000-0000-4000-8000-000000000002', current_date - 10);
    insert into public.eb4a_results (test_name, expected, actual, passed)
    values ('date before commit refused', 'before committed error', 'no error raised', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    insert into public.eb4a_results (test_name, expected, actual, passed)
    values ('date before commit refused', 'cannot be before this exchange was committed',
      v_msg, v_msg like '%cannot be before this exchange was committed%');
  end;
end $$;

select * from public.eb4a_results order by id desc limit 1;

-- ---------------------------------------------------------------------------
-- 7. VOID the block-1 receipt. Expect full reversal.
-- ---------------------------------------------------------------------------
do $$
declare
  v_cancelled uuid;
  v_qty int; v_void int; v_on date; v_status text; v_lines int;
begin
  perform set_config('request.jwt.claim.sub', 'eb4a0000-0000-4000-8000-00000000a004', true);
  v_cancelled := public.void_returned_receipt(
    'eb4a0000-0000-4000-8000-000000000012', 'Marked received at the wrong store');
  select on_hand_quantity into v_qty from public.inventory_positions
    where variant_id = 'eb4a0000-0000-4000-8000-000000000008' and disposition = 'Returned'
      and location_id in (select id from public.stores
        where parent_location_id = 'eb4a0000-0000-4000-8000-000000000002');
  select count(*) into v_void from public.stock_ledger_entries
    where correlation_id = 'eb4a0000-0000-4000-8000-000000000012' and reason = 'return_receipt_voided';
  select original_received_on into v_on from public.sleep_trial_actions
    where id = 'eb4a0000-0000-4000-8000-000000000012';
  select status into v_status from public.returned_unit_inspections
    where action_id = 'eb4a0000-0000-4000-8000-000000000012';
  select count(*) into v_lines from public.journey_interactions
    where source_record_id = 'eb4a0000-0000-4000-8000-000000000012'
      and summary like 'Receipt of the original mattress was voided%';
  insert into public.eb4a_results (test_name, expected, actual, passed) values (
    'void receipt reversal',
    'qty=0 voidLedger=1 received_on=NULL insp=CANCELLED lines=2',
    'qty=' || v_qty || ' void=' || v_void || ' on=' || coalesce(v_on::text,'NULL')
      || ' insp=' || v_status || ' lines=' || v_lines,
    v_qty = 0 and v_void = 1 and v_on is null and v_status = 'CANCELLED' and v_lines = 2);
end $$;

select * from public.eb4a_results order by id desc limit 1;

-- ---------------------------------------------------------------------------
-- 8. VOID AFTER INSPECTION STARTED refused (action 0021 inspection forced).
-- ---------------------------------------------------------------------------
update public.returned_unit_inspections
set status = 'IN_PROGRESS', started_at = now()
where action_id = 'eb4a0000-0000-4000-8000-000000000021';

do $$
declare
  v_msg text;
begin
  perform set_config('request.jwt.claim.sub', 'eb4a0000-0000-4000-8000-00000000a004', true);
  begin
    perform public.void_returned_receipt(
      'eb4a0000-0000-4000-8000-000000000021', 'trying to void a started inspection');
    insert into public.eb4a_results (test_name, expected, actual, passed)
    values ('void after inspection started', 'already being inspected', 'no error raised', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    insert into public.eb4a_results (test_name, expected, actual, passed)
    values ('void after inspection started', 'already being inspected',
      v_msg, v_msg like '%already being inspected%');
  end;
end $$;

select * from public.eb4a_results order by id desc limit 1;

-- ---------------------------------------------------------------------------
-- 9. VOID WITH EMPTY REASON refused (action 0021 has a live receipt).
-- ---------------------------------------------------------------------------
do $$
declare
  v_msg text;
begin
  perform set_config('request.jwt.claim.sub', 'eb4a0000-0000-4000-8000-00000000a004', true);
  begin
    perform public.void_returned_receipt(
      'eb4a0000-0000-4000-8000-000000000021', '   ');
    insert into public.eb4a_results (test_name, expected, actual, passed)
    values ('void empty reason refused', 'reason required', 'no error raised', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    insert into public.eb4a_results (test_name, expected, actual, passed)
    values ('void empty reason refused', 'reason is required',
      v_msg, v_msg like '%reason is required%');
  end;
end $$;

select * from public.eb4a_results order by id desc limit 1;

-- ---------------------------------------------------------------------------
-- 10. NED refused (employee role, no grants, not warehouse-based) then
--     WALLY allowed (warehouse-based) on action 0023.
-- ---------------------------------------------------------------------------
do $$
declare
  v_msg text;
begin
  perform set_config('request.jwt.claim.sub', 'eb4a0000-0000-4000-8000-00000000a006', true);
  begin
    perform public.receive_returned_unit(
      'eb4a0000-0000-4000-8000-000000000023',
      'eb4a0000-0000-4000-8000-000000000002', current_date);
    insert into public.eb4a_results (test_name, expected, actual, passed)
    values ('no-rights employee refused', 'permission error', 'no error raised', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    insert into public.eb4a_results (test_name, expected, actual, passed)
    values ('no-rights employee refused', 'do not have permission',
      v_msg, v_msg like '%do not have permission%');
  end;
end $$;

do $$
declare
  v_insp uuid;
begin
  perform set_config('request.jwt.claim.sub', 'eb4a0000-0000-4000-8000-00000000a005', true);
  v_insp := public.receive_returned_unit(
    'eb4a0000-0000-4000-8000-000000000023',
    'eb4a0000-0000-4000-8000-000000000002', current_date);
  insert into public.eb4a_results (test_name, expected, actual, passed)
  values ('warehouse-based allowed', 'inspection id returned',
    coalesce(v_insp::text, 'null'), v_insp is not null);
end $$;

select * from public.eb4a_results order by id desc limit 2;

-- ---------------------------------------------------------------------------
-- 11. DEACTIVATED WALLY refused on action 0024.
-- ---------------------------------------------------------------------------
update public.employees set is_active = false
where id = 'eb4a0000-0000-4000-8000-000000000005';

do $$
declare
  v_msg text;
begin
  perform set_config('request.jwt.claim.sub', 'eb4a0000-0000-4000-8000-00000000a005', true);
  begin
    perform public.receive_returned_unit(
      'eb4a0000-0000-4000-8000-000000000024',
      'eb4a0000-0000-4000-8000-000000000002', current_date);
    insert into public.eb4a_results (test_name, expected, actual, passed)
    values ('deactivated warehouse employee refused', 'refused', 'no error raised', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    insert into public.eb4a_results (test_name, expected, actual, passed)
    values ('deactivated warehouse employee refused', 'refused',
      v_msg, true);
  end;
end $$;

update public.employees set is_active = true
where id = 'eb4a0000-0000-4000-8000-000000000005';

select * from public.eb4a_results order by id desc limit 1;

-- ---------------------------------------------------------------------------
-- 12. OTHER-COMPANY owner calling create_quarantine_area on OUR store.
-- ---------------------------------------------------------------------------
do $$
declare
  v_msg text;
begin
  perform set_config('request.jwt.claim.sub', 'eb4a0000-0000-4000-8000-00000000ac03', true);
  begin
    perform public.create_quarantine_area('eb4a0000-0000-4000-8000-000000000003');
    insert into public.eb4a_results (test_name, expected, actual, passed)
    values ('cross-company quarantine refused', 'not part of your company', 'no error raised', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    insert into public.eb4a_results (test_name, expected, actual, passed)
    values ('cross-company quarantine refused', 'not part of your company',
      v_msg, v_msg like '%not part of your company%');
  end;
end $$;

select * from public.eb4a_results order by id desc limit 1;

-- ---------------------------------------------------------------------------
-- 13. NO EMPLOYEE ROW (fresh auth uid with no employees record) refused on
--     all three functions.
-- ---------------------------------------------------------------------------
do $$
declare
  v_msg text; v_ok boolean := true; v_msgs text := '';
begin
  perform set_config('request.jwt.claim.sub', 'eb4a0000-0000-4000-8000-00000000b001', true);

  begin
    perform public.receive_returned_unit(
      'eb4a0000-0000-4000-8000-000000000023',
      'eb4a0000-0000-4000-8000-000000000002', current_date);
    v_ok := false; v_msgs := v_msgs || 'receive:noError ';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    v_msgs := v_msgs || 'receive:' || left(v_msg, 40) || ' ';
  end;

  begin
    perform public.void_returned_receipt(
      'eb4a0000-0000-4000-8000-000000000023', 'reason text');
    v_ok := false; v_msgs := v_msgs || 'void:noError ';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    v_msgs := v_msgs || 'void:' || left(v_msg, 40) || ' ';
  end;

  begin
    perform public.create_quarantine_area('eb4a0000-0000-4000-8000-000000000003');
    v_ok := false; v_msgs := v_msgs || 'quarantine:noError ';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    v_msgs := v_msgs || 'quarantine:' || left(v_msg, 40) || ' ';
  end;

  insert into public.eb4a_results (test_name, expected, actual, passed)
  values ('no employee row refused x3', 'all three refused', v_msgs, v_ok);
end $$;

select * from public.eb4a_results order by id desc limit 1;

-- ---------------------------------------------------------------------------
-- 14. NONEXISTENT ACTION -> "not found".
-- ---------------------------------------------------------------------------
do $$
declare
  v_msg text;
begin
  perform set_config('request.jwt.claim.sub', 'eb4a0000-0000-4000-8000-00000000a004', true);
  begin
    perform public.receive_returned_unit(
      'eb4a0000-0000-4000-8000-00000000ffff',
      'eb4a0000-0000-4000-8000-000000000002', current_date);
    insert into public.eb4a_results (test_name, expected, actual, passed)
    values ('nonexistent action', 'not found', 'no error raised', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    insert into public.eb4a_results (test_name, expected, actual, passed)
    values ('nonexistent action', 'not found',
      v_msg, v_msg like '%not found%');
  end;
end $$;

select * from public.eb4a_results order by id desc limit 1;

-- ---------------------------------------------------------------------------
-- 15. CANCEL LOCK: re-receive action 0012, cancel refused, void, cancel ok.
-- ---------------------------------------------------------------------------
do $$
declare
  v_insp uuid; v_msg text; v_status text;
begin
  perform set_config('request.jwt.claim.sub', 'eb4a0000-0000-4000-8000-00000000a004', true);
  -- re-receive after the block-7 void
  v_insp := public.receive_returned_unit(
    'eb4a0000-0000-4000-8000-000000000012',
    'eb4a0000-0000-4000-8000-000000000002', current_date);

  begin
    perform public.cancel_sleep_trial_action(
      'eb4a0000-0000-4000-8000-000000000012', 'cancel while received');
    insert into public.eb4a_results (test_name, expected, actual, passed)
    values ('cancel while received refused', 'already received error', 'no error raised', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    insert into public.eb4a_results (test_name, expected, actual, passed)
    values ('cancel while received refused', 'already received',
      v_msg, v_msg like '%already received%' or v_msg like '%cannot be cancelled%');
  end;

  perform public.void_returned_receipt(
    'eb4a0000-0000-4000-8000-000000000012', 'cancel-lock test void');
  perform public.cancel_sleep_trial_action(
    'eb4a0000-0000-4000-8000-000000000012', 'cancel after void');
  select status into v_status from public.sleep_trial_actions
    where id = 'eb4a0000-0000-4000-8000-000000000012';
  insert into public.eb4a_results (test_name, expected, actual, passed)
  values ('cancel allowed after void', 'status CANCELLED',
    coalesce(v_status, 'null'), v_status = 'CANCELLED');
end $$;

select * from public.eb4a_results order by id desc limit 2;

-- ---------------------------------------------------------------------------
-- 16. RETURNED NEVER SHOWS AS PRIME in inventory_positions_public at the
--     quarantine locations (the same read fetchProductStock makes).
-- ---------------------------------------------------------------------------
insert into public.eb4a_results (test_name, expected, actual, passed)
select
  'returned not visible as prime',
  '0 prime rows at quarantine areas',
  'prime_rows=' || count(*),
  count(*) = 0
from public.inventory_positions_public
where disposition = 'Prime'
  and variant_id = 'eb4a0000-0000-4000-8000-000000000008'
  and location_id in (
    select id from public.stores
    where parent_location_id in (
      'eb4a0000-0000-4000-8000-000000000002',
      'eb4a0000-0000-4000-8000-000000000003'));

select * from public.eb4a_results order by id desc limit 1;

-- ---------------------------------------------------------------------------
-- 17. ALL RESULTS
-- ---------------------------------------------------------------------------
select * from public.eb4a_results order by id;

-- ---------------------------------------------------------------------------
-- 18. TEARDOWN — delete order respects FKs (children before parents,
--     journey_events before journeys per the delivered-journey guard).
--     FK check: returned_unit_inspections -> actions/journeys/items/products/
--     stores; sleep_trial_actions -> items/journeys/companies;
--     sleep_journeys -> customers/stores/companies/parent;
--     journey_interactions/journey_events -> journeys;
--     audit_events -> companies; role_permission_grants -> companies;
--     employees -> auth.users/stores; stores.parent_location_id -> stores
--     (delete quarantine children before parents).
-- ---------------------------------------------------------------------------
drop table public.eb4a_results;

delete from public.journey_interactions
where journey_id in ('eb4a0000-0000-4000-8000-000000000009','eb4a0000-0000-4000-8000-000000000011');
delete from public.journey_events
where journey_id in ('eb4a0000-0000-4000-8000-000000000009','eb4a0000-0000-4000-8000-000000000011');
delete from public.returned_unit_inspections
where company_id = 'eb4a0000-0000-4000-8000-000000000001';
delete from public.stock_ledger_entries
where variant_id = 'eb4a0000-0000-4000-8000-000000000008';
delete from public.inventory_positions
where variant_id = 'eb4a0000-0000-4000-8000-000000000008';
delete from public.audit_events
where company_id = 'eb4a0000-0000-4000-8000-000000000001';
delete from public.sleep_trial_actions
where company_id = 'eb4a0000-0000-4000-8000-000000000001';
delete from public.sleep_trial_items
where company_id = 'eb4a0000-0000-4000-8000-000000000001';
delete from public.sleep_journeys
where id = 'eb4a0000-0000-4000-8000-000000000011';
delete from public.sleep_journeys
where id = 'eb4a0000-0000-4000-8000-000000000009';
delete from public.customers where id = 'eb4a0000-0000-4000-8000-000000000007';
delete from public.products where id = 'eb4a0000-0000-4000-8000-000000000008';
delete from public.employees
where id in (
  'eb4a0000-0000-4000-8000-000000000004',
  'eb4a0000-0000-4000-8000-000000000005',
  'eb4a0000-0000-4000-8000-000000000006',
  'eb4a0000-0000-4000-8000-00000000c003');
delete from public.role_permission_grants
where company_id = 'eb4a0000-0000-4000-8000-000000000001';
-- quarantine children before parent stores
delete from public.stores where parent_location_id in (
  'eb4a0000-0000-4000-8000-000000000002',
  'eb4a0000-0000-4000-8000-000000000003');
delete from public.stores where id in (
  'eb4a0000-0000-4000-8000-000000000002',
  'eb4a0000-0000-4000-8000-000000000003',
  'eb4a0000-0000-4000-8000-00000000c002');
delete from public.companies where id in (
  'eb4a0000-0000-4000-8000-000000000001',
  'eb4a0000-0000-4000-8000-00000000c001');
delete from auth.users where id in (
  'eb4a0000-0000-4000-8000-00000000a004',
  'eb4a0000-0000-4000-8000-00000000a005',
  'eb4a0000-0000-4000-8000-00000000a006',
  'eb4a0000-0000-4000-8000-00000000ac03');

select
  (select count(*) from public.sleep_trial_actions where company_id = 'eb4a0000-0000-4000-8000-000000000001') as actions_left,
  (select count(*) from public.sleep_trial_items where company_id = 'eb4a0000-0000-4000-8000-000000000001') as items_left,
  (select count(*) from public.sleep_journeys where id in ('eb4a0000-0000-4000-8000-000000000009','eb4a0000-0000-4000-8000-000000000011')) as journeys_left,
  (select count(*) from public.employees where id::text like 'eb4a0000-%') as employees_left,
  (select count(*) from public.stores where company_id in ('eb4a0000-0000-4000-8000-000000000001','eb4a0000-0000-4000-8000-00000000c001')) as stores_left,
  (select count(*) from public.companies where id in ('eb4a0000-0000-4000-8000-000000000001','eb4a0000-0000-4000-8000-00000000c001')) as companies_left,
  (select count(*) from auth.users where id::text like 'eb4a0000-%') as auth_users_left;
-- Expect all zeros.
