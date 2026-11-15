-- PERM-1 real-database check for migrations 104 and 105.
-- Single paste. Builds throwaway fixtures (names start with "P1CHK"),
-- runs every check, deletes everything it made, ends with ONE select.
-- If a fixture insert fails, the whole run rolls back and leaves nothing.

create temp table res (id serial primary key, test_name text, expected text, actual text, passed boolean);

create or replace function pg_temp.u(x text) returns uuid language sql as
$f$ select ('d1040000-0000-4000-8000-' || lpad(x, 12, '0'))::uuid $f$;

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

-- has_permission as a signed-in user
create or replace function pg_temp.hp(who text, k text) returns text language sql as
$f$ select replace(pg_temp.try(format('select public.has_permission(%L)::text', k), who, true), 'OK:', '') $f$;

-- set_employee_permission as a signed-in user. val: 'true' | 'false' | 'null'
create or replace function pg_temp.sep(actor text, target text, k text, val text) returns text language sql as
$f$ select pg_temp.try(format('select public.set_employee_permission(%L, %L, %s)::text', pg_temp.u(target), k, val), actor, true) $f$;

-- ---------------------------------------------------------------- fixtures
insert into public.companies (id, name, business_timezone) values
  (pg_temp.u('a'), 'P1CHK Company A', 'America/Denver'),
  (pg_temp.u('b'), 'P1CHK Company B', 'America/Denver');

insert into public.stores (id, company_id, name, location_type, is_active) values
  (pg_temp.u('11'), pg_temp.u('a'), 'P1CHK Warehouse A', 'WAREHOUSE', true),
  (pg_temp.u('12'), pg_temp.u('a'), 'P1CHK Store A', 'STORE', true),
  (pg_temp.u('13'), pg_temp.u('b'), 'P1CHK Store B', 'STORE', true);

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
  'p1chk-' || s || '@example.com', '', now(), now(), now()
from unnest(array['a1','a2','a3','a4','a5','b1','b2']) s;

-- a1 owner A, a2 admin A, a3 manager A, a4 employee X (warehouse), a5 employee Y (warehouse), b1 owner B, b2 admin B
insert into public.employees (id, auth_user_id, home_store_id, first_name, last_name, role, is_active) values
  (pg_temp.u('e1'), pg_temp.u('a1'), pg_temp.u('12'), 'Olive', 'OwnerA', 'owner', true),
  (pg_temp.u('e2'), pg_temp.u('a2'), pg_temp.u('12'), 'Addie', 'AdminA', 'admin', true),
  (pg_temp.u('e3'), pg_temp.u('a3'), pg_temp.u('12'), 'Manny', 'ManagerA', 'manager', true),
  (pg_temp.u('e4'), pg_temp.u('a4'), pg_temp.u('11'), 'Xavier', 'EmployeeX', 'employee', true),
  (pg_temp.u('e5'), pg_temp.u('a5'), pg_temp.u('11'), 'Yara', 'EmployeeY', 'employee', true),
  (pg_temp.u('e6'), pg_temp.u('b1'), pg_temp.u('13'), 'Bo', 'OwnerB', 'owner', true),
  (pg_temp.u('e7'), pg_temp.u('b2'), pg_temp.u('13'), 'Bea', 'AdminB', 'admin', true);

insert into public.products (id, company_id, sku, item_name, price)
values (pg_temp.u('91'), pg_temp.u('a'), 'P1CHK-P1', 'P1CHK Mattress', 999.00);

insert into public.purchase_orders (id, vendor_name, destination_location_id, status, created_by)
values (pg_temp.u('a1a'), 'P1CHK Vendor', pg_temp.u('11'), 'draft', pg_temp.u('e3'));
insert into public.purchase_order_line_items (id, purchase_order_id, variant_id, quantity_ordered, unit_cost)
values (pg_temp.u('a1b'), pg_temp.u('a1a'), pg_temp.u('91'), 10, 100);
update public.purchase_orders set status = 'submitted', submitted_at = now() where id = pg_temp.u('a1a');

-- ------------------------------------------------------------------- tests
do $$
declare
  A uuid := pg_temp.u('a'); B uuid := pg_temp.u('b');
  X uuid := pg_temp.u('e4'); Y uuid := pg_temp.u('e5'); MGR uuid := pg_temp.u('e3');
  OWN uuid := pg_temp.u('e1'); WH uuid := pg_temp.u('11'); P1 uuid := pg_temp.u('91');
  LINE uuid := pg_temp.u('a1b');
  r text; r2 text; n text;
begin
  -- ===== A. installed pieces
  r := format('%s %s %s',
    pg_temp.s('select public.is_valid_permission_key(''inventory.receive_po'')'),
    pg_temp.s('select public.is_valid_permission_key(''units.swap'')'),
    pg_temp.s('select public.is_valid_permission_key(''bogus.key'')'));
  perform pg_temp.rec('A1 key list: receive_po ok, units.swap ok, bogus refused', 'true true false', r, r = 'true true false');

  r := pg_temp.s(format('select string_agg(role, %L order by role) from public.role_permission_grants where company_id = %L and permission_key = %L', ',', A, 'inventory.receive_po'));
  perform pg_temp.rec('A2 new company got receive_po for admin, manager, owner only (trigger)', 'admin,manager,owner', r, r = 'admin,manager,owner');

  -- ===== B. the role-vs-override matrix
  r := pg_temp.hp('a4', 'inventory.receive_po');
  perform pg_temp.rec('B1 employee X has no receive_po by default', 'false', r, r = 'false');

  r := pg_temp.sep('a2', 'e4', 'inventory.receive_po', 'true');
  r2 := pg_temp.hp('a4', 'inventory.receive_po') || ' ' || pg_temp.hp('a5', 'inventory.receive_po');
  perform pg_temp.rec('B2 admin grants X receive_po: X yes, Y still no', 'OK, true false', left(r, 3) || ', ' || r2, r like 'OK:%' and r2 = 'true false');

  r := pg_temp.hp('a4', 'units.assign') || ' ' || pg_temp.hp('a5', 'units.assign');
  perform pg_temp.rec('B3 baseline: both employees have units.assign from the role', 'true true', r, r = 'true true');
  r := pg_temp.sep('a2', 'e4', 'units.assign', 'false');
  r2 := pg_temp.hp('a4', 'units.assign') || ' ' || pg_temp.hp('a5', 'units.assign');
  perform pg_temp.rec('B4 deny beats the role grant for X only', 'OK, false true', left(r, 3) || ', ' || r2, r like 'OK:%' and r2 = 'false true');

  r := pg_temp.sep('a2', 'e4', 'units.assign', 'null');
  r2 := pg_temp.sep('a2', 'e4', 'inventory.receive_po', 'null');
  n := pg_temp.hp('a4', 'units.assign') || ' ' || pg_temp.hp('a4', 'inventory.receive_po');
  perform pg_temp.rec('B5 clearing overrides returns X to the role defaults', 'true false', n, n = 'true false' and r like 'OK:%' and r2 like 'OK:%');

  r := pg_temp.sep('a1', 'e3', 'inventory.receive_po', 'false');
  r2 := pg_temp.hp('a3', 'inventory.receive_po');
  n := pg_temp.sep('a1', 'e3', 'inventory.receive_po', 'null');
  perform pg_temp.rec('B6 deny works on a manager too, and clears back to true', 'false then true', r2 || ' then ' || pg_temp.hp('a3', 'inventory.receive_po'), r2 = 'false' and pg_temp.hp('a3', 'inventory.receive_po') = 'true');

  r := pg_temp.hp('a1', 'units.void') || ' ' || pg_temp.hp('a1', 'sleep_trial.manage_policy');
  perform pg_temp.rec('B7 owner always has everything', 'true true', r, r = 'true true');

  r := pg_temp.sep('a2', 'e1', 'units.void', 'false');
  perform pg_temp.rec('B8 cannot put an override on an owner', 'Owners always have every permission', r, r like 'ERR:%Owners always have every permission%');

  r := pg_temp.sep('a3', 'e4', 'units.swap', 'true');
  r2 := pg_temp.sep('a4', 'e5', 'units.swap', 'true');
  perform pg_temp.rec('B9 manager and employee cannot set overrides', 'Only owners and admins x2', left(r, 50) || ' | ' || left(r2, 50),
    r like 'ERR:%Only owners and admins%' and r2 like 'ERR:%Only owners and admins%');

  r := pg_temp.sep('a2', 'e4', 'bogus.key', 'true');
  perform pg_temp.rec('B10 unknown key refused', 'Unknown permission key', r, r like 'ERR:%Unknown permission key%');

  r := pg_temp.sep('a2', 'dead', 'units.swap', 'true');
  perform pg_temp.rec('B11 nonexistent employee refused', 'not in your company', r, r like 'ERR:%not in your company%');

  r := pg_temp.sep('b2', 'e4', 'units.swap', 'true');
  perform pg_temp.rec('B12 admin of company B cannot touch company A employee', 'not in your company', r, r like 'ERR:%not in your company%');
  r := pg_temp.sep('a2', 'e6', 'units.swap', 'true');
  perform pg_temp.rec('B13 admin of company A cannot touch company B employee', 'not in your company', r, r like 'ERR:%not in your company%');

  -- audit trail
  perform pg_temp.sep('a2', 'e5', 'units.swap', 'true');
  perform pg_temp.sep('a2', 'e5', 'units.swap', 'true');
  r := pg_temp.s(format('select count(*) from public.audit_events where company_id = %L and event_type = %L and (after ->> %L) = %L', A, 'EMPLOYEE_PERMISSION_GRANTED', 'permission_key', 'units.swap'));
  perform pg_temp.rec('B14 granting the same thing twice audits once', '1', r, r = '1');
  perform pg_temp.sep('a2', 'e5', 'units.swap', 'null');
  perform pg_temp.sep('a2', 'e5', 'units.swap', 'null');
  r := pg_temp.s(format('select count(*) from public.audit_events where company_id = %L and event_type = %L', A, 'EMPLOYEE_PERMISSION_CLEARED'));
  r2 := pg_temp.s(format('select count(*) from public.audit_events where company_id = %L and event_type = %L', A, 'EMPLOYEE_PERMISSION_DENIED'));
  perform pg_temp.rec('B15 clear audits once per real change; deny was audited', 'cleared 3 (swap, assign, receive) incl. manager; denied 2', 'cleared ' || r || ', denied ' || r2,
    r = '4' and r2 = '2');

  -- ===== C. who can read and write the overrides table
  perform pg_temp.sep('a2', 'e4', 'inventory.receive_po', 'true');
  r := pg_temp.try(format('select count(*) from public.employee_permission_overrides where employee_id = %L', X), 'a4', true);
  perform pg_temp.rec('C1 employee X can read their own override', 'OK:1', r, r = 'OK:1');
  r := pg_temp.try(format('select count(*) from public.employee_permission_overrides where employee_id = %L', X), 'a5', true);
  perform pg_temp.rec('C2 employee Y cannot read X''s overrides', 'OK:0', r, r = 'OK:0');
  r := pg_temp.try(format('select count(*) from public.employee_permission_overrides where employee_id = %L', X), 'a3', true);
  perform pg_temp.rec('C3 a manager cannot read others'' overrides', 'OK:0', r, r = 'OK:0');
  r := pg_temp.try(format('select count(*) from public.employee_permission_overrides where employee_id = %L', X), 'a2', true);
  perform pg_temp.rec('C4 admin of the same company can read them', 'OK:1', r, r = 'OK:1');
  r := pg_temp.try(format('select count(*) from public.employee_permission_overrides where company_id = %L', A), 'b2', true);
  r2 := pg_temp.try(format('select count(*) from public.employee_permission_overrides where company_id = %L', A), 'b1', true);
  perform pg_temp.rec('C5 company B admin and owner cannot read company A overrides', 'OK:0 and OK:0', r || ' and ' || r2, r = 'OK:0' and r2 = 'OK:0');
  r := pg_temp.try(format('with x as (insert into public.employee_permission_overrides (company_id, employee_id, permission_key, granted) values (%L, %L, %L, true) returning 1) select count(*) from x', A, Y, 'units.void'), 'a2', true);
  perform pg_temp.rec('C6 even an admin cannot write the table directly', 'blocked', r, r like 'ERR:%');
  r := pg_temp.try(format('with x as (update public.employee_permission_overrides set granted = false where employee_id = %L returning 1) select count(*) from x', X), 'a2', true);
  r2 := pg_temp.try(format('with x as (delete from public.employee_permission_overrides where employee_id = %L returning 1) select count(*) from x', X), 'a2', true);
  perform pg_temp.rec('C7 direct update and delete do nothing (0 rows or denied)', 'OK:0 / OK:0', r || ' / ' || r2,
    (r = 'OK:0' or r like 'ERR:permission denied%') and (r2 = 'OK:0' or r2 like 'ERR:permission denied%'));
  r := pg_temp.hp('a4', 'inventory.receive_po');
  perform pg_temp.rec('C8 X still has the grant after those attempts', 'true', r, r = 'true');

  -- ===== D. role grants still work through the shared key list
  r := pg_temp.try(format('select public.set_role_permission(%L, %L, true)::text', 'employee', 'units.void'), 'a2', true);
  r2 := pg_temp.hp('a5', 'units.void');
  perform pg_temp.rec('D1 admin can grant a role a key; Y gets it', 'OK, true', left(r, 3) || ', ' || r2, r like 'OK:%' and r2 = 'true');
  r := pg_temp.try(format('select public.set_role_permission(%L, %L, false)::text', 'employee', 'units.void'), 'a2', true);
  r2 := pg_temp.hp('a5', 'units.void');
  perform pg_temp.rec('D2 and take it back', 'OK, false', left(r, 3) || ', ' || r2, r like 'OK:%' and r2 = 'false');
  r := pg_temp.try(format('select public.set_role_permission(%L, %L, true)::text', 'employee', 'inventory.receive_po'), 'a2', true);
  r2 := pg_temp.hp('a5', 'inventory.receive_po');
  perform pg_temp.rec('D3 role-level receive_po for the employee role reaches Y', 'OK, true', left(r, 3) || ', ' || r2, r like 'OK:%' and r2 = 'true');
  perform pg_temp.try(format('select public.set_role_permission(%L, %L, false)::text', 'employee', 'inventory.receive_po'), 'a2', true);
  r := pg_temp.try(format('select public.set_role_permission(%L, %L, true)::text', 'employee', 'bogus.key'), 'a2', true);
  perform pg_temp.rec('D4 unknown key refused', 'Unknown permission key', r, r like 'ERR:%Unknown permission key%');
  r := pg_temp.try(format('select public.set_role_permission(%L, %L, true)::text', 'employee', 'units.void'), 'a3', true);
  perform pg_temp.rec('D5 manager cannot change role grants', 'Only owners and admins', r, r like 'ERR:%Only owners and admins%');
  r := pg_temp.try(format('select public.set_role_permission(%L, %L, false)::text', 'owner', 'units.void'), 'a2', true);
  perform pg_temp.rec('D6 owner permissions still cannot be removed', 'cannot be removed', r, r like 'ERR:%cannot be removed%');

  -- ===== E. receiving purchase orders (migration 105)
  r := pg_temp.try(format('select public.receive_purchase_order_line(%L, 1)::text', LINE), 'a5', true);
  perform pg_temp.rec('E1 employee Y without the permission cannot receive', 'permission error', r, r like 'ERR:%do not have permission to receive%');
  r := pg_temp.try(format('select public.receive_purchase_order_line(%L, 1)::text', LINE), 'a3', true);
  perform pg_temp.rec('E2 manager can still receive (same as before)', 'OK', r, r like 'OK:%');
  r := pg_temp.try(format('select public.receive_purchase_order_line(%L, 1)::text', LINE), 'a2', true);
  perform pg_temp.rec('E3 admin can still receive', 'OK', r, r like 'OK:%');
  r := pg_temp.try(format('select public.receive_purchase_order_line(%L, 1)::text', LINE), 'a1', true);
  perform pg_temp.rec('E4 owner can still receive', 'OK', r, r like 'OK:%');
  r := pg_temp.try(format('select public.receive_purchase_order_line(%L, 1)::text', LINE), 'a4', true);
  perform pg_temp.rec('E5 employee X WITH the individual grant can receive', 'OK', r, r like 'OK:%');
  perform pg_temp.sep('a2', 'e4', 'inventory.receive_po', 'false');
  r := pg_temp.try(format('select public.receive_purchase_order_line(%L, 1)::text', LINE), 'a4', true);
  perform pg_temp.rec('E6 deny override takes receiving away from X', 'permission error', r, r like 'ERR:%do not have permission to receive%');
  perform pg_temp.sep('a3', 'e3', 'inventory.receive_po', 'false');
  perform pg_temp.sep('a1', 'e3', 'inventory.receive_po', 'false');
  r := pg_temp.try(format('select public.receive_purchase_order_line(%L, 1)::text', LINE), 'a3', true);
  perform pg_temp.rec('E7 deny override takes receiving away from a manager', 'permission error', r, r like 'ERR:%do not have permission to receive%');
  perform pg_temp.sep('a1', 'e3', 'inventory.receive_po', 'null');
  r := pg_temp.try(format('select public.receive_purchase_order_line(%L, 1)::text', LINE), 'b1', true);
  perform pg_temp.rec('E8 company B owner cannot receive company A''s PO', 'permission error', r, r like 'ERR:%');
  r := pg_temp.s(format('select on_hand_quantity from public.inventory_positions where variant_id = %L and location_id = %L and disposition = %L', P1, WH, 'Prime'));
  r2 := pg_temp.s(format('select quantity_received from public.purchase_order_line_items where id = %L', LINE));
  perform pg_temp.rec('E9 four successful receipts: stock 4 and line received 4', '4 and 4', r || ' and ' || r2, r = '4' and r2 = '4');
  r := pg_temp.try(format('select public.receive_purchase_order_line(%L, 100)::text', LINE), 'a1', true);
  perform pg_temp.rec('E10 receiving more than ordered still refused', 'exceeds remaining', r, r like 'ERR:%exceeds remaining%');
end $$;

create temp table res_out as select * from pg_temp.res;

-- ---------------------------------------------------------------- teardown
delete from public.purchase_order_events where purchase_order_id = pg_temp.u('a1a');
delete from public.purchase_order_line_items where purchase_order_id = pg_temp.u('a1a');
delete from public.purchase_orders where id = pg_temp.u('a1a');
delete from public.document_counters where company_id in (pg_temp.u('a'), pg_temp.u('b'));
delete from public.stock_ledger_entries where variant_id = pg_temp.u('91');
delete from public.inventory_positions where variant_id = pg_temp.u('91');
delete from public.audit_events where company_id in (pg_temp.u('a'), pg_temp.u('b'));
delete from public.employee_permission_overrides where company_id in (pg_temp.u('a'), pg_temp.u('b'));
delete from public.products where id = pg_temp.u('91');
delete from public.employees where id in (pg_temp.u('e1'), pg_temp.u('e2'), pg_temp.u('e3'), pg_temp.u('e4'), pg_temp.u('e5'), pg_temp.u('e6'), pg_temp.u('e7'));
delete from public.role_permission_grants where company_id in (pg_temp.u('a'), pg_temp.u('b'));
delete from public.stores where company_id in (pg_temp.u('a'), pg_temp.u('b'));
delete from public.companies where id in (pg_temp.u('a'), pg_temp.u('b'));
delete from auth.users where id in (pg_temp.u('a1'), pg_temp.u('a2'), pg_temp.u('a3'), pg_temp.u('a4'), pg_temp.u('a5'), pg_temp.u('b1'), pg_temp.u('b2'));

-- ---------------------------------------------------------- the one select
select
  r.id, r.test_name, r.passed, case when r.passed then '' else r.actual end as actual_if_failed,
  (select count(*) from res_out where not passed) as total_failed,
  (select count(*) from res_out) as total_tests,
  (select count(*) from public.companies where name like 'P1CHK%')
  + (select count(*) from public.stores where name like 'P1CHK%')
  + (select count(*) from public.employees where first_name in ('Olive','Addie','Manny','Xavier','Yara','Bo','Bea') and last_name like '%A' or last_name like '%B' and first_name in ('Bo','Bea'))
  + (select count(*) from public.employee_permission_overrides where company_id::text like 'd1040000-%')
  + (select count(*) from public.purchase_orders where vendor_name = 'P1CHK Vendor')
  + (select count(*) from public.products where sku like 'P1CHK%')
  + (select count(*) from auth.users where email like 'p1chk-%') as leftovers
from res_out r
order by r.id;
