-- ============================================================================
-- eb-4a — verify migration 099 in the Supabase SQL editor
--
-- Run each labeled block ONE AT A TIME — the editor shows only the LAST
-- statement's result. Fixture ids are fixed UUIDs prefixed eb4a0000.
--
-- Impersonation: select set_config('request.jwt.claim.sub', '<auth_user_id>',
-- true) makes auth.uid() return that user for the rest of the transaction —
-- the same trick refunds_b2_verify.sql used.
--
-- Fixture design:
--   company   eb4a0000-0000-4000-8000-000000000001
--   warehouse eb4a0000-0000-4000-8000-000000000002  (auto-provisions quarantine)
--   store     eb4a0000-0000-4000-8000-000000000003  (no quarantine)
--   employee A (exchange starter, home = store)     ...0004
--   employee B (warehouse-based, no start_exchange)  ...0005
--   employee C (customer-facing, no rights)         ...0006
--   customer  ...0007 / product ...0008
--   journey (original sale) ...0009 / trial item ...0010
--   child journey ...0011 / action COMMITTED ...0012
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0. FIXTURE — run once. Ends in a count you can eyeball.
-- ---------------------------------------------------------------------------
begin;

insert into public.companies (id, name)
values ('eb4a0000-0000-4000-8000-000000000001', 'EB4A Verify Co')
on conflict (id) do nothing;

insert into public.stores (id, company_id, name, location_type, is_active)
values
  ('eb4a0000-0000-4000-8000-000000000002', 'eb4a0000-0000-4000-8000-000000000001', 'EB4A Warehouse', 'WAREHOUSE', true),
  ('eb4a0000-0000-4000-8000-000000000003', 'eb4a0000-0000-4000-8000-000000000001', 'EB4A Store', 'STORE', true)
on conflict (id) do nothing;

insert into public.employees (id, auth_user_id, company_id, home_store_id, name, role)
values
  ('eb4a0000-0000-4000-8000-000000000004', 'eb4a0000-0000-4000-8000-00000000a004', 'eb4a0000-0000-4000-8000-000000000001', 'eb4a0000-0000-4000-8000-000000000003', 'Ada Exchange', 'owner'),
  ('eb4a0000-0000-4000-8000-000000000005', 'eb4a0000-0000-4000-8000-00000000a005', 'eb4a0000-0000-4000-8000-000000000001', 'eb4a0000-0000-4000-8000-000000000002', 'Wally Warehouse', 'employee'),
  ('eb4a0000-0000-4000-8000-000000000006', 'eb4a0000-0000-4000-8000-00000000a006', 'eb4a0000-0000-4000-8000-000000000001', 'eb4a0000-0000-4000-8000-000000000003', 'Ned Norights', 'employee')
on conflict (id) do nothing;

-- Role grants: sleep_trial.start_exchange only for owner + the store employee role.
insert into public.role_permission_grants (company_id, role, permission_key)
values
  ('eb4a0000-0000-4000-8000-000000000001', 'owner', 'sleep_trial.start_exchange'),
  ('eb4a0000-0000-4000-8000-000000000001', 'owner', 'sleep_trial.complete_exchange')
on conflict do nothing;

insert into public.customers (id, company_id, full_name, phone)
values ('eb4a0000-0000-4000-8000-000000000007', 'eb4a0000-0000-4000-8000-000000000001', 'Carl Customer', '555-0101')
on conflict (id) do nothing;

insert into public.products (id, company_id, sku, item_name, price)
values ('eb4a0000-0000-4000-8000-000000000008', 'eb4a0000-0000-4000-8000-000000000001', 'EB4A-MATT', 'EB4A Mattress', 999.00)
on conflict (id) do nothing;

insert into public.sleep_journeys (id, company_id, store_id, customer_id, current_state, sale_kind)
values
  ('eb4a0000-0000-4000-8000-000000000009', 'eb4a0000-0000-4000-8000-000000000001', 'eb4a0000-0000-4000-8000-000000000003', 'eb4a0000-0000-4000-8000-000000000007', 'Sleep Trial', 'STANDARD'),
  ('eb4a0000-0000-4000-8000-000000000011', 'eb4a0000-0000-4000-8000-000000000001', 'eb4a0000-0000-4000-8000-000000000003', 'eb4a0000-0000-4000-8000-000000000007', 'Sold', 'EXCHANGE')
on conflict (id) do nothing;

update public.sleep_journeys
set parent_journey_id = 'eb4a0000-0000-4000-8000-000000000009',
    exchange_action_id = 'eb4a0000-0000-4000-8000-000000000012'
where id = 'eb4a0000-0000-4000-8000-000000000011';

insert into public.sleep_trial_items (id, company_id, journey_id, product_id, product_name_snapshot, status)
values ('eb4a0000-0000-4000-8000-000000000010', 'eb4a0000-0000-4000-8000-000000000001', 'eb4a0000-0000-4000-8000-000000000009', 'eb4a0000-0000-4000-8000-000000000008', 'EB4A Mattress', 'EXCHANGE_IN_PROGRESS')
on conflict (id) do nothing;

insert into public.sleep_trial_actions (
  id, company_id, journey_id, trial_item_id, action, status,
  child_journey_id, committed_at, committed_by
) values (
  'eb4a0000-0000-4000-8000-000000000012', 'eb4a0000-0000-4000-8000-000000000001',
  'eb4a0000-0000-4000-8000-000000000009', 'eb4a0000-0000-4000-8000-000000000010',
  'EXCHANGE', 'COMMITTED',
  'eb4a0000-0000-4000-8000-000000000011', now() - interval '2 days',
  'eb4a0000-0000-4000-8000-000000000004'
)
on conflict (id) do nothing;

commit;

-- Expected: quarantine row auto-provisioned for the warehouse.
select id, name, location_type, parent_location_id
from public.stores
where parent_location_id = 'eb4a0000-0000-4000-8000-000000000002';

-- ---------------------------------------------------------------------------
-- 1. RECEIVE at the warehouse as the exchange starter (Ada).
--    Expect: one inspection id back; position +1 Returned; one ledger row;
--    one AWAITING_INSPECTION; activity lines on BOTH journeys.
-- ---------------------------------------------------------------------------
begin;
select set_config('request.jwt.claim.sub', 'eb4a0000-0000-4000-8000-00000000a004', true);
select public.receive_returned_unit(
  'eb4a0000-0000-4000-8000-000000000012',
  'eb4a0000-0000-4000-8000-000000000002',
  current_date
) as inspection_id;
commit;

select
  (select on_hand_quantity from public.inventory_positions
    where variant_id = 'eb4a0000-0000-4000-8000-000000000008'
      and disposition = 'Returned') as returned_qty,
  (select count(*) from public.stock_ledger_entries
    where correlation_id = 'eb4a0000-0000-4000-8000-000000000012'
      and reason = 'return_received' and quantity_delta = 1) as ledger_rows,
  (select count(*) from public.returned_unit_inspections
    where action_id = 'eb4a0000-0000-4000-8000-000000000012'
      and status = 'AWAITING_INSPECTION') as inspections,
  (select count(*) from public.journey_interactions
    where source_domain = 'sleep_trial_action'
      and source_record_id = 'eb4a0000-0000-4000-8000-000000000012'
      and summary like 'Original mattress received%') as activity_lines,
  (select original_received_on from public.sleep_trial_actions
    where id = 'eb4a0000-0000-4000-8000-000000000012') as received_on;
-- Expect: 1, 1, 1, 2 (both journeys), today.

-- ---------------------------------------------------------------------------
-- 2. RECEIVE AGAIN (idempotent). Expect: returns the same inspection id;
--    position still +1, ledger still 1 row.
-- ---------------------------------------------------------------------------
begin;
select set_config('request.jwt.claim.sub', 'eb4a0000-0000-4000-8000-00000000a004', true);
select public.receive_returned_unit(
  'eb4a0000-0000-4000-8000-000000000012',
  'eb4a0000-0000-4000-8000-000000000002',
  current_date
) as second_call;
commit;

select
  (select on_hand_quantity from public.inventory_positions
    where variant_id = 'eb4a0000-0000-4000-8000-000000000008'
      and disposition = 'Returned') as returned_qty,
  (select count(*) from public.stock_ledger_entries
    where correlation_id = 'eb4a0000-0000-4000-8000-000000000012'
      and reason = 'return_received') as ledger_rows,
  (select count(*) from public.returned_unit_inspections
    where action_id = 'eb4a0000-0000-4000-8000-000000000012'
      and status = 'AWAITING_INSPECTION') as inspections;
-- Expect: 1, 1, 1 — no second +1, no second inspection.

-- ---------------------------------------------------------------------------
-- 3. RECEIVE WITHOUT A QUARANTINE AREA — void the receipt first (block 5
--    does the void path too; here we force the missing-area error with a
--    fresh action on the store, which has no quarantine child).
-- ---------------------------------------------------------------------------
insert into public.sleep_trial_actions (
  id, company_id, journey_id, trial_item_id, action, status,
  child_journey_id, committed_at, committed_by
) values (
  'eb4a0000-0000-4000-8000-000000000013', 'eb4a0000-0000-4000-8000-000000000001',
  'eb4a0000-0000-4000-8000-000000000009', 'eb4a0000-0000-4000-8000-000000000010',
  'EXCHANGE', 'COMMITTED',
  'eb4a0000-0000-4000-8000-000000000011', now() - interval '2 days',
  'eb4a0000-0000-4000-8000-000000000004'
)
on conflict (id) do nothing;

begin;
select set_config('request.jwt.claim.sub', 'eb4a0000-0000-4000-8000-00000000a004', true);
select public.receive_returned_unit(
  'eb4a0000-0000-4000-8000-000000000013',
  'eb4a0000-0000-4000-8000-000000000003',  -- the STORE: no quarantine area
  current_date
);
commit;
-- Expect: ERROR "That location has no quarantine area. An owner or admin can
-- create one in Settings (Locations)." — transaction aborts, nothing written.

-- Now the one-click fix, then the same call succeeds.
begin;
select set_config('request.jwt.claim.sub', 'eb4a0000-0000-4000-8000-00000000a004', true);
select public.create_quarantine_area('eb4a0000-0000-4000-8000-000000000003') as quarantine_id;
select public.create_quarantine_area('eb4a0000-0000-4000-8000-000000000003') as second_call_same_id;
commit;

begin;
select set_config('request.jwt.claim.sub', 'eb4a0000-0000-4000-8000-00000000a004', true);
select public.receive_returned_unit(
  'eb4a0000-0000-4000-8000-000000000013',
  'eb4a0000-0000-4000-8000-000000000003',
  current_date
) as inspection_id;
commit;

select
  (select s.location_type from public.stores s
    where s.parent_location_id = 'eb4a0000-0000-4000-8000-000000000003') as child_type,
  (select ip.on_hand_quantity from public.inventory_positions ip
    join public.stores s on s.id = ip.location_id
    where s.parent_location_id = 'eb4a0000-0000-4000-8000-000000000003'
      and ip.disposition = 'Returned') as returned_at_store_quarantine;
-- Expect: 'WAREHOUSE_QUARANTINE', 1.

-- ---------------------------------------------------------------------------
-- 4. FUTURE DATE refused (fresh action).
-- ---------------------------------------------------------------------------
insert into public.sleep_trial_actions (
  id, company_id, journey_id, trial_item_id, action, status,
  committed_at, committed_by
) values (
  'eb4a0000-0000-4000-8000-000000000014', 'eb4a0000-0000-4000-8000-000000000001',
  'eb4a0000-0000-4000-8000-000000000009', 'eb4a0000-0000-4000-8000-000000000010',
  'EXCHANGE', 'COMMITTED', now() - interval '2 days',
  'eb4a0000-0000-4000-8000-000000000004'
)
on conflict (id) do nothing;

begin;
select set_config('request.jwt.claim.sub', 'eb4a0000-0000-4000-8000-00000000a004', true);
select public.receive_returned_unit(
  'eb4a0000-0000-4000-8000-000000000014',
  'eb4a0000-0000-4000-8000-000000000002',
  current_date + 1
);
commit;
-- Expect: ERROR "The received date cannot be in the future."

-- ---------------------------------------------------------------------------
-- 5. VOID the block-1 receipt (inspection still AWAITING_INSPECTION).
--    Expect: position back to 0, void ledger row, action fields cleared,
--    inspection CANCELLED, activity lines on both journeys.
-- ---------------------------------------------------------------------------
begin;
select set_config('request.jwt.claim.sub', 'eb4a0000-0000-4000-8000-00000000a004', true);
select public.void_returned_receipt(
  'eb4a0000-0000-4000-8000-000000000012',
  'Marked received at the wrong store'
) as cancelled_inspection;
commit;

select
  (select on_hand_quantity from public.inventory_positions
    where variant_id = 'eb4a0000-0000-4000-8000-000000000008'
      and disposition = 'Returned'
      and location_id in (select id from public.stores where parent_location_id = 'eb4a0000-0000-4000-8000-000000000002')) as returned_at_wh_quarantine,
  (select count(*) from public.stock_ledger_entries
    where correlation_id = 'eb4a0000-0000-4000-8000-000000000012'
      and reason = 'return_receipt_voided' and quantity_delta = -1) as void_ledger,
  (select original_received_on from public.sleep_trial_actions
    where id = 'eb4a0000-0000-4000-8000-000000000012') as received_on_after_void,
  (select status from public.returned_unit_inspections
    where action_id = 'eb4a0000-0000-4000-8000-000000000012') as inspection_status,
  (select count(*) from public.journey_interactions
    where source_record_id = 'eb4a0000-0000-4000-8000-000000000012'
      and summary like 'Receipt of the original mattress was voided%') as void_lines;
-- Expect: 0, 1, NULL, 'CANCELLED', 2.

-- ---------------------------------------------------------------------------
-- 6. VOID AFTER INSPECTION STARTED — refuse. Simulate IN_PROGRESS on the
--    block-3 receipt (direct update as postgres bypasses RLS).
-- ---------------------------------------------------------------------------
update public.returned_unit_inspections
set status = 'IN_PROGRESS', started_at = now()
where action_id = 'eb4a0000-0000-4000-8000-000000000013';

begin;
select set_config('request.jwt.claim.sub', 'eb4a0000-0000-4000-8000-00000000a004', true);
select public.void_returned_receipt(
  'eb4a0000-0000-4000-8000-000000000013',
  'trying to void a started inspection'
);
commit;
-- Expect: ERROR "This return is already being inspected, so the receipt can
-- no longer be voided."

-- ---------------------------------------------------------------------------
-- 7. NO RIGHTS — Ned (store employee, not warehouse-based, no start_exchange).
--    Fresh action so the idempotent branch can't mask the refusal.
-- ---------------------------------------------------------------------------
insert into public.sleep_trial_actions (
  id, company_id, journey_id, trial_item_id, action, status,
  committed_at, committed_by
) values (
  'eb4a0000-0000-4000-8000-000000000015', 'eb4a0000-0000-4000-8000-000000000001',
  'eb4a0000-0000-4000-8000-000000000009', 'eb4a0000-0000-4000-8000-000000000010',
  'EXCHANGE', 'COMMITTED', now() - interval '2 days',
  'eb4a0000-0000-4000-8000-000000000004'
)
on conflict (id) do nothing;

begin;
select set_config('request.jwt.claim.sub', 'eb4a0000-0000-4000-8000-00000000a006', true);
select public.receive_returned_unit(
  'eb4a0000-0000-4000-8000-000000000015',
  'eb4a0000-0000-4000-8000-000000000002',
  current_date
);
commit;
-- Expect: ERROR "You do not have permission to mark an original mattress
-- received." (Ned is not warehouse-based and lacks start_exchange.)

-- Warehouse-based Wally CAN receive even without the start_exchange key.
begin;
select set_config('request.jwt.claim.sub', 'eb4a0000-0000-4000-8000-00000000a005', true);
select public.receive_returned_unit(
  'eb4a0000-0000-4000-8000-000000000015',
  'eb4a0000-0000-4000-8000-000000000002',
  current_date
) as wally_inspection;
commit;
-- Expect: an inspection id — Wally passed the warehouse-based rule.

-- ---------------------------------------------------------------------------
-- 8. RETURNED NEVER COUNTS AS AVAILABLE — the public view (the same read
--    fetchProductStock makes) shows no Returned row under Prime, and a Prime
--    read at the warehouse is unaffected by the Returned units.
-- ---------------------------------------------------------------------------
select
  (select count(*) from public.inventory_positions_public
    where variant_id = 'eb4a0000-0000-4000-8000-000000000008'
      and disposition = 'Prime'
      and location_id in (
        select id from public.stores
        where parent_location_id in (
          'eb4a0000-0000-4000-8000-000000000002',
          'eb4a0000-0000-4000-8000-000000000003'))) as prime_rows_at_quarantine,
  (select count(*) from public.inventory_positions
    where variant_id = 'eb4a0000-0000-4000-8000-000000000008'
      and disposition = 'Returned') as returned_rows_total;
-- Expect: 0 Prime rows at quarantine areas; 2 Returned rows total
-- (blocks 3 and 7; block 1's was voided down to 0 but the row may remain).

-- ---------------------------------------------------------------------------
-- 9. CROSS-COMPANY refusal — a different company's action id is invisible.
-- ---------------------------------------------------------------------------
insert into public.companies (id, name)
values ('eb4a0000-0000-4000-8000-00000000c001', 'EB4A Other Co')
on conflict (id) do nothing;

begin;
select set_config('request.jwt.claim.sub', 'eb4a0000-0000-4000-8000-00000000a004', true);
select public.receive_returned_unit(
  'eb4a0000-0000-4000-8000-00000000ffff',  -- nonexistent / other-company
  'eb4a0000-0000-4000-8000-000000000002',
  current_date
);
commit;
-- Expect: ERROR "That exchange was not found." (invisible = not found)

-- ---------------------------------------------------------------------------
-- 10. TEARDOWN — delete order respects the delivered-journey guard
--     (delete journey_events BEFORE sleep_journeys) and children before
--     parents.
-- ---------------------------------------------------------------------------
delete from public.journey_interactions
where journey_id in (
  'eb4a0000-0000-4000-8000-000000000009',
  'eb4a0000-0000-4000-8000-000000000011');

delete from public.journey_events
where journey_id in (
  'eb4a0000-0000-4000-8000-000000000009',
  'eb4a0000-0000-4000-8000-000000000011');

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
delete from public.employees where company_id = 'eb4a0000-0000-4000-8000-000000000001';
delete from public.role_permission_grants where company_id = 'eb4a0000-0000-4000-8000-000000000001';
delete from public.stores where company_id = 'eb4a0000-0000-4000-8000-000000000001';
delete from public.companies where id in (
  'eb4a0000-0000-4000-8000-000000000001',
  'eb4a0000-0000-4000-8000-00000000c001');

select 'teardown complete' as result;
