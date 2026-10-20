-- ============================================================================
-- refunds-b1 — verify migrations 096 + 097 in the Supabase SQL editor
--
-- IMPORTANT: the editor only shows the LAST statement's result, so run each
-- labeled block ONE AT A TIME. All fixture ids are fixed UUIDs prefixed
-- bb000000 so the blocks are independent and teardown is simple.
--
-- Fixture design: lines have product_id NULL (a catalog-less service line),
-- so no inventory requirement is ever created and state transitions stay
-- purely about money: payment -> Sold/Ready, refund under the total ->
-- Quoted, voided refund -> back up. The exchange fixture (block 8) is a
-- fabricated COMMITTED action + child journey, not a real quoted exchange.
--
-- Blocks marked EXPECT ERROR are supposed to raise; a success means a bug.
-- Impersonation uses the set_config('request.jwt.claim.sub', ...) pattern
-- from the EB-2c cleanup script so security-definer RPCs see an employee.
--
-- Run order: 0, 1, 2, 3, 4, 5, 6, 7, 8a, 8b, 8c, 9.
-- ============================================================================


-- ─── BLOCK 0 — SETUP ─────────────────────────────────────────────────────
-- Customer, journey A ($49 line + $147 payment), journey B ($49 line + $49
-- payment), and an exchange fixture on A: trial item EXCHANGE_IN_PROGRESS,
-- COMMITTED action, child journey with a $200 payment.
-- The payment_completed inserts fire zz_inventory_event_hook -> evaluate;
-- with no product lines the only effect is the derive-trigger Sold flip.
--
-- EXPECTED (final select): 8 fixture ids listed.

insert into public.customers (id, first_name, last_name, phone, email)
values ('bb000000-0000-4000-8000-000000000001', 'REFUND-TEST', 'Customer',
        '000-000-0000', 'refund-test@example.com')
on conflict (id) do nothing;

insert into public.sleep_journeys (id, customer_id, store_id, fulfillment_type)
select 'bb000000-0000-4000-8000-000000000003',
       'bb000000-0000-4000-8000-000000000001', s.id, 'pickup'
from public.stores s order by s.created_at limit 1
on conflict (id) do nothing;

insert into public.journey_line_items
  (id, journey_id, item_name, quantity, unit_price)
values ('bb000000-0000-4000-8000-000000000010',
        'bb000000-0000-4000-8000-000000000003',
        'REFUND-TEST service', 1, 49)
on conflict (id) do nothing;

insert into public.journey_events
  (id, journey_id, event_type, outcome, event_data, triggered_by)
values ('bb000000-0000-4000-8000-000000000020',
        'bb000000-0000-4000-8000-000000000003',
        'payment_completed', 'SUCCEEDED',
        jsonb_build_object('amount', 147, 'method', 'CARD'), 'system')
on conflict (id) do nothing;

insert into public.sleep_journeys (id, customer_id, store_id, fulfillment_type)
select 'bb000000-0000-4000-8000-000000000004',
       'bb000000-0000-4000-8000-000000000001', s.id, 'pickup'
from public.stores s order by s.created_at limit 1
on conflict (id) do nothing;

insert into public.journey_line_items
  (id, journey_id, item_name, quantity, unit_price)
values ('bb000000-0000-4000-8000-000000000011',
        'bb000000-0000-4000-8000-000000000004',
        'REFUND-TEST service', 1, 49)
on conflict (id) do nothing;

insert into public.journey_events
  (id, journey_id, event_type, outcome, event_data, triggered_by)
values ('bb000000-0000-4000-8000-000000000021',
        'bb000000-0000-4000-8000-000000000004',
        'payment_completed', 'SUCCEEDED',
        jsonb_build_object('amount', 49, 'method', 'CARD'), 'system')
on conflict (id) do nothing;

-- Exchange fixture on journey A.
insert into public.sleep_trial_items (id, company_id, journey_id, customer_id, status)
select 'bb000000-0000-4000-8000-000000000030', st.company_id,
       'bb000000-0000-4000-8000-000000000003',
       'bb000000-0000-4000-8000-000000000001', 'EXCHANGE_IN_PROGRESS'
from public.stores st
join public.sleep_journeys sj on sj.store_id = st.id
where sj.id = 'bb000000-0000-4000-8000-000000000003'
on conflict (id) do nothing;

insert into public.sleep_journeys
  (id, customer_id, store_id, fulfillment_type, sale_kind, parent_journey_id)
select 'bb000000-0000-4000-8000-000000000005',
       'bb000000-0000-4000-8000-000000000001', sj.store_id, 'pickup',
       'EXCHANGE', 'bb000000-0000-4000-8000-000000000003'
from public.sleep_journeys sj
where sj.id = 'bb000000-0000-4000-8000-000000000003'
on conflict (id) do nothing;

insert into public.sleep_trial_actions
  (id, company_id, journey_id, trial_item_id, action, status, child_journey_id)
select 'bb000000-0000-4000-8000-000000000040', st.company_id,
       'bb000000-0000-4000-8000-000000000003',
       'bb000000-0000-4000-8000-000000000030',
       'EXCHANGE', 'COMMITTED',
       'bb000000-0000-4000-8000-000000000005'
from public.stores st
join public.sleep_journeys sj on sj.store_id = st.id
where sj.id = 'bb000000-0000-4000-8000-000000000003'
on conflict (id) do nothing;

update public.sleep_journeys
set exchange_action_id = 'bb000000-0000-4000-8000-000000000040'
where id = 'bb000000-0000-4000-8000-000000000005'
  and exchange_action_id is null;

insert into public.journey_events
  (id, journey_id, event_type, outcome, event_data, triggered_by)
values ('bb000000-0000-4000-8000-000000000022',
        'bb000000-0000-4000-8000-000000000005',
        'payment_completed', 'SUCCEEDED',
        jsonb_build_object('amount', 200, 'method', 'CARD'), 'system')
on conflict (id) do nothing;

select 'journey_a' as label, id from public.sleep_journeys
 where id = 'bb000000-0000-4000-8000-000000000003'
union all select 'journey_b', 'bb000000-0000-4000-8000-000000000004'
union all select 'child', 'bb000000-0000-4000-8000-000000000005'
union all select 'trial_item', 'bb000000-0000-4000-8000-000000000030'
union all select 'action', 'bb000000-0000-4000-8000-000000000040'
union all select 'payment_a', 'bb000000-0000-4000-8000-000000000020'
union all select 'payment_b', 'bb000000-0000-4000-8000-000000000021'
union all select 'payment_child', 'bb000000-0000-4000-8000-000000000022';


-- ─── BLOCK 1 — BASELINE ──────────────────────────────────────────────────
-- EXPECTED: total_paid 147 (price 49 -> overpaid by 98).

select public.total_paid('bb000000-0000-4000-8000-000000000003') as total_paid;


-- ─── BLOCK 2 — PARTIAL REFUND $98 ────────────────────────────────────────
-- EXPECTED: refund event id uuid, then total_paid 49.

select set_config('request.jwt.claim.sub', (
  select e.auth_user_id::text
  from public.employees e
  join public.stores st on st.company_id = e.company_id
  join public.sleep_journeys sj on sj.store_id = st.id
  where sj.id = 'bb000000-0000-4000-8000-000000000003'
    and e.role in ('owner','admin','manager')
    and e.is_active = true
  order by case e.role when 'owner' then 0 when 'admin' then 1 else 2 end
  limit 1), true);

select public.record_payment_refund(
  'bb000000-0000-4000-8000-000000000020',
  98, 'Card', 'Order total reduced after purchase', 'rf-1001'
) as refund_event_id;

select public.total_paid('bb000000-0000-4000-8000-000000000003') as total_paid;


-- ─── BLOCK 3 — CAP: only $49 remains refundable on that payment ──────────
-- EXPECT ERROR: 'This refund is more than what was paid on that payment.'
-- A successful return here means the cap is broken.

select set_config('request.jwt.claim.sub', (
  select e.auth_user_id::text
  from public.employees e
  join public.stores st on st.company_id = e.company_id
  join public.sleep_journeys sj on sj.store_id = st.id
  where sj.id = 'bb000000-0000-4000-8000-000000000003'
    and e.role in ('owner','admin','manager')
    and e.is_active = true
  order by case e.role when 'owner' then 0 when 'admin' then 1 else 2 end
  limit 1), true);

select public.record_payment_refund(
  'bb000000-0000-4000-8000-000000000020',
  50, 'Card', 'Should fail', null
);


-- ─── BLOCK 4 — REFUND THE REMAINING $49 ──────────────────────────────────
-- EXPECTED: refund event id uuid, then total_paid 0 and journey re-evaluated
-- out of Sold (current_state 'Quoted' — paid < price).

select set_config('request.jwt.claim.sub', (
  select e.auth_user_id::text
  from public.employees e
  join public.stores st on st.company_id = e.company_id
  join public.sleep_journeys sj on sj.store_id = st.id
  where sj.id = 'bb000000-0000-4000-8000-000000000003'
    and e.role in ('owner','admin','manager')
    and e.is_active = true
  order by case e.role when 'owner' then 0 when 'admin' then 1 else 2 end
  limit 1), true);

select public.record_payment_refund(
  'bb000000-0000-4000-8000-000000000020',
  49, 'Card', 'Remaining balance refunded', null
) as refund_event_id;

select public.total_paid('bb000000-0000-4000-8000-000000000003') as total_paid,
       sj.current_state
from public.sleep_journeys sj
where sj.id = 'bb000000-0000-4000-8000-000000000003';


-- ─── BLOCK 5 — VOID THE $49 REFUND ───────────────────────────────────────
-- EXPECTED: total_paid back to 49, journey Sold/Ready again, the refund row
-- VOIDED with reconciled_at set, and one payment_reconciliation_events row
-- SUCCEEDED -> VOIDED.

select set_config('request.jwt.claim.sub', (
  select e.auth_user_id::text
  from public.employees e
  join public.stores st on st.company_id = e.company_id
  join public.sleep_journeys sj on sj.store_id = st.id
  where sj.id = 'bb000000-0000-4000-8000-000000000003'
    and e.role in ('owner','admin','manager')
    and e.is_active = true
  order by case e.role when 'owner' then 0 when 'admin' then 1 else 2 end
  limit 1), true);

select public.void_payment_refund(
  (select je.id from public.journey_events je
    where je.journey_id = 'bb000000-0000-4000-8000-000000000003'
      and je.event_type = 'payment_refunded'
      and je.outcome = 'SUCCEEDED'
      and (je.event_data->>'amount')::numeric = 49
    order by je.created_at desc limit 1),
  'Refund was entered twice'
) as voided_id;

select public.total_paid('bb000000-0000-4000-8000-000000000003') as total_paid,
       sj.current_state
from public.sleep_journeys sj
where sj.id = 'bb000000-0000-4000-8000-000000000003';

select je.id, je.outcome, je.reconciled_at is not null as reconciled
from public.journey_events je
where je.journey_id = 'bb000000-0000-4000-8000-000000000003'
  and je.event_type = 'payment_refunded'
order by je.created_at;

select r.previous_outcome, r.new_outcome, r.notes
from public.payment_reconciliation_events r
join public.journey_events je on je.id = r.payment_id
where je.journey_id = 'bb000000-0000-4000-8000-000000000003'
order by r.reconciled_at;


-- ─── BLOCK 6 — PERMISSION: non-manager employee refused ──────────────────
-- EXPECT ERROR: 'Only owner, admin, or manager may record a refund'
-- If the impersonation subquery returns null (no non-manager employee in
-- the company), skip this block — check first with the standalone select:
--   select e.role from employees e
--   join stores st on st.company_id = e.company_id
--   join sleep_journeys sj on sj.store_id = st.id
--   where sj.id = 'bb000000-0000-4000-8000-000000000003'
--     and e.role not in ('owner','admin','manager') and e.is_active;

select set_config('request.jwt.claim.sub', (
  select e.auth_user_id::text
  from public.employees e
  join public.stores st on st.company_id = e.company_id
  join public.sleep_journeys sj on sj.store_id = st.id
  where sj.id = 'bb000000-0000-4000-8000-000000000003'
    and e.role not in ('owner','admin','manager')
    and e.is_active = true
  limit 1), true);

select public.record_payment_refund(
  'bb000000-0000-4000-8000-000000000021',
  10, 'Cash', 'Should be refused', null
);


-- ─── BLOCK 7 — DELIVERED JOURNEY: refund records, state untouched ────────
-- First select EXPECTED: delivered=true, current_state 'Sleep Trial'.
-- After the $10 refund: total_paid 39, delivered still true, current_state
-- unchanged ('Sleep Trial') — refund must NOT rewrite state or touch stock.

insert into public.journey_events (journey_id, event_type, outcome, event_data, triggered_by)
values ('bb000000-0000-4000-8000-000000000023',
        'bb000000-0000-4000-8000-000000000004',
        'delivery_completed', 'SUCCEEDED', '{}'::jsonb, 'system')
on conflict (id) do nothing;

select sj.delivered_at is not null as delivered, sj.current_state
from public.sleep_journeys sj
where sj.id = 'bb000000-0000-4000-8000-000000000004';

select set_config('request.jwt.claim.sub', (
  select e.auth_user_id::text
  from public.employees e
  join public.stores st on st.company_id = e.company_id
  join public.sleep_journeys sj on sj.store_id = st.id
  where sj.id = 'bb000000-0000-4000-8000-000000000003'
    and e.role in ('owner','admin','manager')
    and e.is_active = true
  order by case e.role when 'owner' then 0 when 'admin' then 1 else 2 end
  limit 1), true);

select public.record_payment_refund(
  'bb000000-0000-4000-8000-000000000021',
  10, 'Cash', 'Goodwill refund after delivery', null
) as refund_event_id;

select public.total_paid('bb000000-0000-4000-8000-000000000004') as total_paid,
       sj.delivered_at is not null as delivered, sj.current_state
from public.sleep_journeys sj
where sj.id = 'bb000000-0000-4000-8000-000000000004';


-- ─── BLOCK 8a — EXCHANGE CANCEL BLOCKED WHILE CHILD IS PAID ──────────────
-- EXPECT ERROR: 'The replacement has a payment on record — resolve it
-- before cancelling the exchange.' (Cancel BEFORE refunding must fail.)

select set_config('request.jwt.claim.sub', (
  select e.auth_user_id::text
  from public.employees e
  join public.stores st on st.company_id = e.company_id
  join public.sleep_journeys sj on sj.store_id = st.id
  where sj.id = 'bb000000-0000-4000-8000-000000000003'
    and e.role in ('owner','admin','manager')
    and e.is_active = true
  order by case e.role when 'owner' then 0 when 'admin' then 1 else 2 end
  limit 1), true);

select public.cancel_sleep_trial_action(
  'bb000000-0000-4000-8000-000000000040',
  'Customer changed their mind'
);


-- ─── BLOCK 8b — REFUND THE CHILD'S $200 PAYMENT ──────────────────────────
-- EXPECTED: refund id uuid, then child total_paid 0.

select set_config('request.jwt.claim.sub', (
  select e.auth_user_id::text
  from public.employees e
  join public.stores st on st.company_id = e.company_id
  join public.sleep_journeys sj on sj.store_id = st.id
  where sj.id = 'bb000000-0000-4000-8000-000000000003'
    and e.role in ('owner','admin','manager')
    and e.is_active = true
  order by case e.role when 'owner' then 0 when 'admin' then 1 else 2 end
  limit 1), true);

select public.record_payment_refund(
  'bb000000-0000-4000-8000-000000000022',
  200, 'Card', 'Exchange cancelled — payment refunded', null
) as refund_event_id;

select public.total_paid('bb000000-0000-4000-8000-000000000005') as child_total_paid;


-- ─── BLOCK 8c — CANCEL NOW SUCCEEDS ──────────────────────────────────────
-- EXPECTED: action status CANCELLED, child cancelled, trial item ACTIVE.

select set_config('request.jwt.claim.sub', (
  select e.auth_user_id::text
  from public.employees e
  join public.stores st on st.company_id = e.company_id
  join public.sleep_journeys sj on sj.store_id = st.id
  where sj.id = 'bb000000-0000-4000-8000-000000000003'
    and e.role in ('owner','admin','manager')
    and e.is_active = true
  order by case e.role when 'owner' then 0 when 'admin' then 1 else 2 end
  limit 1), true);

select public.cancel_sleep_trial_action(
  'bb000000-0000-4000-8000-000000000040',
  'Customer changed their mind'
) as cancelled_action_id;

select a.status as action_status,
       (select sj.cancelled_at is not null from public.sleep_journeys sj
         where sj.id = 'bb000000-0000-4000-8000-000000000005') as child_cancelled,
       (select ti.status from public.sleep_trial_items ti
         where ti.id = 'bb000000-0000-4000-8000-000000000030') as item_status
from public.sleep_trial_actions a
where a.id = 'bb000000-0000-4000-8000-000000000040';


-- ─── BLOCK 9 — TEARDOWN ──────────────────────────────────────────────────
-- Deletes every fixture row. Journeys cascade events, lines, requirements,
-- trial items and actions; the customer delete must come last.
-- EXPECTED: remaining = 0.

delete from public.sleep_journeys
where id in ('bb000000-0000-4000-8000-000000000003',
             'bb000000-0000-4000-8000-000000000004',
             'bb000000-0000-4000-8000-000000000005');

delete from public.customers
where id = 'bb000000-0000-4000-8000-000000000001';

select count(*) as remaining
from public.sleep_journeys sj
join public.customers cu on cu.id = sj.customer_id
where cu.first_name = 'REFUND-TEST';
