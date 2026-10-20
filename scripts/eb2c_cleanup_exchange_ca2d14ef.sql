-- ============================================================================
-- EB-2c test-data cleanup — exchange child ca2d14ef cannot be cancelled in
-- the app because its $200 payment can't be marked refunded (no such button
-- exists yet). Run each block ONE AT A TIME in the Supabase SQL editor and
-- check the "expected" notes before moving on.
--
-- Fixture facts (verified 2026-10-19):
--   child journey   ca2d14ef-d621-4228-955b-f92f992568db  price $200
--                   = replacement $950 - credit $1000 + pillow add-on $250
--   exchange action 8e110d35-68c1-4cdb-8302-e16480a0366b  COMMITTED
--   parent journey  234c5745-bdd8-4ffe-a80e-1a00ac547dc8  Sleep Trial
--   payment event   9df6909d-*  payment_completed, SUCCEEDED, $200 Cash
--
-- Tables touched: public.journey_events (outcome, reconciled_at),
-- public.payment_reconciliation_events (audit log insert),
-- public.sleep_journeys / public.journey_inventory_requirements /
-- public.sleep_trial_actions / public.sleep_trial_items (via RPCs).
--
-- NOTE on auth: reconcile_payment_event and cancel_sleep_trial_action check
-- auth.uid() for owner/admin/manager. The SQL editor has no JWT, so each
-- block first sets request.jwt.claim.sub to an admin employee of this
-- company — the same user context the app's RPC call would carry.
-- ============================================================================


-- ─── BLOCK A — LOOK, don't change anything ────────────────────────────────
-- Expected: child is Ready to Schedule, price 200, not cancelled.
select id, current_state, price, cancelled_at, sale_kind, exchange_action_id
from public.sleep_journeys
where id = 'ca2d14ef-d621-4228-955b-f92f992568db';

-- Expected: status COMMITTED, refund_owed_cents 0, refund_recorded_at null.
select id, status, action, journey_id, child_journey_id,
       net_cents, refund_owed_cents, refund_recorded_at
from public.sleep_trial_actions
where id = '8e110d35-68c1-4cdb-8302-e16480a0366b';

-- Expected: exactly one payment row — payment_completed, SUCCEEDED, $200.
-- This row is why the app's Cancel refuses ("payment on record").
select id, event_type, outcome, reconciled_at, event_data, created_at
from public.journey_events
where journey_id = 'ca2d14ef-d621-4228-955b-f92f992568db'
  and event_type in ('deposit_received', 'payment_completed');


-- ─── BLOCK B — mark the $200 payment REFUNDED ─────────────────────────────
-- Same thing the app's Reconcile dialog does (reconcile_payment_event with
-- outcome 'REFUNDED'), then the balance/inventory re-evaluation a real
-- refund SHOULD trigger — today's reconcile function only re-evaluates on
-- SUCCEEDED, so without these two calls the child would still read "paid".
select set_config('request.jwt.claim.sub', (
  select e.auth_user_id::text
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  join public.sleep_journeys sj on sj.store_id = s.id
  where sj.id = 'ca2d14ef-d621-4228-955b-f92f992568db'
    and e.auth_user_id is not null
    and e.role::text in ('owner', 'admin', 'manager')
  order by e.created_at
  limit 1
), true);

select public.reconcile_payment_event(
  '9df6909d-01f0-4774-8b12-9c96ac8a9bac',
  'REFUNDED',
  'manual',
  'zach-sql-cleanup',
  'Test cleanup: marking $200 payment refunded so the exchange can be cancelled'
);

-- What a refund button should also do (see report): recompute balance and
-- release the reservations the payment had justified.
select public.reevaluate_journey_balance('ca2d14ef-d621-4228-955b-f92f992568db');
select public.evaluate_journey_inventory('ca2d14ef-d621-4228-955b-f92f992568db');

-- Expected after Block B:
--   - the payment row: outcome REFUNDED, reconciled_at set
--   - one new payment_reconciliation_events row SUCCEEDED -> REFUNDED
--   - child flips Ready to Schedule -> Quoted (balance $200 due again)
--   - the two 'ready' requirements go 'superseded' (stock released)
-- Check:
select id, outcome, reconciled_at from public.journey_events
where journey_id = 'ca2d14ef-d621-4228-955b-f92f992568db'
  and event_type = 'payment_completed';
select previous_outcome, new_outcome, reconciliation_source, actor_id, notes
from public.payment_reconciliation_events
where payment_id in (
  select id from public.journey_events
  where journey_id = 'ca2d14ef-d621-4228-955b-f92f992568db'
    and event_type = 'payment_completed');
select status, count(*) from public.journey_inventory_requirements
where journey_id = 'ca2d14ef-d621-4228-955b-f92f992568db' group by status;


-- ─── BLOCK C — cancel the exchange (same RPC the app's Cancel uses) ───────
-- With no SUCCEEDED payment left, cancel_sleep_trial_action's guard passes.
-- It cancels the child journey (journey_cancelled event -> cancelled_at),
-- releases its requirements, and returns the original trial item to ACTIVE.
select set_config('request.jwt.claim.sub', (
  select e.auth_user_id::text
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  join public.sleep_journeys sj on sj.store_id = s.id
  where sj.id = 'ca2d14ef-d621-4228-955b-f92f992568db'
    and e.auth_user_id is not null
    and e.role::text in ('owner', 'admin', 'manager')
  order by e.created_at
  limit 1
), true);

select public.cancel_sleep_trial_action(
  '8e110d35-68c1-4cdb-8302-e16480a0366b',
  'Test cleanup: removing committed test exchange (paid $200 pillow line refunded first)'
);


-- ─── BLOCK D — verify ─────────────────────────────────────────────────────
-- Expected: action CANCELLED with cancelled_at + reason.
select id, status, cancelled_at, cancel_reason
from public.sleep_trial_actions
where id = '8e110d35-68c1-4cdb-8302-e16480a0366b';

-- Expected: child cancelled_at set (state may keep showing its last label);
-- parent UNCHANGED — still Sleep Trial, not cancelled.
select id, current_state, cancelled_at from public.sleep_journeys
where id in (
  'ca2d14ef-d621-4228-955b-f92f992568db',
  '234c5745-bdd8-4ffe-a80e-1a00ac547dc8');

-- Expected: every child requirement superseded/cancelled — none pending|ready.
select status, count(*) from public.journey_inventory_requirements
where journey_id = 'ca2d14ef-d621-4228-955b-f92f992568db' group by status;

-- Expected: the original trial item back to ACTIVE (no longer
-- EXCHANGE_IN_PROGRESS).
select id, status from public.sleep_trial_items
where id = (
  select trial_item_id from public.sleep_trial_actions
  where id = '8e110d35-68c1-4cdb-8302-e16480a0366b');
