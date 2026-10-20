-- ============================================================================
-- refunds-b2 — verify migration 098 in the Supabase SQL editor
--
-- Run each labeled block ONE AT A TIME (the editor shows only the last
-- statement's result). All fixture ids are fixed UUIDs prefixed cc000000.
--
-- Fixture design:
--   Journey C — $49 stocked line (product A, 10 on hand) + $147 payment +
--     a written_sales row. Used for the adjustment, clamp, reservation-
--     kept, re-pay, cancel-releases, and refund-after-cancel tests.
--   Journey D — $49 catalog-less line + $100 payment + a written_sales
--     row. Used for the partial-clamp and reconcile guards.
--   Journey E — $30 stocked line (product B) + $30 payment. Used to prove
--     line edits still supersede reservations (default release path).
-- Payment events are inserted directly (bypass record_payment_event), so
-- the written_sales rows are inserted by hand too.
--
-- Blocks marked EXPECT ERROR are supposed to raise; a success means a bug.
-- Impersonation uses set_config('request.jwt.claim.sub', ...) so the
-- security-definer RPCs see an employee. No delivered journeys are created
-- (the delivered guard would block teardown), so block 14 removes
-- everything.
-- ============================================================================


-- ─── BLOCK 0 — SETUP ─────────────────────────────────────────────────────
-- EXPECTED (final select): journeys C/D/E with prices 49/49/30 and
-- total_paid 147/100/30.

insert into public.customers (id, first_name, last_name, phone, email)
values ('cc000000-0000-4000-8000-000000000001', 'REFUND-B2', 'Customer',
        '000-000-0000', 'refundb2-test@example.com')
on conflict (id) do nothing;

insert into public.products (id, company_id, sku, item_name, price)
select 'cc000000-0000-4000-8000-000000000002', s.company_id,
       'REFUND-B2-A', 'REFUND-B2 Mattress A', 49
from public.stores s order by s.created_at limit 1
on conflict (id) do nothing;

insert into public.products (id, company_id, sku, item_name, price)
select 'cc000000-0000-4000-8000-000000000003', s.company_id,
       'REFUND-B2-B', 'REFUND-B2 Mattress B', 30
from public.stores s order by s.created_at limit 1
on conflict (id) do nothing;

insert into public.inventory_positions
  (variant_id, location_id, disposition, sublocation_id,
   on_hand_quantity, committed_quantity)
select 'cc000000-0000-4000-8000-000000000002', s.id, 'Prime', null, 10, 0
from public.stores s order by s.created_at limit 1
on conflict do nothing;

insert into public.inventory_positions
  (variant_id, location_id, disposition, sublocation_id,
   on_hand_quantity, committed_quantity)
select 'cc000000-0000-4000-8000-000000000003', s.id, 'Prime', null, 10, 0
from public.stores s order by s.created_at limit 1
on conflict do nothing;

-- Journey C: $49 stocked line + $147 payment + written sale.
insert into public.sleep_journeys (id, customer_id, store_id, fulfillment_type)
select 'cc000000-0000-4000-8000-000000000010',
       'cc000000-0000-4000-8000-000000000001', s.id, 'pickup'
from public.stores s order by s.created_at limit 1
on conflict (id) do nothing;

insert into public.journey_line_items
  (id, journey_id, product_id, item_name, quantity, unit_price)
values ('cc000000-0000-4000-8000-000000000030',
        'cc000000-0000-4000-8000-000000000010',
        'cc000000-0000-4000-8000-000000000002',
        'REFUND-B2 Mattress A', 1, 49)
on conflict (id) do nothing;

insert into public.journey_events
  (id, journey_id, event_type, outcome, event_data, triggered_by)
values ('cc000000-0000-4000-8000-000000000020',
        'cc000000-0000-4000-8000-000000000010',
        'payment_completed', 'SUCCEEDED',
        jsonb_build_object('amount', 147, 'method', 'CARD'), 'system')
on conflict (id) do nothing;

insert into public.written_sales
  (id, tenant_id, order_id, selling_store_id,
   salesperson_attribution_reference, qualifying_order_amount,
   triggering_payment_id)
select 'cc000000-0000-4000-8000-000000000040', s.company_id,
       'cc000000-0000-4000-8000-000000000010', sj.store_id,
       'refund-b2-verify', 49,
       'cc000000-0000-4000-8000-000000000020'
from public.sleep_journeys sj
join public.stores s on s.id = sj.store_id
where sj.id = 'cc000000-0000-4000-8000-000000000010'
on conflict (id) do nothing;

-- Journey D: $49 catalog-less line + $100 payment + written sale.
insert into public.sleep_journeys (id, customer_id, store_id, fulfillment_type)
select 'cc000000-0000-4000-8000-000000000011',
       'cc000000-0000-4000-8000-000000000001', s.id, 'pickup'
from public.stores s order by s.created_at limit 1
on conflict (id) do nothing;

insert into public.journey_line_items
  (id, journey_id, item_name, quantity, unit_price)
values ('cc000000-0000-4000-8000-000000000031',
        'cc000000-0000-4000-8000-000000000011',
        'REFUND-B2 service', 1, 49)
on conflict (id) do nothing;

insert into public.journey_events
  (id, journey_id, event_type, outcome, event_data, triggered_by)
values ('cc000000-0000-4000-8000-000000000021',
        'cc000000-0000-4000-8000-000000000011',
        'payment_completed', 'SUCCEEDED',
        jsonb_build_object('amount', 100, 'method', 'CARD'), 'system')
on conflict (id) do nothing;

insert into public.written_sales
  (id, tenant_id, order_id, selling_store_id,
   salesperson_attribution_reference, qualifying_order_amount,
   triggering_payment_id)
select 'cc000000-0000-4000-8000-000000000041', s.company_id,
       'cc000000-0000-4000-8000-000000000011', sj.store_id,
       'refund-b2-verify', 49,
       'cc000000-0000-4000-8000-000000000021'
from public.sleep_journeys sj
join public.stores s on s.id = sj.store_id
where sj.id = 'cc000000-0000-4000-8000-000000000011'
on conflict (id) do nothing;

-- Journey E: $30 stocked line (product B) + $30 payment (line-edit test).
insert into public.sleep_journeys (id, customer_id, store_id, fulfillment_type)
select 'cc000000-0000-4000-8000-000000000012',
       'cc000000-0000-4000-8000-000000000001', s.id, 'pickup'
from public.stores s order by s.created_at limit 1
on conflict (id) do nothing;

insert into public.journey_line_items
  (id, journey_id, product_id, item_name, quantity, unit_price)
values ('cc000000-0000-4000-8000-000000000032',
        'cc000000-0000-4000-8000-000000000012',
        'cc000000-0000-4000-8000-000000000003',
        'REFUND-B2 Mattress B', 1, 30)
on conflict (id) do nothing;

insert into public.journey_events
  (id, journey_id, event_type, outcome, event_data, triggered_by)
values ('cc000000-0000-4000-8000-000000000022',
        'cc000000-0000-4000-8000-000000000012',
        'payment_completed', 'SUCCEEDED',
        jsonb_build_object('amount', 30, 'method', 'CARD'), 'system')
on conflict (id) do nothing;

select sj.id, sj.price, sj.current_state,
       public.total_paid(sj.id) as total_paid
from public.sleep_journeys sj
where sj.id in ('cc000000-0000-4000-8000-000000000010',
                'cc000000-0000-4000-8000-000000000011',
                'cc000000-0000-4000-8000-000000000012')
order by sj.id;


-- ─── BLOCK 1 — BASELINE ──────────────────────────────────────────────────
-- EXPECTED: written sale committed = 49; journey C requirement
-- required=1, reserved=1, status 'ready'; product-A committed=1.

select ws.qualifying_order_amount,
       ws.qualifying_order_amount
         + coalesce((select sum(a.adjustment_amount)
                     from public.written_sale_adjustments a
                     where a.written_sale_id = ws.id), 0) as committed
from public.written_sales ws
where ws.order_id = 'cc000000-0000-4000-8000-000000000010';

select jir.id as requirement_id, jir.quantity_required,
       jir.quantity_reserved, jir.status, ip.committed_quantity
from public.journey_inventory_requirements jir
join public.inventory_positions ip
  on ip.variant_id = jir.variant_id and ip.location_id = jir.location_id
 and ip.disposition = 'Prime' and ip.sublocation_id is null
where jir.journey_id = 'cc000000-0000-4000-8000-000000000010';


-- ─── BLOCK 2 — REFUND $20: negative adjustment with running totals ───────
-- EXPECTED: adjustment type 'refund', amount -20, previous 49 -> new 29;
-- journey C total_paid 127 (still over price — state unchanged).

select set_config('request.jwt.claim.sub', (
  select e.auth_user_id::text
  from public.employees e
  join public.stores st on st.company_id = e.company_id
  join public.sleep_journeys sj on sj.store_id = st.id
  where sj.id = 'cc000000-0000-4000-8000-000000000010'
    and e.role in ('owner','admin','manager')
    and e.is_active = true
  order by case e.role when 'owner' then 0 when 'admin' then 1 else 2 end
  limit 1), true);

select public.record_payment_refund(
  'cc000000-0000-4000-8000-000000000020',
  20, 'Card', 'Partial refund — customer overpaid', 'rf-2001'
) as refund_event_id;

select a.adjustment_type, a.adjustment_amount,
       a.previous_qualifying_committed_amount, a.new_qualifying_committed_amount,
       a.adjustment_reason, a.correlation_id is not null as linked_to_event
from public.written_sale_adjustments a
join public.written_sales ws on ws.id = a.written_sale_id
where ws.order_id = 'cc000000-0000-4000-8000-000000000010'
order by a.occurred_at;

select public.total_paid('cc000000-0000-4000-8000-000000000010') as total_paid;


-- ─── BLOCK 3 — SECOND REFUND $10: running totals accumulate ──────────────
-- EXPECTED: second 'refund' row -10, previous 29 -> new 19; total_paid 117.

select set_config('request.jwt.claim.sub', (
  select e.auth_user_id::text
  from public.employees e
  join public.stores st on st.company_id = e.company_id
  join public.sleep_journeys sj on sj.store_id = st.id
  where sj.id = 'cc000000-0000-4000-8000-000000000010'
    and e.role in ('owner','admin','manager')
    and e.is_active = true
  order by case e.role when 'owner' then 0 when 'admin' then 1 else 2 end
  limit 1), true);

select public.record_payment_refund(
  'cc000000-0000-4000-8000-000000000020',
  10, 'Card', 'Second partial refund', null
) as refund_event_id;

select a.adjustment_type, a.adjustment_amount,
       a.previous_qualifying_committed_amount, a.new_qualifying_committed_amount
from public.written_sale_adjustments a
join public.written_sales ws on ws.id = a.written_sale_id
where ws.order_id = 'cc000000-0000-4000-8000-000000000010'
order by a.occurred_at;


-- ─── BLOCK 4 — VOID THE $10 REFUND: positive reversal row ────────────────
-- EXPECTED: 'refund_reversal' +10 (previous 19 -> new 29); the original two
-- 'refund' rows untouched; refund event VOIDED; total_paid back to 127.

select set_config('request.jwt.claim.sub', (
  select e.auth_user_id::text
  from public.employees e
  join public.stores st on st.company_id = e.company_id
  join public.sleep_journeys sj on sj.store_id = st.id
  where sj.id = 'cc000000-0000-4000-8000-000000000010'
    and e.role in ('owner','admin','manager')
    and e.is_active = true
  order by case e.role when 'owner' then 0 when 'admin' then 1 else 2 end
  limit 1), true);

select public.void_payment_refund(
  (select je.id from public.journey_events je
    where je.journey_id = 'cc000000-0000-4000-8000-000000000010'
      and je.event_type = 'payment_refunded'
      and je.outcome = 'SUCCEEDED'
      and (je.event_data->>'amount')::numeric = 10
    order by je.created_at desc limit 1),
  'Entered in error'
) as voided_id;

select a.adjustment_type, a.adjustment_amount,
       a.previous_qualifying_committed_amount, a.new_qualifying_committed_amount,
       a.adjustment_reason
from public.written_sale_adjustments a
join public.written_sales ws on ws.id = a.written_sale_id
where ws.order_id = 'cc000000-0000-4000-8000-000000000010'
order by a.occurred_at;

select je.outcome, je.reconciled_at is not null as reconciled
from public.journey_events je
where je.journey_id = 'cc000000-0000-4000-8000-000000000010'
  and je.event_type = 'payment_refunded'
order by je.created_at;

select public.total_paid('cc000000-0000-4000-8000-000000000010') as total_paid;


-- ─── BLOCK 5 — REFUND UNDER THE PRICE: clamped + reservation KEPT ────────
-- $120 more refunded: net paid 7 < price 49 -> journey flips to Quoted,
-- the committed clamp kicks in (adjustment is -29, not -120, so committed
-- lands exactly on 0), and the ready reservation must NOT release.
-- EXPECTED: adjustment 'refund' -29 (29 -> 0); current_state 'Quoted';
-- requirement still 'ready'/reserved 1 — note the requirement_id, block 6
-- must show the SAME row; product-A committed_quantity still 1.

select set_config('request.jwt.claim.sub', (
  select e.auth_user_id::text
  from public.employees e
  join public.stores st on st.company_id = e.company_id
  join public.sleep_journeys sj on sj.store_id = st.id
  where sj.id = 'cc000000-0000-4000-8000-000000000010'
    and e.role in ('owner','admin','manager')
    and e.is_active = true
  order by case e.role when 'owner' then 0 when 'admin' then 1 else 2 end
  limit 1), true);

select public.record_payment_refund(
  'cc000000-0000-4000-8000-000000000020',
  120, 'Card', 'Refund below paid-in-full', null
) as refund_event_id;

select a.adjustment_type, a.adjustment_amount,
       a.previous_qualifying_committed_amount, a.new_qualifying_committed_amount
from public.written_sale_adjustments a
join public.written_sales ws on ws.id = a.written_sale_id
where ws.order_id = 'cc000000-0000-4000-8000-000000000010'
order by a.occurred_at desc limit 1;

select public.total_paid('cc000000-0000-4000-8000-000000000010') as total_paid,
       sj.current_state
from public.sleep_journeys sj
where sj.id = 'cc000000-0000-4000-8000-000000000010';

select jir.id as requirement_id, jir.quantity_reserved, jir.status,
       ip.committed_quantity
from public.journey_inventory_requirements jir
join public.inventory_positions ip
  on ip.variant_id = jir.variant_id and ip.location_id = jir.location_id
 and ip.disposition = 'Prime' and ip.sublocation_id is null
where jir.journey_id = 'cc000000-0000-4000-8000-000000000010';


-- ─── BLOCK 6 — RE-PAY BACK TO PRICE: same reservation, Ready to Schedule ─
-- A $42 payment brings net paid back to 49.
-- EXPECTED: current_state 'Ready to Schedule'; the SAME requirement_id as
-- block 5, still 'ready'/reserved 1; committed still 1.

insert into public.journey_events
  (id, journey_id, event_type, outcome, event_data, triggered_by)
values ('cc000000-0000-4000-8000-000000000023',
        'cc000000-0000-4000-8000-000000000010',
        'payment_completed', 'SUCCEEDED',
        jsonb_build_object('amount', 42, 'method', 'CARD'), 'system')
on conflict (id) do nothing;

select public.total_paid('cc000000-0000-4000-8000-000000000010') as total_paid,
       sj.current_state
from public.sleep_journeys sj
where sj.id = 'cc000000-0000-4000-8000-000000000010';

select jir.id as requirement_id, jir.quantity_reserved, jir.status,
       ip.committed_quantity
from public.journey_inventory_requirements jir
join public.inventory_positions ip
  on ip.variant_id = jir.variant_id and ip.location_id = jir.location_id
 and ip.disposition = 'Prime' and ip.sublocation_id is null
where jir.journey_id = 'cc000000-0000-4000-8000-000000000010';


-- ─── BLOCK 7 — CANCEL STILL RELEASES ─────────────────────────────────────
-- Cancelling journey C (the standard journey_cancelled event path) must
-- release the reservation the refund refused to release.
-- EXPECTED: requirement 'cancelled', product-A committed back to 0,
-- journey cancelled_at set; a 'cancellation' adjustment row (0 -> 0,
-- committed was already 0).

insert into public.journey_events
  (journey_id, event_type, outcome, event_data, triggered_by)
values ('cc000000-0000-4000-8000-000000000010',
        'journey_cancelled', 'SUCCEEDED',
        jsonb_build_object('reason', 'refund-b2 verify'), 'system');

select jir.status, ip.committed_quantity,
       sj.cancelled_at is not null as cancelled
from public.journey_inventory_requirements jir
join public.inventory_positions ip
  on ip.variant_id = jir.variant_id and ip.location_id = jir.location_id
 and ip.disposition = 'Prime' and ip.sublocation_id is null
join public.sleep_journeys sj on sj.id = jir.journey_id
where jir.journey_id = 'cc000000-0000-4000-8000-000000000010';


-- ─── BLOCK 8 — REFUND AFTER CANCEL: no adjustment, no reversal ───────────
-- The written sale is already cancelled to committed 0. Recording a $7
-- refund (the remaining refundable amount on the payment) must NOT write
-- an adjustment, and voiding it must NOT write a reversal.
-- EXPECTED: refund event id returns; the adjustment list is UNCHANGED
-- from after block 7 (no new 'refund' row after the 'cancellation' row);
-- after the void, still no new rows — committed stays 0.

select set_config('request.jwt.claim.sub', (
  select e.auth_user_id::text
  from public.employees e
  join public.stores st on st.company_id = e.company_id
  join public.sleep_journeys sj on sj.store_id = st.id
  where sj.id = 'cc000000-0000-4000-8000-000000000010'
    and e.role in ('owner','admin','manager')
    and e.is_active = true
  order by case e.role when 'owner' then 0 when 'admin' then 1 else 2 end
  limit 1), true);

select public.record_payment_refund(
  'cc000000-0000-4000-8000-000000000020',
  7, 'Card', 'Refund after cancel', null
) as refund_event_id;

select a.adjustment_type, a.adjustment_amount,
       a.new_qualifying_committed_amount
from public.written_sale_adjustments a
join public.written_sales ws on ws.id = a.written_sale_id
where ws.order_id = 'cc000000-0000-4000-8000-000000000010'
order by a.occurred_at;

select public.void_payment_refund(
  (select je.id from public.journey_events je
    where je.journey_id = 'cc000000-0000-4000-8000-000000000010'
      and je.event_type = 'payment_refunded'
      and je.outcome = 'SUCCEEDED'
      and (je.event_data->>'amount')::numeric = 7
    order by je.created_at desc limit 1),
  'Checking the reversal path'
) as voided_id;

select a.adjustment_type, a.adjustment_amount,
       a.new_qualifying_committed_amount
from public.written_sale_adjustments a
join public.written_sales ws on ws.id = a.written_sale_id
where ws.order_id = 'cc000000-0000-4000-8000-000000000010'
order by a.occurred_at;


-- ─── BLOCK 9 — PARTIAL CLAMP on journey D: -29 not -40 ───────────────────
-- Journey D committed is 49. Refund $20 -> committed 29. Then refund $40:
-- the adjustment clamps to -29 (committed 0), not -40. Voiding the $40
-- refund reverses exactly +29 (committed back to 29), never the raw $40.
-- EXPECTED: rows 'refund' -20 (49->29), 'refund' -29 (29->0),
-- 'refund_reversal' +29 (0->29).

select set_config('request.jwt.claim.sub', (
  select e.auth_user_id::text
  from public.employees e
  join public.stores st on st.company_id = e.company_id
  join public.sleep_journeys sj on sj.store_id = st.id
  where sj.id = 'cc000000-0000-4000-8000-000000000011'
    and e.role in ('owner','admin','manager')
    and e.is_active = true
  order by case e.role when 'owner' then 0 when 'admin' then 1 else 2 end
  limit 1), true);

select public.record_payment_refund(
  'cc000000-0000-4000-8000-000000000021',
  20, 'Card', 'First refund on D', null
) as refund_event_id;

select public.record_payment_refund(
  'cc000000-0000-4000-8000-000000000021',
  40, 'Card', 'Refund larger than remaining committed', null
) as refund_event_id;

select a.adjustment_type, a.adjustment_amount,
       a.previous_qualifying_committed_amount, a.new_qualifying_committed_amount
from public.written_sale_adjustments a
join public.written_sales ws on ws.id = a.written_sale_id
where ws.order_id = 'cc000000-0000-4000-8000-000000000011'
order by a.occurred_at;

select public.void_payment_refund(
  (select je.id from public.journey_events je
    where je.journey_id = 'cc000000-0000-4000-8000-000000000011'
      and je.event_type = 'payment_refunded'
      and je.outcome = 'SUCCEEDED'
      and (je.event_data->>'amount')::numeric = 40
    order by je.created_at desc limit 1),
  'Reversing the clamped refund'
) as voided_id;

select a.adjustment_type, a.adjustment_amount,
       a.previous_qualifying_committed_amount, a.new_qualifying_committed_amount
from public.written_sale_adjustments a
join public.written_sales ws on ws.id = a.written_sale_id
where ws.order_id = 'cc000000-0000-4000-8000-000000000011'
order by a.occurred_at;


-- ─── BLOCK 10 — VOID AFTER CANCEL: no reversal row ───────────────────────
-- Journey D committed is 29 with one live $20 refund. Record another $20
-- refund (adjustment -20, committed 9), cancel the journey (the
-- 'cancellation' adjustment zeroes committed), then void that refund: the
-- reversal must be SKIPPED on a cancelled journey — committed stays 0.
-- EXPECTED: rows 'refund' -20 (29 -> 9) then 'cancellation' (9 -> 0); the
-- post-void select shows the refund row VOIDED with
-- reversal_rows_for_this_refund = 0 (block 9's older +29 reversal is
-- counted under its own refund's correlation_id and stays put). The final
-- full list ends at the 'cancellation' row — committed stays 0.

select set_config('request.jwt.claim.sub', (
  select e.auth_user_id::text
  from public.employees e
  join public.stores st on st.company_id = e.company_id
  join public.sleep_journeys sj on sj.store_id = st.id
  where sj.id = 'cc000000-0000-4000-8000-000000000011'
    and e.role in ('owner','admin','manager')
    and e.is_active = true
  order by case e.role when 'owner' then 0 when 'admin' then 1 else 2 end
  limit 1), true);

select public.record_payment_refund(
  'cc000000-0000-4000-8000-000000000021',
  20, 'Card', 'Refund before the cancel', null
) as refund_event_id;

select a.adjustment_type, a.adjustment_amount,
       a.previous_qualifying_committed_amount, a.new_qualifying_committed_amount
from public.written_sale_adjustments a
join public.written_sales ws on ws.id = a.written_sale_id
where ws.order_id = 'cc000000-0000-4000-8000-000000000011'
order by a.occurred_at desc limit 1;

insert into public.journey_events
  (journey_id, event_type, outcome, event_data, triggered_by)
values ('cc000000-0000-4000-8000-000000000011',
        'journey_cancelled', 'SUCCEEDED',
        jsonb_build_object('reason', 'refund-b2 verify'), 'system');

select a.adjustment_type, a.adjustment_amount,
       a.previous_qualifying_committed_amount, a.new_qualifying_committed_amount
from public.written_sale_adjustments a
join public.written_sales ws on ws.id = a.written_sale_id
where ws.order_id = 'cc000000-0000-4000-8000-000000000011'
order by a.occurred_at desc limit 1;

select public.void_payment_refund(
  (select je.id from public.journey_events je
    where je.journey_id = 'cc000000-0000-4000-8000-000000000011'
      and je.event_type = 'payment_refunded'
      and je.outcome = 'SUCCEEDED'
      and (je.event_data->>'amount')::numeric = 20
    order by je.created_at desc limit 1),
  'Voiding a refund on a cancelled journey'
) as voided_id;

select je.outcome,
       (select count(*) from public.written_sale_adjustments a
         join public.written_sales ws on ws.id = a.written_sale_id
         where ws.order_id = 'cc000000-0000-4000-8000-000000000011'
           and a.adjustment_type = 'refund_reversal'
           and a.correlation_id = je.id) as reversal_rows_for_this_refund
from public.journey_events je
where je.journey_id = 'cc000000-0000-4000-8000-000000000011'
  and je.event_type = 'payment_refunded'
order by je.created_at desc limit 1;

select a.adjustment_type, a.adjustment_amount,
       a.new_qualifying_committed_amount
from public.written_sale_adjustments a
join public.written_sales ws on ws.id = a.written_sale_id
where ws.order_id = 'cc000000-0000-4000-8000-000000000011'
order by a.occurred_at;


-- ─── BLOCK 11 — LINE EDITS STILL SUPERSEDE (unchanged behavior) ──────────
-- Journey E paid $30 of $30 (reserved, ready). Bumping the line to qty 3
-- makes it underpaid ($90 vs $30) — the default p_release_inventory=true
-- path must still supersede.
-- EXPECTED: requirement 'cancelled', product-B committed back to 0,
-- journey 'Quoted', a line_items_changed_balance_due event logged.

update public.journey_line_items
set quantity = 3
where id = 'cc000000-0000-4000-8000-000000000032';

select jir.status, ip.committed_quantity, sj.current_state
from public.journey_inventory_requirements jir
join public.inventory_positions ip
  on ip.variant_id = jir.variant_id and ip.location_id = jir.location_id
 and ip.disposition = 'Prime' and ip.sublocation_id is null
join public.sleep_journeys sj on sj.id = jir.journey_id
where jir.journey_id = 'cc000000-0000-4000-8000-000000000012';

select je.event_type, je.event_data->>'balance_due' as balance_due
from public.journey_events je
where je.journey_id = 'cc000000-0000-4000-8000-000000000012'
  and je.event_type = 'line_items_changed_balance_due'
order by je.created_at desc limit 1;


-- ─── BLOCK 12 — RECONCILE GUARD: FAILED refused while a refund exists ────
-- Journey D still has a SUCCEEDED $20 refund on its payment.
-- EXPECT ERROR: 'Void the refunds on this payment first.'

select set_config('request.jwt.claim.sub', (
  select e.auth_user_id::text
  from public.employees e
  join public.stores st on st.company_id = e.company_id
  join public.sleep_journeys sj on sj.store_id = st.id
  where sj.id = 'cc000000-0000-4000-8000-000000000011'
    and e.role in ('owner','admin','manager')
    and e.is_active = true
  order by case e.role when 'owner' then 0 when 'admin' then 1 else 2 end
  limit 1), true);

select public.reconcile_payment_event(
  'cc000000-0000-4000-8000-000000000021',
  'FAILED', 'manual', 'system', 'chargeback attempt'
);


-- ─── BLOCK 13 — RECONCILE GUARD: VOIDED refused too ──────────────────────
-- The guard covers every non-SUCCEEDED outcome, not just FAILED.
-- EXPECT ERROR: 'Void the refunds on this payment first.'

select set_config('request.jwt.claim.sub', (
  select e.auth_user_id::text
  from public.employees e
  join public.stores st on st.company_id = e.company_id
  join public.sleep_journeys sj on sj.store_id = st.id
  where sj.id = 'cc000000-0000-4000-8000-000000000011'
    and e.role in ('owner','admin','manager')
    and e.is_active = true
  order by case e.role when 'owner' then 0 when 'admin' then 1 else 2 end
  limit 1), true);

select public.reconcile_payment_event(
  'cc000000-0000-4000-8000-000000000021',
  'VOIDED', 'manual', 'system', 'entered in error'
);


-- ─── BLOCK 14 — TEARDOWN: remove all REFUND-B2 fixtures ──────────────────
-- Journeys D and E were never cancelled — cancel events release any
-- lingering requirements first (journey C was cancelled in block 7).
-- EXPECTED: remaining = 0.

insert into public.journey_events
  (journey_id, event_type, outcome, event_data, triggered_by)
select id, 'journey_cancelled', 'SUCCEEDED',
       jsonb_build_object('reason', 'refund-b2 verify teardown'), 'system'
from public.sleep_journeys
where id in ('cc000000-0000-4000-8000-000000000011',
             'cc000000-0000-4000-8000-000000000012')
  and cancelled_at is null;

delete from public.journey_line_items
where journey_id in ('cc000000-0000-4000-8000-000000000010',
                     'cc000000-0000-4000-8000-000000000011',
                     'cc000000-0000-4000-8000-000000000012');
delete from public.journey_inventory_requirements
where journey_id in ('cc000000-0000-4000-8000-000000000010',
                     'cc000000-0000-4000-8000-000000000011',
                     'cc000000-0000-4000-8000-000000000012');
delete from public.journey_events
where journey_id in ('cc000000-0000-4000-8000-000000000010',
                     'cc000000-0000-4000-8000-000000000011',
                     'cc000000-0000-4000-8000-000000000012');
delete from public.written_sale_adjustments
where order_id in ('cc000000-0000-4000-8000-000000000010',
                   'cc000000-0000-4000-8000-000000000011',
                   'cc000000-0000-4000-8000-000000000012');
delete from public.written_sales
where order_id in ('cc000000-0000-4000-8000-000000000010',
                   'cc000000-0000-4000-8000-000000000011',
                   'cc000000-0000-4000-8000-000000000012');
delete from public.inventory_positions
where variant_id in ('cc000000-0000-4000-8000-000000000002',
                     'cc000000-0000-4000-8000-000000000003');
delete from public.sleep_journeys
where id in ('cc000000-0000-4000-8000-000000000010',
             'cc000000-0000-4000-8000-000000000011',
             'cc000000-0000-4000-8000-000000000012');
delete from public.products
where id in ('cc000000-0000-4000-8000-000000000002',
             'cc000000-0000-4000-8000-000000000003');
delete from public.customers
where id = 'cc000000-0000-4000-8000-000000000001';

select count(*) as remaining
from public.customers where first_name = 'REFUND-B2';
