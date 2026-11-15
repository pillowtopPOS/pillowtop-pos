-- Unit ID S1 real-database check for migration 101.
-- Single paste. Builds throwaway fixtures (names start with "U1CHK"),
-- runs every check, deletes everything it made, ends with ONE select.
-- If a fixture insert fails, the whole run rolls back and leaves nothing.

create temp table res (id serial primary key, test_name text, expected text, actual text, passed boolean);

create or replace function pg_temp.u(x text) returns uuid language sql as
$f$ select ('d1010000-0000-4000-8000-' || lpad(x, 12, '0'))::uuid $f$;

-- try: run one statement as postgres (as_client=false) or as the
-- signed-in "authenticated" role (as_client=true), as the given test user.
create or replace function pg_temp.try(q text, who text, as_client boolean default false)
returns text language plpgsql as
$f$
declare v text;
begin
  perform set_config('request.jwt.claim.sub', pg_temp.u(who)::text, true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', pg_temp.u(who)::text, 'role', 'authenticated')::text, true);
  if as_client then execute 'set local role authenticated'; end if;
  execute q into v;
  if as_client then execute 'reset role'; end if;
  return 'OK:' || coalesce(v, '');
exception when others then
  return 'ERR:' || sqlerrm;
end $f$;

-- s: read-only scalar as postgres, errors returned as text
create or replace function pg_temp.s(q text) returns text language plpgsql as
$f$
declare v text;
begin
  execute q into v;
  return coalesce(v, 'NULL');
exception when others then
  return 'ERR:' || sqlerrm;
end $f$;

create or replace function pg_temp.rec(n text, e text, a text, p boolean) returns void language sql as
$f$ insert into pg_temp.res (test_name, expected, actual, passed) values (n, e, left(a, 160), coalesce(p, false)) $f$;

-- position text "on_hand/committed" for product, location, disposition
create or replace function pg_temp.pos(prod uuid, loc uuid, disp text) returns text language sql as
$f$ select coalesce((select on_hand_quantity || '/' || committed_quantity
  from public.inventory_positions
  where variant_id = prod and location_id = loc and sublocation_id is null
    and disposition = disp::public.disposition), 'none') $f$;

-- mv: move_unit as owner A (so the employee lookup and ledger actor are exercised)
create or replace function pg_temp.mv(unit uuid, to_status text, loc uuid, ctx jsonb default '{}'::jsonb)
returns text language sql as
$f$ select pg_temp.try(format('select public.move_unit(%L, %L, %L, %L)', unit, to_status, loc, ctx), 'a1') $f$;

create or replace function pg_temp.ust(unit uuid) returns text language sql as
$f$ select pg_temp.s(format('select status || '','' || coalesce(assigned_requirement_id::text, ''-'') from public.units where id = %L', unit)) $f$;

-- ---------------------------------------------------------------- fixtures
insert into public.companies (id, name, business_timezone) values
  (pg_temp.u('a'), 'U1CHK Company A', 'America/Denver'),
  (pg_temp.u('b'), 'U1CHK Company B', 'America/Denver');

update public.companies set unit_counter_start = 500 where id = pg_temp.u('a');

insert into public.stores (id, company_id, name, location_type, is_active) values
  (pg_temp.u('11'), pg_temp.u('a'), 'U1CHK Warehouse A', 'WAREHOUSE', true),
  (pg_temp.u('12'), pg_temp.u('a'), 'U1CHK Store A', 'STORE', true),
  (pg_temp.u('13'), pg_temp.u('b'), 'U1CHK Store B', 'STORE', true);

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
  'u1chk-' || s || '@example.com', '', now(), now(), now()
from unnest(array['a1','a2','a3','b1']) s;

insert into public.employees (id, auth_user_id, home_store_id, first_name, last_name, role, is_active) values
  (pg_temp.u('e1'), pg_temp.u('a1'), pg_temp.u('12'), 'Olive', 'OwnerA', 'owner', true),
  (pg_temp.u('e2'), pg_temp.u('a2'), pg_temp.u('12'), 'Ed', 'EmployeeA', 'employee', true),
  (pg_temp.u('e3'), pg_temp.u('a3'), pg_temp.u('12'), 'Addie', 'AdminA', 'admin', true),
  (pg_temp.u('e4'), pg_temp.u('b1'), pg_temp.u('13'), 'Bo', 'OwnerB', 'owner', true);

insert into public.customers (id, first_name, last_name, phone, email, street_address, city, state, zip_code)
values (pg_temp.u('c1'), 'Carl', 'Customer', '555-0101', 'u1chk-carl@example.com', '1 Test St', 'Denver', 'CO', '80202');

insert into public.product_categories (id, company_id, name)
values (pg_temp.u('f1'), pg_temp.u('a'), 'U1CHK Tracked Category');
update public.product_categories set unit_tracked = true where id = pg_temp.u('f1');

insert into public.products (id, company_id, sku, item_name, price) values
  (pg_temp.u('91'), pg_temp.u('a'), 'U1CHK-P1', 'U1CHK Mattress', 999.00),
  (pg_temp.u('92'), pg_temp.u('a'), 'U1CHK-P2', 'U1CHK Mattress Floor', 799.00),
  (pg_temp.u('93'), pg_temp.u('a'), 'U1CHK-P3', 'U1CHK Pillow', 49.00),
  (pg_temp.u('94'), pg_temp.u('a'), 'U1CHK-P4', 'U1CHK Category Product', 500.00),
  (pg_temp.u('95'), pg_temp.u('a'), 'U1CHK-P5', 'U1CHK Opted Out Product', 500.00),
  (pg_temp.u('96'), pg_temp.u('b'), 'U1CHK-PB', 'U1CHK Other Company Mattress', 999.00);
update public.products set unit_tracked = true where id in (pg_temp.u('91'), pg_temp.u('92'), pg_temp.u('96'));
update public.products set category_id = pg_temp.u('f1') where id in (pg_temp.u('94'), pg_temp.u('95'));
update public.products set unit_tracked = false where id = pg_temp.u('95');

insert into public.sleep_journeys (id, store_id, customer_id, current_state, sale_kind) values
  (pg_temp.u('51'), pg_temp.u('12'), pg_temp.u('c1'), 'Sleep Trial', 'STANDARD'),
  (pg_temp.u('52'), pg_temp.u('12'), pg_temp.u('c1'), 'Sleep Trial', 'STANDARD');

insert into public.journey_inventory_requirements (id, journey_id, variant_id, location_id, quantity_required, status) values
  (pg_temp.u('61'), pg_temp.u('51'), pg_temp.u('91'), pg_temp.u('12'), 1, 'ready'),
  (pg_temp.u('62'), pg_temp.u('52'), pg_temp.u('91'), pg_temp.u('12'), 1, 'ready');

-- ------------------------------------------------------------------- tests
do $$
declare
  A uuid := pg_temp.u('a');  B uuid := pg_temp.u('b');
  W uuid := pg_temp.u('11'); S uuid := pg_temp.u('12'); SB uuid := pg_temp.u('13');
  P1 uuid := pg_temp.u('91'); P2 uuid := pg_temp.u('92'); P3 uuid := pg_temp.u('93');
  P4 uuid := pg_temp.u('94'); P5 uuid := pg_temp.u('95'); PB uuid := pg_temp.u('96');
  RQ1 uuid := pg_temp.u('61'); RQ2 uuid := pg_temp.u('62');
  J2 uuid := pg_temp.u('52');
  u1 uuid; u2 uuid; u3 uuid; u4 uuid; u5 uuid; u6 uuid; u7 uuid; u8 uuid; ub uuid;
  r text; r2 text; n text;
begin
  -- ===== A. what the migration installed
  r := pg_temp.s(format('select count(*) from public.role_permission_grants where company_id = %L and permission_key like %L', A, 'units.%'));
  perform pg_temp.rec('A1 new company got 20 default unit grants (trigger)', '20', r, r = '20');

  r := pg_temp.s('select count(*) from public.unit_transitions');
  perform pg_temp.rec('A2 20 transitions seeded', '20', r, r = '20');

  r := pg_temp.s($q$select mirror_owner from public.unit_transitions where from_status='QUARANTINE' and to_status='VOID'$q$);
  perform pg_temp.rec('A3 QUARANTINE to VOID owned by wrapper', 'wrapper', r, r = 'wrapper');

  r := format('%s %s %s %s',
    pg_temp.s(format('select public.is_unit_tracked(%L)', P1)),
    pg_temp.s(format('select public.is_unit_tracked(%L)', P3)),
    pg_temp.s(format('select public.is_unit_tracked(%L)', P4)),
    pg_temp.s(format('select public.is_unit_tracked(%L)', P5)));
  perform pg_temp.rec('A4 tracking flag: product on, none, category inherited, product opted out', 'true false true false', r, r = 'true false true false');

  r := pg_temp.try(format('update public.companies set unit_counter_start = 0 where id = %L', B), 'a1');
  perform pg_temp.rec('A5 counter start of 0 refused', 'check violation', r, r like 'ERR:%check%');

  r := pg_temp.try(format('select public.allocate_unit_number(%L)', pg_temp.u('dead')), 'a1');
  perform pg_temp.rec('A6 allocator refuses an unknown company', 'company was not found', r, r like 'ERR:%company was not found%');

  -- ===== B. creating units
  u1 := public.create_unit(A, P1, S, 'Prime', null, pg_temp.u('e1'));
  u2 := public.create_unit(A, P1, S, 'Prime', null, pg_temp.u('e1'));
  u3 := public.create_unit(A, P1, S, 'Prime', null, pg_temp.u('e1'));
  r := pg_temp.s(format('select string_agg(unit_number::text, %L order by unit_number) from public.units where company_id = %L', ',', A));
  perform pg_temp.rec('B1 numbers start at the company setting and run in order', '500,501,502', r, r = '500,501,502');

  ub := public.create_unit(B, PB, SB, 'Prime', null, pg_temp.u('e4'));
  r := pg_temp.s(format('select unit_number from public.units where id = %L', ub));
  perform pg_temp.rec('B2 other company has its own counter (starts at 1)', '1', r, r = '1');

  r := pg_temp.try(format('select public.create_unit(%L, %L, %L)', A, P3, S), 'a1');
  perform pg_temp.rec('B3 untracked product refused', 'not tracked per unit', r, r like 'ERR:%not tracked per unit%');

  r := pg_temp.try(format('select public.create_unit(%L, %L, %L)', A, P5, S), 'a1');
  perform pg_temp.rec('B4 product opted out of its tracked category refused', 'not tracked per unit', r, r like 'ERR:%not tracked per unit%');

  r := pg_temp.s(format('select count(*) from public.unit_events where unit_id = %L and event_type = %L', u1, 'UNIT_CREATED'));
  perform pg_temp.rec('B5 creation wrote a history row', '1', r, r = '1');

  r := pg_temp.try(format('insert into public.units (company_id, product_id, unit_number) values (%L, %L, 500) returning 1', A, P1), 'a1');
  perform pg_temp.rec('B6 duplicate unit number refused', 'duplicate key', r, r like 'ERR:%duplicate key%');

  r := pg_temp.try(format('delete from public.units where id = %L returning 1', u1), 'a1');
  perform pg_temp.rec('B7 a unit with history cannot be deleted', 'foreign key', r, r like 'ERR:%foreign key%');

  r := pg_temp.try(format('update public.unit_events set event_type = %L where unit_id = %L returning 1', 'X', u1), 'a1');
  r2 := pg_temp.try(format('delete from public.unit_events where unit_id = %L returning 1', u1), 'a1');
  perform pg_temp.rec('B8 history cannot be edited or deleted (even by the database owner)', 'append-only twice', left(r, 40) || ' | ' || left(r2, 40),
    r like 'ERR:%append-only%' and r2 like 'ERR:%append-only%');

  -- ===== C. what the app (signed-in user) can and cannot touch
  r := pg_temp.try(format('select public.create_unit(%L, %L, %L)', A, P1, S), 'a1', true);
  perform pg_temp.rec('C1 signed-in user cannot call create_unit', 'permission denied', r, r like 'ERR:permission denied%');
  r := pg_temp.try(format('select public.move_unit(%L, %L)', u1, 'MISSING'), 'a1', true);
  perform pg_temp.rec('C2 signed-in user cannot call move_unit', 'permission denied', r, r like 'ERR:permission denied%');
  r := pg_temp.try(format('select public.allocate_unit_number(%L)', A), 'a1', true);
  perform pg_temp.rec('C3 signed-in user cannot draw a unit number', 'permission denied', r, r like 'ERR:permission denied%');
  r := pg_temp.try(format('select count(*) from public.check_unit_consistency(%L)', A), 'a1', true);
  perform pg_temp.rec('C4 signed-in user cannot call the raw consistency check', 'permission denied', r, r like 'ERR:permission denied%');
  r := pg_temp.try(format('select public.seed_unit_permission_defaults(%L)::text', A), 'a1', true);
  perform pg_temp.rec('C5 signed-in user cannot re-seed grants', 'permission denied', r, r like 'ERR:permission denied%');

  r := pg_temp.try(format('with x as (insert into public.units (company_id, product_id, unit_number) values (%L, %L, 9001) returning 1) select count(*) from x', A, P1), 'a1', true);
  perform pg_temp.rec('C6 signed-in user cannot insert a unit', 'blocked', r, r like 'ERR:%');
  r := pg_temp.try(format('with x as (update public.units set status = %L where company_id = %L returning 1) select count(*) from x', 'VOID', A), 'a1', true);
  perform pg_temp.rec('C7 signed-in user cannot update units (0 rows or denied)', 'OK:0 or denied', r, r = 'OK:0' or r like 'ERR:permission denied%');
  r := pg_temp.try(format('with x as (delete from public.units where company_id = %L returning 1) select count(*) from x', A), 'a1', true);
  perform pg_temp.rec('C8 signed-in user cannot delete units (0 rows or denied)', 'OK:0 or denied', r, r = 'OK:0' or r like 'ERR:%');
  r := pg_temp.try(format('with x as (update public.unit_events set event_type = %L where company_id = %L returning 1) select count(*) from x', 'X', A), 'a1', true);
  perform pg_temp.rec('C9 signed-in user cannot update history (0 rows or denied)', 'OK:0 or denied', r, r = 'OK:0' or r like 'ERR:%');
  r := pg_temp.try(format('with x as (insert into public.unit_events (unit_id, company_id, event_type) values (%L, %L, %L) returning 1) select count(*) from x', u1, A, 'FAKE'), 'a1', true);
  perform pg_temp.rec('C10 signed-in user cannot write history', 'blocked', r, r like 'ERR:%');
  r := pg_temp.try('with x as (insert into public.unit_transitions (from_status, to_status) values (''STOCK'', ''DELIVERED'') returning 1) select count(*) from x', 'a1', true);
  perform pg_temp.rec('C11 signed-in user cannot add transitions', 'blocked', r, r like 'ERR:%');
  r := pg_temp.try('select count(*) from public.unit_counters', 'a1', true);
  perform pg_temp.rec('C12 signed-in user cannot read counters (0 rows or denied)', 'OK:0 or denied', r, r = 'OK:0' or r like 'ERR:permission denied%');

  -- ===== D. who can see what
  r := pg_temp.try(format('select count(*) from public.units where company_id = %L', A), 'a1', true);
  perform pg_temp.rec('D1 company A owner sees A units', 'OK:3', r, r = 'OK:3');
  r := pg_temp.try(format('select count(*) from public.units where company_id = %L', A), 'b1', true);
  perform pg_temp.rec('D2 company B owner sees no A units', 'OK:0', r, r = 'OK:0');
  r := pg_temp.try(format('select count(*) from public.unit_events where company_id = %L', A), 'b1', true);
  perform pg_temp.rec('D3 company B owner sees no A history', 'OK:0', r, r = 'OK:0');
  r := pg_temp.try(format('select count(*) from public.units where company_id = %L', B), 'b1', true);
  perform pg_temp.rec('D4 company B owner sees B units', 'OK:1', r, r = 'OK:1');
  r := pg_temp.try('select count(*) from public.unit_transitions', 'a2', true);
  perform pg_temp.rec('D5 any employee can read the transition rules', 'OK:20', r, r = 'OK:20');

  -- ===== E. drift check
  r := pg_temp.s(format('select units_on_hand || ''/'' || mirror_on_hand from public.check_unit_consistency(%L) where product_id = %L', A, P1));
  perform pg_temp.rec('E1 units without a stock mirror are reported', '3/0', r, r = '3/0');

  insert into public.inventory_positions (variant_id, location_id, sublocation_id, disposition, on_hand_quantity, committed_quantity)
  values (P1, S, null, 'Prime', 3, 0), (P3, S, null, 'Prime', 5, 0);
  r := pg_temp.s(format('select count(*) from public.check_unit_consistency(%L) where product_id = %L', A, P1));
  perform pg_temp.rec('E2 mirror matches units: clean', '0', r, r = '0');
  r := pg_temp.s(format('select count(*) from public.check_unit_consistency(%L) where product_id = %L', A, P3));
  perform pg_temp.rec('E3 untracked product never appears', '0', r, r = '0');

  -- company B has a tracked product with stock; A must never see it
  insert into public.inventory_positions (variant_id, location_id, sublocation_id, disposition, on_hand_quantity, committed_quantity)
  values (PB, SB, null, 'Prime', 7, 0);
  r := pg_temp.try(format('select count(*) from public.get_unit_discrepancies(%L) where product_id = %L', A, PB), 'a1', true);
  perform pg_temp.rec('E4 company A report never shows company B stock', 'OK:0', r, r = 'OK:0');

  r := pg_temp.try(format('select count(*) from public.get_unit_discrepancies(%L)', A), 'a1', true);
  perform pg_temp.rec('E5 owner can run the discrepancy report', 'OK', r, r like 'OK:%');
  r := pg_temp.try(format('select count(*) from public.get_unit_discrepancies(%L)', A), 'a3', true);
  perform pg_temp.rec('E6 admin can run it (default grant works)', 'OK', r, r like 'OK:%');
  r := pg_temp.try(format('select count(*) from public.get_unit_discrepancies(%L)', A), 'a2', true);
  perform pg_temp.rec('E7 plain employee refused', 'no permission', r, r like 'ERR:%do not have permission%');
  r := pg_temp.try(format('select count(*) from public.get_unit_discrepancies(%L)', B), 'a1', true);
  perform pg_temp.rec('E8 A owner asking for B refused', 'not yours', r, r like 'ERR:%not yours%');
  r := pg_temp.try(format('select count(*) from public.get_unit_discrepancies(%L)', A), 'b1', true);
  perform pg_temp.rec('E9 B owner asking for A refused', 'not yours', r, r like 'ERR:%not yours%');

  -- ===== F. moves that own their stock effect
  r := pg_temp.mv(u1, 'MISSING', null);
  perform pg_temp.rec('F1 STOCK to MISSING works', 'OK', r, r like 'OK:%');
  r := pg_temp.pos(P1, S, 'Prime') || ' ' || pg_temp.s(format('select count(*) from public.stock_ledger_entries where variant_id = %L and reason = %L and quantity_delta = -1', P1, 'unit_missing'));
  perform pg_temp.rec('F2 missing takes 1 off stock and writes a ledger row', '2/0 1', r, r = '2/0 1');
  r := pg_temp.mv(u1, 'STOCK', null);
  r2 := pg_temp.pos(P1, S, 'Prime') || ' ' || pg_temp.s(format('select count(*) from public.stock_ledger_entries where variant_id = %L and reason = %L and quantity_delta = 1', P1, 'unit_found'));
  perform pg_temp.rec('F3 found puts it back and writes a ledger row', 'OK, 3/0 1', left(r, 3) || ', ' || r2, r like 'OK:%' and r2 = '3/0 1');

  u4 := public.create_unit(A, P1, S, 'Prime', null, pg_temp.u('e1'));
  update public.inventory_positions set on_hand_quantity = 4 where variant_id = P1 and location_id = S and disposition = 'Prime';
  r := pg_temp.mv(u4, 'VOID', null, '{"reason":"u1chk void"}'::jsonb);
  r2 := pg_temp.s(format('select status || '','' || (voided_at is not null)::text || '','' || coalesce(void_reason, ''-'') || '','' || (voided_by = %L)::text from public.units where id = %L', pg_temp.u('e1'), u4));
  perform pg_temp.rec('F4 void records who, when, why and takes 1 off stock', 'OK, VOID,true,u1chk void,true, 3/0', left(r, 3) || ', ' || r2 || ', ' || pg_temp.pos(P1, S, 'Prime'),
    r like 'OK:%' and r2 = 'VOID,true,u1chk void,true' and pg_temp.pos(P1, S, 'Prime') = '3/0');
  r := pg_temp.s(format('select count(*) from public.check_unit_consistency(%L) where product_id = %L', A, P1));
  perform pg_temp.rec('F5 after move, missing and void the mirror is still clean', '0', r, r = '0');

  r := pg_temp.mv(u4, 'STOCK', null);
  perform pg_temp.rec('F6 a voided unit can never come back', 'cannot move from VOID', r, r like 'ERR:%cannot move from VOID to STOCK%');
  r := pg_temp.mv(u2, 'DELIVERED', null);
  perform pg_temp.rec('F7 STOCK straight to DELIVERED refused', 'cannot move', r, r like 'ERR:%cannot move from STOCK to DELIVERED%');

  update public.inventory_positions set on_hand_quantity = 0 where variant_id = P1 and location_id = S and disposition = 'Prime';
  r := pg_temp.mv(u2, 'MISSING', null);
  r2 := pg_temp.ust(u2);
  update public.inventory_positions set on_hand_quantity = 3 where variant_id = P1 and location_id = S and disposition = 'Prime';
  perform pg_temp.rec('F8 cannot remove stock the mirror does not have; unit unchanged', 'refused, STOCK', left(r, 60) || ', ' || r2,
    r like 'ERR:%mirror does not have%' and r2 like 'STOCK,%');

  -- ===== G. reserving, shipping, staging, delivering
  r := pg_temp.mv(u2, 'RESERVED', null);
  perform pg_temp.rec('G1 reserving without a requirement refused', 'requires the requirement', r, r like 'ERR:%requires the requirement%');
  r := pg_temp.mv(u2, 'RESERVED', null, jsonb_build_object('requirement_id', RQ1));
  r2 := pg_temp.ust(u2);
  perform pg_temp.rec('G2 reserving with a requirement works and remembers it', 'OK, RESERVED,<RQ1>', left(r, 3) || ', ' || r2, r like 'OK:%' and r2 = 'RESERVED,' || RQ1::text);
  r := pg_temp.mv(u3, 'RESERVED', null, jsonb_build_object('requirement_id', RQ1));
  perform pg_temp.rec('G3 a second unit cannot take the same requirement', 'duplicate key', r, r like 'ERR:%duplicate key%');
  r := pg_temp.pos(P1, S, 'Prime');
  perform pg_temp.rec('G4 reserving does not touch stock (existing code owns that)', '3/0', r, r = '3/0');

  r := pg_temp.mv(u2, 'IN_TRANSIT', null);
  r2 := pg_temp.ust(u2);
  perform pg_temp.rec('G5 shipping keeps the assignment', 'OK, IN_TRANSIT,<RQ1>', left(r, 3) || ', ' || r2, r like 'OK:%' and r2 = 'IN_TRANSIT,' || RQ1::text);
  r := pg_temp.mv(u2, 'RESERVED', null);
  r2 := pg_temp.ust(u2);
  perform pg_temp.rec('G6 arriving keeps the assignment (no need to re-pass it)', 'OK, RESERVED,<RQ1>', left(r, 3) || ', ' || r2, r like 'OK:%' and r2 = 'RESERVED,' || RQ1::text);
  r := pg_temp.mv(u2, 'STAGED', null);
  r2 := pg_temp.mv(u2, 'RESERVED', null);
  n := pg_temp.ust(u2);
  perform pg_temp.rec('G7 staging and un-staging keep the assignment', 'OK, OK, RESERVED,<RQ1>', left(r, 3) || ', ' || left(r2, 3) || ', ' || n,
    r like 'OK:%' and r2 like 'OK:%' and n = 'RESERVED,' || RQ1::text);
  r := pg_temp.mv(u2, 'STOCK', null);
  r2 := pg_temp.ust(u2);
  perform pg_temp.rec('G8 un-assigning clears the assignment', 'OK, STOCK,-', left(r, 3) || ', ' || r2, r like 'OK:%' and r2 = 'STOCK,-');

  r := pg_temp.mv(u3, 'IN_TRANSIT', null);
  r2 := pg_temp.mv(u3, 'STOCK', null);
  perform pg_temp.rec('G9 an unassigned unit can ship and come back', 'OK, OK, STOCK,-', left(r, 3) || ', ' || left(r2, 3) || ', ' || pg_temp.ust(u3),
    r like 'OK:%' and r2 like 'OK:%' and pg_temp.ust(u3) = 'STOCK,-');

  u5 := public.create_unit(A, P1, S, 'Prime', null, pg_temp.u('e1'));
  update public.inventory_positions set on_hand_quantity = 4 where variant_id = P1 and location_id = S and disposition = 'Prime';
  r := pg_temp.mv(u5, 'RESERVED', null, jsonb_build_object('requirement_id', RQ2));
  r2 := pg_temp.mv(u5, 'DELIVERED', null, jsonb_build_object('journey_id', J2));
  n := pg_temp.s(format('select status || '','' || coalesce(assigned_requirement_id::text, ''-'') || '','' || (delivered_journey_id = %L)::text from public.units where id = %L', J2, u5));
  perform pg_temp.rec('G10 delivery clears the assignment and records the journey', 'DELIVERED,-,true', n, n = 'DELIVERED,-,true');
  r := pg_temp.mv(u5, 'RETURNED', null);
  r2 := pg_temp.mv(u5, 'QUARANTINE', null);
  perform pg_temp.rec('G11 delivered unit can be returned then quarantined', 'OK, OK, QUARANTINE', left(r, 3) || ', ' || left(r2, 3) || ', ' || pg_temp.ust(u5),
    r like 'OK:%' and r2 like 'OK:%' and pg_temp.ust(u5) like 'QUARANTINE,%');
  -- put stock back in step with the units so later checks stay readable
  update public.inventory_positions set on_hand_quantity = 3 where variant_id = P1 and location_id = S and disposition = 'Prime';
  update public.units set status = 'VOID', voided_at = now() where id = u5;

  -- ===== H. changing a unit's version or condition (two-leg moves)
  insert into public.inventory_positions (variant_id, location_id, sublocation_id, disposition, on_hand_quantity, committed_quantity)
  values (P2, S, null, 'Prime', 0, 0);
  r := pg_temp.mv(u3, 'STOCK', null, jsonb_build_object('new_product_id', P2));
  perform pg_temp.rec('H1 moving a unit to another version works', 'OK', r, r like 'OK:%');
  r := pg_temp.pos(P1, S, 'Prime') || ' ' || pg_temp.pos(P2, S, 'Prime');
  perform pg_temp.rec('H2 old version loses 1, new version gains 1', '2/0 1/0', r, r = '2/0 1/0');
  r := pg_temp.s(format('select count(*) || '','' || sum(quantity_delta) from public.stock_ledger_entries where correlation_id = %L and reason = %L', u3, 'unit_reclassified'));
  perform pg_temp.rec('H3 two ledger rows that net to zero', '2,0', r, r = '2,0');
  r := pg_temp.s(format('select product_id = %L from public.units where id = %L', P2, u3));
  perform pg_temp.rec('H4 the unit now belongs to the new version', 'true', r, r = 'true');

  r := pg_temp.mv(u1, 'STOCK', null, jsonb_build_object('new_disposition', 'Display'));
  r2 := pg_temp.pos(P1, S, 'Prime') || ' ' || pg_temp.pos(P1, S, 'Display');
  perform pg_temp.rec('H5 changing condition moves stock between condition buckets', 'OK, 1/0 1/0', left(r, 3) || ', ' || r2, r like 'OK:%' and r2 = '1/0 1/0');

  r := pg_temp.mv(u2, 'STOCK', null);
  perform pg_temp.rec('H6 a move that changes nothing is refused', 'Nothing changed', r, r like 'ERR:%Nothing changed%');
  r := pg_temp.mv(u2, 'STOCK', null, jsonb_build_object('new_product_id', PB));
  perform pg_temp.rec('H7 cannot move a unit to another company''s product', 'does not exist in this company', r, r like 'ERR:%does not exist in this company%');
  r := pg_temp.mv(u2, 'STOCK', null, jsonb_build_object('new_product_id', P3));
  perform pg_temp.rec('H8 cannot move a unit to an untracked product', 'not tracked per unit', r, r like 'ERR:%not tracked per unit%');
  r := pg_temp.mv(u2, 'MISSING', null, jsonb_build_object('new_disposition', 'Floor'));
  perform pg_temp.rec('H9 condition cannot change inside an ordinary move', 'can only change in a relocation', r, r like 'ERR:%can only change in a relocation%');

  update public.inventory_positions set on_hand_quantity = 0 where variant_id = P1 and location_id = S and disposition = 'Prime';
  r := pg_temp.mv(u2, 'STOCK', null, jsonb_build_object('new_product_id', P2));
  update public.inventory_positions set on_hand_quantity = 1 where variant_id = P1 and location_id = S and disposition = 'Prime';
  perform pg_temp.rec('H10 a version change cannot take stock the mirror does not have', 'mirror does not have', r, r like 'ERR:%mirror does not have%');

  -- ===== I. returned and damaged stock never quietly turns Prime
  u6 := public.create_unit(A, P1, W, 'Returned', null, pg_temp.u('e1'));
  update public.units set status = 'QUARANTINE' where id = u6;
  insert into public.inventory_positions (variant_id, location_id, sublocation_id, disposition, on_hand_quantity, committed_quantity)
  values (P1, W, null, 'Returned', 1, 0);
  r := pg_temp.mv(u6, 'STOCK', null, '{"new_disposition":"Prime"}'::jsonb);
  perform pg_temp.rec('I1 returned unit to Prime without an inspection refused', 'finished inspection', r, r like 'ERR:%finished inspection%');
  r := pg_temp.mv(u6, 'STOCK', null, '{"new_disposition":"Prime","authorized_by":"inspection_finish"}'::jsonb);
  r2 := pg_temp.pos(P1, W, 'Returned') || ' ' || pg_temp.pos(P1, W, 'Prime');
  perform pg_temp.rec('I2 with a finished inspection it works and moves the stock', 'OK, 0/0 1/0', left(r, 3) || ', ' || r2, r like 'OK:%' and r2 = '0/0 1/0');
  r := pg_temp.s(format('select data ->> %L from public.unit_events where unit_id = %L and data ? %L limit 1', 'authorized_by', u6, 'authorized_by'));
  perform pg_temp.rec('I3 the history records the inspection authorization', 'inspection_finish', r, r = 'inspection_finish');

  u7 := public.create_unit(A, P1, W, 'Damaged', null, pg_temp.u('e1'));
  update public.units set status = 'DAMAGED' where id = u7;
  insert into public.inventory_positions (variant_id, location_id, sublocation_id, disposition, on_hand_quantity, committed_quantity)
  values (P1, W, null, 'Damaged', 1, 0);
  r := pg_temp.mv(u7, 'STOCK', null, '{"new_disposition":"Prime"}'::jsonb);
  perform pg_temp.rec('I4 damaged unit to Prime without an inspection refused', 'finished inspection', r, r like 'ERR:%finished inspection%');

  u8 := public.create_unit(A, P1, W, 'Returned', null, pg_temp.u('e1'));
  update public.units set status = 'MISSING' where id = u8;
  r := pg_temp.mv(u8, 'STOCK', null, '{"new_disposition":"Prime"}'::jsonb);
  perform pg_temp.rec('I5 "found" cannot be used to sneak a returned unit to Prime', 'can only change in a relocation', r, r like 'ERR:%can only change in a relocation%');
  r := pg_temp.mv(u8, 'STOCK', null);
  r2 := pg_temp.s(format('select disposition::text from public.units where id = %L', u8));
  perform pg_temp.rec('I6 found returned unit stays Returned', 'OK, Returned', left(r, 3) || ', ' || r2, r like 'OK:%' and r2 = 'Returned');

  -- ===== J. permissions end to end
  r := pg_temp.try(format('select public.has_permission(%L)::text', 'units.assign'), 'a2', true);
  r2 := pg_temp.try(format('select public.has_permission(%L)::text', 'units.manage_settings'), 'a2', true);
  perform pg_temp.rec('J1 employee has units.assign but not units.manage_settings by default', 'true, false', replace(r, 'OK:', '') || ', ' || replace(r2, 'OK:', ''), r = 'OK:true' and r2 = 'OK:false');

  r := pg_temp.try(format('select public.set_role_permission(%L, %L, true)::text', 'employee', 'units.void'), 'a1', true);
  r2 := pg_temp.try(format('select public.has_permission(%L)::text', 'units.void'), 'a2', true);
  perform pg_temp.rec('J2 owner can grant a units.* key and it takes effect', 'OK, true', left(r, 3) || ', ' || replace(r2, 'OK:', ''), r like 'OK:%' and r2 = 'OK:true');
  r := pg_temp.try(format('select public.set_role_permission(%L, %L, false)::text', 'employee', 'units.void'), 'a1', true);
  r2 := pg_temp.try(format('select public.has_permission(%L)::text', 'units.void'), 'a2', true);
  perform pg_temp.rec('J3 owner can take it back', 'OK, false', left(r, 3) || ', ' || replace(r2, 'OK:', ''), r like 'OK:%' and r2 = 'OK:false');
  r := pg_temp.try(format('select public.set_role_permission(%L, %L, true)::text', 'employee', 'units.bogus'), 'a1', true);
  perform pg_temp.rec('J4 made-up key still refused', 'Unknown permission key', r, r like 'ERR:%Unknown permission key%');
  r := pg_temp.try(format('select public.set_role_permission(%L, %L, true)::text', 'employee', 'units.void'), 'a2', true);
  perform pg_temp.rec('J5 plain employee cannot change permissions', 'Only owners and admins', r, r like 'ERR:%Only owners and admins%');

  -- ===== K. history
  r := pg_temp.s(format('select string_agg(event_type, %L order by event_type) from public.unit_events where unit_id = %L', ',', u1));
  perform pg_temp.rec('K1 unit history is complete', 'UNIT_CREATED,UNIT_MOVED,UNIT_MOVED,UNIT_MOVED', r, r = 'UNIT_CREATED,UNIT_MOVED,UNIT_MOVED,UNIT_MOVED');
end $$;

create temp table res_out as select * from pg_temp.res;

-- ---------------------------------------------------------------- teardown
alter table public.unit_events disable trigger trg_unit_events_no_update;
alter table public.unit_events disable trigger trg_unit_events_no_delete;
delete from public.unit_events where company_id in (pg_temp.u('a'), pg_temp.u('b'));
alter table public.unit_events enable trigger trg_unit_events_no_update;
alter table public.unit_events enable trigger trg_unit_events_no_delete;

delete from public.units where company_id in (pg_temp.u('a'), pg_temp.u('b'));
delete from public.unit_counters where company_id in (pg_temp.u('a'), pg_temp.u('b'));
delete from public.stock_ledger_entries where variant_id in (pg_temp.u('91'), pg_temp.u('92'), pg_temp.u('93'), pg_temp.u('94'), pg_temp.u('95'), pg_temp.u('96'));
delete from public.inventory_positions where variant_id in (pg_temp.u('91'), pg_temp.u('92'), pg_temp.u('93'), pg_temp.u('94'), pg_temp.u('95'), pg_temp.u('96'));
delete from public.journey_inventory_requirements where id in (pg_temp.u('61'), pg_temp.u('62'));
delete from public.journey_interactions where journey_id in (pg_temp.u('51'), pg_temp.u('52'));
delete from public.journey_events where journey_id in (pg_temp.u('51'), pg_temp.u('52'));
delete from public.audit_events where company_id in (pg_temp.u('a'), pg_temp.u('b'));
delete from public.sleep_journeys where id in (pg_temp.u('51'), pg_temp.u('52'));
delete from public.customers where id = pg_temp.u('c1');
delete from public.products where id in (pg_temp.u('91'), pg_temp.u('92'), pg_temp.u('93'), pg_temp.u('94'), pg_temp.u('95'), pg_temp.u('96'));
delete from public.product_categories where id = pg_temp.u('f1');
delete from public.employees where id in (pg_temp.u('e1'), pg_temp.u('e2'), pg_temp.u('e3'), pg_temp.u('e4'));
delete from public.role_permission_grants where company_id in (pg_temp.u('a'), pg_temp.u('b'));
delete from public.stores where company_id in (pg_temp.u('a'), pg_temp.u('b'));
delete from public.companies where id in (pg_temp.u('a'), pg_temp.u('b'));
delete from auth.users where id in (pg_temp.u('a1'), pg_temp.u('a2'), pg_temp.u('a3'), pg_temp.u('b1'));

-- ---------------------------------------------------------- the one select
select
  r.id, r.test_name, r.passed, case when r.passed then '' else r.actual end as actual_if_failed,
  (select count(*) from res_out where not passed) as total_failed,
  (select count(*) from res_out) as total_tests,
  (select count(*) from public.companies where name like 'U1CHK%')
  + (select count(*) from public.stores where name like 'U1CHK%')
  + (select count(*) from public.units where company_id::text like 'd1010000-%')
  + (select count(*) from public.unit_events where company_id::text like 'd1010000-%')
  + (select count(*) from public.unit_counters where company_id::text like 'd1010000-%')
  + (select count(*) from public.products where sku like 'U1CHK%')
  + (select count(*) from auth.users where email like 'u1chk-%') as leftovers
from res_out r
order by r.id;
