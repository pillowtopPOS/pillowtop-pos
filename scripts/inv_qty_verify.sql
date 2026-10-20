-- ============================================================================
-- INV-QTY — verify migration 095 in the Supabase SQL editor
--
-- IMPORTANT: the editor only shows the LAST statement's result, so run each
-- labeled block ONE AT A TIME. Blocks 0-5 and 7 use a self-contained TEST
-- journey (fixed UUIDs, sku INV-QTY-TEST, customer "INV-QTY Test").
-- Fulfillment is pickup so the effective location is the store itself.
--
-- Fixture design: line is $10, payment is $1,000 — the journey stays "fully
-- paid" through every quantity change under the default paid_in_full policy
-- (and trivially satisfies the earlier-trigger policies too). That is what
-- keeps the reservation trigger true while quantity changes — the exact
-- case 095 fixes.
--
-- No set_config impersonation is needed: the SQL editor runs as postgres,
-- and evaluate_journey_inventory / evaluate_pending_inventory_for_variant
-- take no auth.uid() check (they are revoked from authenticated — the app
-- reaches them via triggers/RPCs, the editor reaches them directly).
--
-- Expected results are written above each final SELECT.
-- ============================================================================


-- ─── BLOCK 0 — SETUP: TEST journey, 1 line qty 1, fully paid ─────────────
-- Creates: TEST customer, product sku INV-QTY-TEST, 10 on-hand at the first
-- store (Prime, no sublocation), pickup journey, line qty 1, $1,000 payment.
-- The payment_completed event fires zz_inventory_event_hook -> evaluate.
--
-- EXPECTED (final select): requirement required=1, reserved=1, ready;
-- position committed=1 (of 10); journey Ready to Schedule.

insert into public.customers (id, first_name, last_name, phone, email)
values ('aa000000-0000-4000-8000-000000000001', 'INV-QTY', 'Test',
        '000-000-0000', 'invqty-test@example.com')
on conflict (id) do nothing;

insert into public.products (id, company_id, sku, item_name, price)
select 'aa000000-0000-4000-8000-000000000002', s.company_id,
       'INV-QTY-TEST', 'INV-QTY Test Mattress', 10
from public.stores s order by s.created_at limit 1
on conflict (id) do nothing;

insert into public.inventory_positions
  (variant_id, location_id, disposition, sublocation_id,
   on_hand_quantity, committed_quantity)
select 'aa000000-0000-4000-8000-000000000002', s.id, 'Prime', null, 10, 0
from public.stores s order by s.created_at limit 1
on conflict do nothing;

insert into public.sleep_journeys (id, customer_id, store_id, fulfillment_type)
select 'aa000000-0000-4000-8000-000000000003',
       'aa000000-0000-4000-8000-000000000001', s.id, 'pickup'
from public.stores s order by s.created_at limit 1
on conflict (id) do nothing;

insert into public.journey_line_items
  (id, journey_id, product_id, item_name, quantity, unit_price)
values ('aa000000-0000-4000-8000-000000000010',
        'aa000000-0000-4000-8000-000000000003',
        'aa000000-0000-4000-8000-000000000002',
        'INV-QTY Test Mattress', 1, 10)
on conflict (id) do nothing;

insert into public.journey_events
  (journey_id, event_type, outcome, event_data, triggered_by)
select 'aa000000-0000-4000-8000-000000000003', 'payment_completed', 'SUCCEEDED',
       jsonb_build_object('amount', 1000, 'method', 'CASH', 'inv_qty_verify', true),
       'system'
where not exists (
  select 1 from public.journey_events
  where journey_id = 'aa000000-0000-4000-8000-000000000003'
    and event_type = 'payment_completed' and outcome = 'SUCCEEDED');

select jir.quantity_required, jir.quantity_reserved, jir.status,
       ip.committed_quantity, ip.on_hand_quantity,
       sj.current_state
from public.journey_inventory_requirements jir
join public.inventory_positions ip
  on ip.variant_id = jir.variant_id and ip.location_id = jir.location_id
 and ip.disposition = 'Prime' and ip.sublocation_id is null
join public.sleep_journeys sj on sj.id = jir.journey_id
where jir.journey_id = 'aa000000-0000-4000-8000-000000000003'
  and jir.status in ('pending', 'ready');


-- ─── BLOCK 1 — qty 1 -> 3 with stock ──────────────────────────────────────
-- EXPECTED: required=3, reserved=3, status ready, committed=3 (up by 2),
-- journey still Ready to Schedule.

update public.journey_line_items
set quantity = 3
where id = 'aa000000-0000-4000-8000-000000000010';

select jir.quantity_required, jir.quantity_reserved, jir.status,
       ip.committed_quantity, ip.on_hand_quantity,
       sj.current_state
from public.journey_inventory_requirements jir
join public.inventory_positions ip
  on ip.variant_id = jir.variant_id and ip.location_id = jir.location_id
 and ip.disposition = 'Prime' and ip.sublocation_id is null
join public.sleep_journeys sj on sj.id = jir.journey_id
where jir.journey_id = 'aa000000-0000-4000-8000-000000000003'
  and jir.status in ('pending', 'ready');


-- ─── BLOCK 2 — qty 3 -> 5 with only ONE free unit ────────────────────────
-- First shrink on-hand to 4 so free = on_hand - committed = 4 - 3 = 1.
-- The delta needed is 2 > 1 free, so under all-or-nothing nothing new is
-- reserved — but the 3 already held must STAY held (partial-reserve state).
-- EXPECTED: required=5, reserved=3, status pending, committed still 3,
-- journey Waiting for Inventory.

update public.inventory_positions
set on_hand_quantity = 4
where variant_id = 'aa000000-0000-4000-8000-000000000002'
  and disposition = 'Prime' and sublocation_id is null
  and committed_quantity = 3;

update public.journey_line_items
set quantity = 5
where id = 'aa000000-0000-4000-8000-000000000010';

select jir.quantity_required, jir.quantity_reserved, jir.status,
       ip.committed_quantity, ip.on_hand_quantity,
       sj.current_state
from public.journey_inventory_requirements jir
join public.inventory_positions ip
  on ip.variant_id = jir.variant_id and ip.location_id = jir.location_id
 and ip.disposition = 'Prime' and ip.sublocation_id is null
join public.sleep_journeys sj on sj.id = jir.journey_id
where jir.journey_id = 'aa000000-0000-4000-8000-000000000003'
  and jir.status in ('pending', 'ready');


-- ─── BLOCK 2b — stock arrives -> evaluate_pending_inventory_for_variant ──
-- Restock to 10, then call the same FIFO wake-up the receipt paths call.
-- EXPECTED: reserved=5, status ready, committed=5, Ready to Schedule.

update public.inventory_positions
set on_hand_quantity = 10
where variant_id = 'aa000000-0000-4000-8000-000000000002'
  and disposition = 'Prime' and sublocation_id is null;

select public.evaluate_pending_inventory_for_variant(
  'aa000000-0000-4000-8000-000000000002',
  (select store_id from public.sleep_journeys
   where id = 'aa000000-0000-4000-8000-000000000003'));

select jir.quantity_required, jir.quantity_reserved, jir.status,
       ip.committed_quantity, ip.on_hand_quantity,
       sj.current_state
from public.journey_inventory_requirements jir
join public.inventory_positions ip
  on ip.variant_id = jir.variant_id and ip.location_id = jir.location_id
 and ip.disposition = 'Prime' and ip.sublocation_id is null
join public.sleep_journeys sj on sj.id = jir.journey_id
where jir.journey_id = 'aa000000-0000-4000-8000-000000000003'
  and jir.status in ('pending', 'ready');


-- ─── BLOCK 3 — qty 5 -> 2: release the excess ─────────────────────────────
-- EXPECTED: required=2, reserved=2, committed=2 (down by 3), ready,
-- Ready to Schedule.

update public.journey_line_items
set quantity = 2
where id = 'aa000000-0000-4000-8000-000000000010';

select jir.quantity_required, jir.quantity_reserved, jir.status,
       ip.committed_quantity, ip.on_hand_quantity,
       sj.current_state
from public.journey_inventory_requirements jir
join public.inventory_positions ip
  on ip.variant_id = jir.variant_id and ip.location_id = jir.location_id
 and ip.disposition = 'Prime' and ip.sublocation_id is null
join public.sleep_journeys sj on sj.id = jir.journey_id
where jir.journey_id = 'aa000000-0000-4000-8000-000000000003'
  and jir.status in ('pending', 'ready');


-- ─── BLOCK 4 — same quantity: nothing changes ─────────────────────────────
-- Rewriting quantity = 2 still fires the trigger and runs the evaluator;
-- the equal case must be a no-op.
-- EXPECTED: required=2, reserved=2, ready, committed=2 — and the event
-- count shows NO new inventory_required / inventory_received rows
-- (still only the original payment_completed).

update public.journey_line_items
set quantity = 2
where id = 'aa000000-0000-4000-8000-000000000010';

select jir.quantity_required, jir.quantity_reserved, jir.status,
       ip.committed_quantity, sj.current_state,
       (select count(*) from public.journey_events e
        where e.journey_id = 'aa000000-0000-4000-8000-000000000003'
          and e.event_type in ('inventory_required', 'inventory_received'))
         as inventory_events
from public.journey_inventory_requirements jir
join public.inventory_positions ip
  on ip.variant_id = jir.variant_id and ip.location_id = jir.location_id
 and ip.disposition = 'Prime' and ip.sublocation_id is null
join public.sleep_journeys sj on sj.id = jir.journey_id
where jir.journey_id = 'aa000000-0000-4000-8000-000000000003'
  and jir.status in ('pending', 'ready');


-- ─── BLOCK 5 — delete the line: existing supersede still works ────────────
-- EXPECTED: the requirement is superseded, committed back to 0.
-- (Final select returns the superseded row + position.)

delete from public.journey_line_items
where id = 'aa000000-0000-4000-8000-000000000010';

select jir.quantity_required, jir.quantity_reserved, jir.status,
       ip.committed_quantity, ip.on_hand_quantity
from public.journey_inventory_requirements jir
left join public.inventory_positions ip
  on ip.variant_id = jir.variant_id and ip.location_id = jir.location_id
 and ip.disposition = 'Prime' and ip.sublocation_id is null
where jir.journey_id = 'aa000000-0000-4000-8000-000000000003'
order by jir.created_at;


-- ─── BLOCK 6 — exchange child: add-on qty change touches ONLY its row ─────
-- Fixture: the newest COMMITTED exchange child that has an add-on line
-- (product-backed line with exchange_line_role IS NULL — 'replacement',
-- 'exchange_fee', 'other_fees', 'credit' are the flagged roles).
-- To keep the child "fully paid" through the edit (its price rises by the
-- add-on's unit price), a matching top-up payment is recorded FIRST — then
-- the quantity bump reconciles in place instead of going underpaid.
--
-- Run the first select alone to see the fixture it picked; then the rest.
-- EXPECTED (final select): the add-on's requirement required/reserved grew
-- by 1; the replacement (mattress) requirement is the SAME row id with the
-- SAME required/reserved it had before — untouched.

select sj.id as child_id, sj.current_state, sj.price, public.total_paid(sj.id) as paid,
       jli.id as addon_line_id, jli.item_name, jli.quantity, jli.unit_price
from public.sleep_trial_actions sa
join public.sleep_journeys sj on sj.id = sa.child_journey_id
join public.journey_line_items jli on jli.journey_id = sj.id
where sa.status = 'COMMITTED'
  and sj.cancelled_at is null
  and jli.exchange_line_role is null
  and jli.product_id is not null
order by sa.created_at desc
limit 1;

-- top-up payment covering the add-on's unit price (keeps paid >= new price)
insert into public.journey_events
  (journey_id, event_type, outcome, event_data, triggered_by)
select sj.id, 'payment_completed', 'SUCCEEDED',
       jsonb_build_object('amount', jli.unit_price, 'method', 'CASH',
                          'inv_qty_verify', true),
       'system'
from public.sleep_trial_actions sa
join public.sleep_journeys sj on sj.id = sa.child_journey_id
join public.journey_line_items jli on jli.journey_id = sj.id
where sa.status = 'COMMITTED'
  and sj.cancelled_at is null
  and jli.exchange_line_role is null
  and jli.product_id is not null
order by sa.created_at desc
limit 1;

-- bump the add-on quantity by 1
update public.journey_line_items jli
set quantity = jli.quantity + 1
from public.sleep_trial_actions sa
join public.sleep_journeys sj on sj.id = sa.child_journey_id
where jli.journey_id = sj.id
  and sa.status = 'COMMITTED'
  and sj.cancelled_at is null
  and jli.exchange_line_role is null
  and jli.product_id is not null
  and sa.created_at = (
    select max(sa2.created_at) from public.sleep_trial_actions sa2
    where sa2.status = 'COMMITTED');

-- result: every requirement on that child — add-on row changed, others not
select jir.id, jir.variant_id, p.item_name, jir.quantity_required,
       jir.quantity_reserved, jir.status, jir.created_at
from public.journey_inventory_requirements jir
join public.products p on p.id = jir.variant_id
where jir.journey_id = (
  select sj.id
  from public.sleep_trial_actions sa
  join public.sleep_journeys sj on sj.id = sa.child_journey_id
  join public.journey_line_items jli on jli.journey_id = sj.id
  where sa.status = 'COMMITTED'
    and sj.cancelled_at is null
    and jli.exchange_line_role is null
    and jli.product_id is not null
  order by sa.created_at desc
  limit 1)
order by jir.created_at;


-- ─── BLOCK 7 — two lines, same variant + location: required = SUM ─────────
-- Back on the TEST journey (whose line was deleted in block 5): add two
-- lines for the same product, qty 2 and qty 1.
-- EXPECTED: one requirement, required=3, reserved=3, ready, committed=3.

insert into public.journey_line_items
  (id, journey_id, product_id, item_name, quantity, unit_price)
values
  ('aa000000-0000-4000-8000-000000000010',
   'aa000000-0000-4000-8000-000000000003',
   'aa000000-0000-4000-8000-000000000002',
   'INV-QTY Test Mattress', 2, 10),
  ('aa000000-0000-4000-8000-000000000011',
   'aa000000-0000-4000-8000-000000000003',
   'aa000000-0000-4000-8000-000000000002',
   'INV-QTY Test Mattress (2nd line)', 1, 10)
on conflict (id) do nothing;

select jir.quantity_required, jir.quantity_reserved, jir.status,
       ip.committed_quantity, sj.current_state
from public.journey_inventory_requirements jir
join public.inventory_positions ip
  on ip.variant_id = jir.variant_id and ip.location_id = jir.location_id
 and ip.disposition = 'Prime' and ip.sublocation_id is null
join public.sleep_journeys sj on sj.id = jir.journey_id
where jir.journey_id = 'aa000000-0000-4000-8000-000000000003'
  and jir.status in ('pending', 'ready');


-- ─── BLOCK 8 — TEARDOWN (optional): remove all INV-QTY fixtures ──────────
-- Releases reservations via the normal cancel path first.

insert into public.journey_events
  (journey_id, event_type, outcome, event_data, triggered_by)
select 'aa000000-0000-4000-8000-000000000003', 'journey_cancelled', 'SUCCEEDED',
       jsonb_build_object('reason', 'inv-qty verify teardown', 'inv_qty_verify', true),
       'system'
where exists (
  select 1 from public.sleep_journeys
  where id = 'aa000000-0000-4000-8000-000000000003' and cancelled_at is null);

delete from public.journey_line_items
where journey_id = 'aa000000-0000-4000-8000-000000000003';
delete from public.journey_inventory_requirements
where journey_id = 'aa000000-0000-4000-8000-000000000003';
delete from public.inventory_positions
where variant_id = 'aa000000-0000-4000-8000-000000000002';
delete from public.sleep_journeys
where id = 'aa000000-0000-4000-8000-000000000003';
delete from public.products
where id = 'aa000000-0000-4000-8000-000000000002';
delete from public.customers
where id = 'aa000000-0000-4000-8000-000000000001';

select 'fixtures removed' as result;
