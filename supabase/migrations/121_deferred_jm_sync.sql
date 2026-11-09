-- PillowTop POS m121: defer the journey_mismatch request sync to commit
--
-- trg_jm_requirement_sync (114) is a per-row AFTER trigger on
-- journey_inventory_requirements. It fires the instant a requirement row
-- is inserted or its quantity_required/location_id/status changes —
-- i.e. in the MIDDLE of evaluate_journey_inventory, before that function's
-- own reserve loop has run. At that moment quantity_reserved is stale
-- (0 on insert, old value on a qty increase), so sync_requirement_request
-- computes a phantom uncovered shortfall and creates a journey_mismatch
-- request + warehouse hold. Seconds later the reserve loop's status
-- update re-fires the trigger, the shortfall computes as covered, and
-- release_jm_request cancels the request — leaving a cancelled request
-- row and a "Transfer requested" timeline line on orders that never
-- needed a transfer (SJ-MS00135, SJ-MS00132).
--
-- Fix: make the trigger a DEFERRABLE CONSTRAINT TRIGGER
-- (initially deferred). Nothing fires at row-write time; at COMMIT each
-- queued row fires jm_requirement_sync once, when quantity_reserved and
-- assigned units reflect the finished evaluation. A covered order then
-- computes shortfall = 0 and no request is ever created; a genuinely
-- uncovered order still gets exactly one request, with correct quantity
-- and hold, in the same transaction.
--
-- This is general: it covers creation+payment, quantity increases on
-- paid orders, and Quoted-to-paid flips — every path funnels through
-- evaluate_journey_inventory's insert/update of requirement rows.
--
-- Notes:
--  * jm_journey_state_sync (the Quoted-cancel trigger on sleep_journeys)
--    is a separate row trigger and stays immediate — it keys off the
--    journey row itself, which is already updated when it fires.
--  * Direct callers of sync_requirement_request / sync_order_transfer /
--    reconcile_requirement_units / cancel_transfer are unaffected.
--  * If any code issues SET CONSTRAINTS ALL IMMEDIATE the sync would
--    fire early again — nothing in the codebase does.

drop trigger if exists trg_jm_requirement_sync on public.journey_inventory_requirements;

create constraint trigger trg_jm_requirement_sync
  after insert or update of quantity_required, location_id, status
  on public.journey_inventory_requirements
  deferrable initially deferred
  for each row execute function public.jm_requirement_sync();
