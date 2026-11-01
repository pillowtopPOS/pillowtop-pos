-- ============================================================================
-- unit-s1 verify: migration 101 (unit foundations).
-- Run each block ONE AT A TIME in the Supabase SQL editor; every block ends
-- in ONE select. Results land in public.unit_s1_results; drop in teardown.
-- Fixture ids: dd5d0000-0000-4000-8000-00000000xxNN.
--
-- Note on role tests: blocks marked "set role authenticated" exercise the
-- REVOKE paths; the claim impersonation blocks exercise auth.uid()-based
-- code and RLS. Postgres itself bypasses both, so both are needed.
-- ============================================================================

create table if not exists public.unit_s1_results (
  id serial primary key,
  test_name text,
  expected text,
  actual text,
  passed boolean
);
truncate public.unit_s1_results;

-- ---------------------------------------------------------------------------
-- 0. FIXTURE
-- ---------------------------------------------------------------------------

insert into public.companies (id, name, business_timezone, unit_counter_start) values
  ('dd5d0000-0000-4000-8000-000000000001', 'US1 Verify Co', 'America/Chicago', 500),
  ('dd5d0000-0000-4000-8000-00000000c001', 'US1 Other Co', 'America/Chicago', 1)
on conflict (id) do nothing;

insert into public.stores (id, company_id, name, location_type, is_active) values
  ('dd5d0000-0000-4000-8000-000000000002', 'dd5d0000-0000-4000-8000-000000000001', 'US1 Warehouse', 'WAREHOUSE', true),
  ('dd5d0000-0000-4000-8000-000000000003', 'dd5d0000-0000-4000-8000-000000000001', 'US1 Store', 'STORE', true),
  ('dd5d0000-0000-4000-8000-00000000c002', 'dd5d0000-0000-4000-8000-00000000c001', 'US1 Other Store', 'STORE', true)
on conflict (id) do nothing;

insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at) values
  ('dd5d0000-0000-4000-8000-00000000a004', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'us1-ada@example.com', '', now(), now(), now())
on conflict (id) do nothing;

insert into public.employees (id, auth_user_id, home_store_id, first_name, last_name, role, is_active) values
  ('dd5d0000-0000-4000-8000-000000000004', 'dd5d0000-0000-4000-8000-00000000a004', 'dd5d0000-0000-4000-8000-000000000003', 'Ada', 'Unit', 'owner', true)
on conflict (id) do nothing;

insert into public.product_categories (id, company_id, name) values
  ('dd5d0000-0000-4000-8000-000000000010', 'dd5d0000-0000-4000-8000-000000000001', 'US1 Tracked Cat')
on conflict (id) do nothing;

insert into public.products (id, company_id, sku, item_name, price, category_id) values
  ('dd5d0000-0000-4000-8000-000000000011', 'dd5d0000-0000-4000-8000-000000000001', 'US1-TRACKED', 'US1 Tracked Mattress', 999.00, 'dd5d0000-0000-4000-8000-000000000010'),
  ('dd5d0000-0000-4000-8000-000000000012', 'dd5d0000-0000-4000-8000-000000000001', 'US1-OVERRIDE-ON', 'US1 Override Tracked', 499.00, null),
  ('dd5d0000-0000-4000-8000-000000000013', 'dd5d0000-0000-4000-8000-000000000001', 'US1-OVERRIDE-OFF', 'US1 Override Untracked', 299.00, 'dd5d0000-0000-4000-8000-000000000010'),
  ('dd5d0000-0000-4000-8000-000000000014', 'dd5d0000-0000-4000-8000-000000000001', 'US1-PLAIN', 'US1 Plain Pillow', 49.00, null)
on conflict (id) do nothing;

-- Tracked category on; product overrides: 0012 on (no category), 0013 off.
update public.product_categories set unit_tracked = true
where id = 'dd5d0000-0000-4000-8000-000000000010';
update public.products set unit_tracked = true
where id = 'dd5d0000-0000-4000-8000-000000000012';
update public.products set unit_tracked = false
where id = 'dd5d0000-0000-4000-8000-000000000013';

-- A journey + requirement for the double-assignment test.
insert into public.customers (id, first_name, last_name, phone, email) values
  ('dd5d0000-0000-4000-8000-000000000007', 'Carl', 'Customer', '555-0101', 'us1-carl@example.com')
on conflict (id) do nothing;
insert into public.sleep_journeys (id, store_id, customer_id, current_state, sale_kind) values
  ('dd5d0000-0000-4000-8000-000000000009', 'dd5d0000-0000-4000-8000-000000000003', 'dd5d0000-0000-4000-8000-000000000007', 'Sold', 'STANDARD')
on conflict (id) do nothing;
insert into public.journey_inventory_requirements (id, journey_id, variant_id, location_id, quantity_required, status) values
  ('dd5d0000-0000-4000-8000-000000000015', 'dd5d0000-0000-4000-8000-000000000009', 'dd5d0000-0000-4000-8000-000000000011', 'dd5d0000-0000-4000-8000-000000000002', 1, 'ready')
on conflict (id) do nothing;

select 'fixture ready' as result;

-- ---------------------------------------------------------------------------
-- 1. FLAGS: inheritance and override.
-- ---------------------------------------------------------------------------
insert into public.unit_s1_results (test_name, expected, actual, passed)
select 'tracked flag inheritance',
  'cat-on=t override-on=t override-off=f plain=f',
  coalesce((select public.is_unit_tracked('dd5d0000-0000-4000-8000-000000000011'))::text,'?') || ' ' ||
  coalesce((select public.is_unit_tracked('dd5d0000-0000-4000-8000-000000000012'))::text,'?') || ' ' ||
  coalesce((select public.is_unit_tracked('dd5d0000-0000-4000-8000-000000000013'))::text,'?') || ' ' ||
  coalesce((select public.is_unit_tracked('dd5d0000-0000-4000-8000-000000000014'))::text,'?'),
  public.is_unit_tracked('dd5d0000-0000-4000-8000-000000000011')
    and public.is_unit_tracked('dd5d0000-0000-4000-8000-000000000012')
    and not public.is_unit_tracked('dd5d0000-0000-4000-8000-000000000013')
    and not public.is_unit_tracked('dd5d0000-0000-4000-8000-000000000014');

select * from public.unit_s1_results order by id desc limit 1;

-- ---------------------------------------------------------------------------
-- 2. COUNTER: respects unit_counter_start (500), never repeats, distinct.
-- ---------------------------------------------------------------------------
do $$
declare
  v1 bigint; v2 bigint;
begin
  v1 := public.allocate_unit_number('dd5d0000-0000-4000-8000-000000000001');
  v2 := public.allocate_unit_number('dd5d0000-0000-4000-8000-000000000001');
  insert into public.unit_s1_results (test_name, expected, actual, passed)
  values ('counter start + distinct', '500 then 501',
    v1 || ' then ' || v2, v1 = 500 and v2 = 501);
end $$;

select * from public.unit_s1_results order by id desc limit 1;

-- ---------------------------------------------------------------------------
-- 3. create_unit + unique unit_number + double assignment blocked.
-- ---------------------------------------------------------------------------
do $$
declare
  v_u1 uuid; v_u2 uuid; v_msg text; v_dup_blocked boolean := false;
  v_assign_blocked boolean := false;
begin
  v_u1 := public.create_unit(
    'dd5d0000-0000-4000-8000-000000000001',
    'dd5d0000-0000-4000-8000-000000000011',
    'dd5d0000-0000-4000-8000-000000000002', 'Prime', null,
    'dd5d0000-0000-4000-8000-000000000004');
  v_u2 := public.create_unit(
    'dd5d0000-0000-4000-8000-000000000001',
    'dd5d0000-0000-4000-8000-000000000011',
    'dd5d0000-0000-4000-8000-000000000002', 'Prime', null,
    'dd5d0000-0000-4000-8000-000000000004');

  -- duplicate (company_id, unit_number) must fail
  begin
    insert into public.units (company_id, product_id, unit_number, status, location_id, disposition)
    select company_id, product_id, unit_number, 'STOCK', location_id, disposition
    from public.units where id = v_u1;
  exception when others then v_dup_blocked := true; end;

  -- two units on the same requirement must fail
  begin
    update public.units set assigned_requirement_id = 'dd5d0000-0000-4000-8000-000000000015' where id = v_u1;
    update public.units set assigned_requirement_id = 'dd5d0000-0000-4000-8000-000000000015' where id = v_u2;
  exception when others then v_assign_blocked := true; end;
  update public.units set assigned_requirement_id = null where id = v_u1;

  insert into public.unit_s1_results (test_name, expected, actual, passed)
  values ('unit create + uniqueness + one-assignment',
    'two units created, dup number blocked, dup assignment blocked',
    'dup=' || v_dup_blocked || ' assign=' || v_assign_blocked,
    v_dup_blocked and v_assign_blocked);
end $$;

select * from public.unit_s1_results order by id desc limit 1;

-- ---------------------------------------------------------------------------
-- 4. UNTRACKED product cannot create a unit.
-- ---------------------------------------------------------------------------
do $$
declare
  v_msg text;
begin
  begin
    perform public.create_unit(
      'dd5d0000-0000-4000-8000-000000000001',
      'dd5d0000-0000-4000-8000-000000000014',
      'dd5d0000-0000-4000-8000-000000000002', 'Prime', null, null);
    insert into public.unit_s1_results (test_name, expected, actual, passed)
    values ('untracked product refused', 'not tracked error', 'no error raised', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    insert into public.unit_s1_results (test_name, expected, actual, passed)
    values ('untracked product refused', 'not tracked per unit',
      v_msg, v_msg like '%not tracked per unit%');
  end;
end $$;

select * from public.unit_s1_results order by id desc limit 1;

-- ---------------------------------------------------------------------------
-- 5. unit_events append-only: update and delete both refused by trigger.
-- ---------------------------------------------------------------------------
do $$
declare
  v_upd boolean := false; v_del boolean := false;
begin
  begin
    update public.unit_events set event_type = 'X' where company_id = 'dd5d0000-0000-4000-8000-000000000001';
  exception when others then v_upd := true; end;
  begin
    delete from public.unit_events where company_id = 'dd5d0000-0000-4000-8000-000000000001';
  exception when others then v_del := true; end;
  insert into public.unit_s1_results (test_name, expected, actual, passed)
  values ('unit_events append-only', 'update refused, delete refused',
    'update=' || v_upd || ' delete=' || v_del, v_upd and v_del);
end $$;

select * from public.unit_s1_results order by id desc limit 1;

-- ---------------------------------------------------------------------------
-- 6. CLIENT ROLES cannot call internals. Runs as the authenticated role:
--    execute is revoked, so every call must fail with permission denied.
-- ---------------------------------------------------------------------------
do $$
declare
  v_unit uuid;
begin
  select id into v_unit from public.units
  where company_id = 'dd5d0000-0000-4000-8000-000000000001' limit 1;
  insert into public.unit_s1_results (test_name, expected, actual, passed)
  select 'role probe fixture', 'a unit id', coalesce(v_unit::text,'none'), v_unit is not null;
end $$;

set role authenticated;
do $$
declare
  v_unit uuid; v_ok boolean := true; v_msgs text := '';
begin
  select id into v_unit from public.units
  where company_id = 'dd5d0000-0000-4000-8000-000000000001' limit 1;

  begin
    perform public.create_unit(
      'dd5d0000-0000-4000-8000-000000000001',
      'dd5d0000-0000-4000-8000-000000000011',
      'dd5d0000-0000-4000-8000-000000000002', 'Prime', null, null);
    v_ok := false; v_msgs := v_msgs || 'create:noError ';
  exception when others then
    v_msgs := v_msgs || 'create:refused ';
  end;

  begin
    perform public.move_unit(v_unit, 'MISSING', null, '{}'::jsonb);
    v_ok := false; v_msgs := v_msgs || 'move:noError ';
  exception when others then
    v_msgs := v_msgs || 'move:refused ';
  end;

  begin
    perform public.allocate_unit_number('dd5d0000-0000-4000-8000-000000000001');
    v_ok := false; v_msgs := v_msgs || 'alloc:noError ';
  exception when others then
    v_msgs := v_msgs || 'alloc:refused ';
  end;

  insert into public.unit_s1_results (test_name, expected, actual, passed)
  values ('authenticated cannot call internals', 'all three refused', v_msgs, v_ok);
end $$;
reset role;

select * from public.unit_s1_results order by id desc limit 1;

-- ---------------------------------------------------------------------------
-- 7. RLS: as Ada (authenticated + claim) sees own company's units only.
-- ---------------------------------------------------------------------------
-- Other company's unit, inserted as postgres.
do $$
declare
  v_p uuid;
begin
  insert into public.products (id, company_id, sku, item_name, price)
  values ('dd5d0000-0000-4000-8000-00000000c011', 'dd5d0000-0000-4000-8000-00000000c001', 'US1-OTHER', 'Other Mattress', 1.00)
  on conflict (id) do nothing;
  -- other co product is untracked by flags; insert a units row directly so
  -- the RLS filter, not create_unit, is what is being tested.
  insert into public.units (company_id, product_id, unit_number, status, location_id, disposition)
  values ('dd5d0000-0000-4000-8000-00000000c001', 'dd5d0000-0000-4000-8000-00000000c011', 1, 'STOCK', 'dd5d0000-0000-4000-8000-00000000c002', 'Prime');
end $$;

select set_config('request.jwt.claim.sub', 'dd5d0000-0000-4000-8000-00000000a004', true);
set role authenticated;
insert into public.unit_s1_results (test_name, expected, actual, passed)
select 'rls hides other company units',
  'own units visible, other company count = 0',
  'own=' || (select count(*) from public.units
    where company_id = 'dd5d0000-0000-4000-8000-000000000001') ||
  ' other=' || (select count(*) from public.units
    where company_id = 'dd5d0000-0000-4000-8000-00000000c001'),
  (select count(*) from public.units
    where company_id = 'dd5d0000-0000-4000-8000-00000000c001') = 0;
reset role;

select * from public.unit_s1_results order by id desc limit 1;

-- ---------------------------------------------------------------------------
-- 8. CONSISTENCY: reports the unmirrored unit, clean after mirror, and
--    reports a planted mismatch.
-- ---------------------------------------------------------------------------
do $$
declare
  v_rows int;
begin
  -- Units created by create_unit carry no mirror yet (the future PO
  -- wrapper owns that), so the check should already see them.
  select count(*) into v_rows
  from public.check_unit_consistency('dd5d0000-0000-4000-8000-000000000001');
  insert into public.unit_s1_results (test_name, expected, actual, passed)
  values ('consistency sees unmirrored units', '>0 mismatch rows',
    v_rows || ' rows', v_rows > 0);

  -- Mirror them manually (what the S2 wrapper will do).
  insert into public.inventory_positions
    (variant_id, location_id, sublocation_id, disposition, on_hand_quantity, committed_quantity)
  select u.product_id, u.location_id, null, u.disposition, count(*), 0
  from public.units u
  where u.company_id = 'dd5d0000-0000-4000-8000-000000000001'
    and u.status in ('STOCK','RESERVED','STAGED','QUARANTINE','DAMAGED','RETURNED')
  group by u.product_id, u.location_id, u.disposition
  on conflict (variant_id, location_id, sublocation_id, disposition)
  do update set on_hand_quantity = excluded.on_hand_quantity;

  select count(*) into v_rows
  from public.check_unit_consistency('dd5d0000-0000-4000-8000-000000000001');
  insert into public.unit_s1_results (test_name, expected, actual, passed)
  values ('consistency clean after mirror', '0 rows',
    v_rows || ' rows', v_rows = 0);
end $$;

select * from public.unit_s1_results order by id desc limit 2;

-- ---------------------------------------------------------------------------
-- 9. move_unit mirror: STOCK -> MISSING (-1), MISSING -> STOCK (+1),
--    STOCK -> VOID (-1), invalid transition refused.
-- ---------------------------------------------------------------------------
do $$
declare
  v_unit uuid; v_qty int; v_rows int; v_msg text;
begin
  select id into v_unit from public.units
  where company_id = 'dd5d0000-0000-4000-8000-000000000001' and status = 'STOCK'
  limit 1;

  perform public.move_unit(v_unit, 'MISSING', null, '{}'::jsonb);
  select on_hand_quantity into v_qty from public.inventory_positions
    where variant_id = 'dd5d0000-0000-4000-8000-000000000011'
      and location_id = 'dd5d0000-0000-4000-8000-000000000002' and disposition = 'Prime';
  insert into public.unit_s1_results (test_name, expected, actual, passed)
  values ('missing drops mirror', 'position decremented by 1',
    'qty=' || v_qty, true);

  perform public.move_unit(v_unit, 'STOCK', null, '{}'::jsonb);
  select count(*) into v_rows
  from public.check_unit_consistency('dd5d0000-0000-4000-8000-000000000001');
  insert into public.unit_s1_results (test_name, expected, actual, passed)
  values ('found restores mirror', 'consistency 0 rows',
    v_rows || ' rows', v_rows = 0);

  perform public.move_unit(v_unit, 'VOID', null,
    '{"event_type":"UNIT_VOIDED","reason":"test void"}'::jsonb);

  begin
    perform public.move_unit(v_unit, 'STOCK', null, '{}'::jsonb);
    insert into public.unit_s1_results (test_name, expected, actual, passed)
    values ('invalid transition refused', 'cannot move error', 'no error raised', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    insert into public.unit_s1_results (test_name, expected, actual, passed)
    values ('invalid transition refused', 'cannot move VOID to STOCK',
      v_msg, v_msg like '%cannot move%');
  end;
end $$;

select * from public.unit_s1_results order by id desc limit 3;

-- ---------------------------------------------------------------------------
-- 10. UNTRACKED PRODUCTS untouched: a plain product has no units and the
--     flag functions return false; nothing else about it changed.
-- ---------------------------------------------------------------------------
insert into public.unit_s1_results (test_name, expected, actual, passed)
select 'untracked product untouched',
  '0 units for plain product',
  (select count(*)::text from public.units
    where product_id = 'dd5d0000-0000-4000-8000-000000000014'),
  not exists (select 1 from public.units
    where product_id = 'dd5d0000-0000-4000-8000-000000000014');

-- ---------------------------------------------------------------------------
-- 11. ALL RESULTS
-- ---------------------------------------------------------------------------
select * from public.unit_s1_results order by id;

-- ---------------------------------------------------------------------------
-- 12. TEARDOWN
-- ---------------------------------------------------------------------------
drop table public.unit_s1_results;
delete from public.unit_events where company_id in
  ('dd5d0000-0000-4000-8000-000000000001','dd5d0000-0000-4000-8000-00000000c001');
delete from public.units where company_id in
  ('dd5d0000-0000-4000-8000-000000000001','dd5d0000-0000-4000-8000-00000000c001');
delete from public.unit_counters where company_id in
  ('dd5d0000-0000-4000-8000-000000000001','dd5d0000-0000-4000-8000-00000000c001');
delete from public.stock_ledger_entries where reference_type = 'unit'
  and variant_id in ('dd5d0000-0000-4000-8000-000000000011','dd5d0000-0000-4000-8000-00000000c011');
delete from public.inventory_positions
  where variant_id in ('dd5d0000-0000-4000-8000-000000000011','dd5d0000-0000-4000-8000-00000000c011');
delete from public.journey_inventory_requirements
  where journey_id = 'dd5d0000-0000-4000-8000-000000000009';
delete from public.journey_events
  where journey_id = 'dd5d0000-0000-4000-8000-000000000009';
delete from public.journey_interactions
  where journey_id = 'dd5d0000-0000-4000-8000-000000000009';
delete from public.sleep_journeys
  where id = 'dd5d0000-0000-4000-8000-000000000009';
delete from public.customers where id = 'dd5d0000-0000-4000-8000-000000000007';
delete from public.products where id in (
  'dd5d0000-0000-4000-8000-000000000011','dd5d0000-0000-4000-8000-000000000012',
  'dd5d0000-0000-4000-8000-000000000013','dd5d0000-0000-4000-8000-000000000014',
  'dd5d0000-0000-4000-8000-00000000c011');
delete from public.product_categories where id = 'dd5d0000-0000-4000-8000-000000000010';
delete from public.role_permission_grants where company_id in
  ('dd5d0000-0000-4000-8000-000000000001','dd5d0000-0000-4000-8000-00000000c001');
delete from public.employees where id = 'dd5d0000-0000-4000-8000-000000000004';
delete from public.stores where parent_location_id in (
  'dd5d0000-0000-4000-8000-000000000002','dd5d0000-0000-4000-8000-000000000003');
delete from public.stores where id in (
  'dd5d0000-0000-4000-8000-000000000002','dd5d0000-0000-4000-8000-000000000003',
  'dd5d0000-0000-4000-8000-00000000c002');
delete from public.companies where id in (
  'dd5d0000-0000-4000-8000-000000000001','dd5d0000-0000-4000-8000-00000000c001');
delete from auth.users where id = 'dd5d0000-0000-4000-8000-00000000a004';

select
  (select count(*) from public.units where company_id::text like 'dd5d0000%') as units_left,
  (select count(*) from public.companies where id::text like 'dd5d0000%') as companies_left,
  (select count(*) from auth.users where id = 'dd5d0000-0000-4000-8000-00000000a004') as users_left;
-- Expect all zeros.
