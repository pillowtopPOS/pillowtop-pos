-- PillowTop POS m121: defer the requirement-row observers to commit
--
-- TWO per-row triggers on journey_inventory_requirements fire the instant
-- a requirement row is inserted or its quantity_required / location_id /
-- status / quantity_reserved changes — i.e. in the MIDDLE of
-- evaluate_journey_inventory, before that function's own reserve loop
-- has run:
--
--   trg_jm_requirement_sync (114) -> jm_requirement_sync ->
--     sync_requirement_request: sees quantity_reserved stale (0 on
--     insert, old value on a qty increase), computes a phantom uncovered
--     shortfall and creates a journey_mismatch request + warehouse hold.
--
--   trg_jir_units_observer (109) -> observe_requirement_units ->
--     reconcile_requirement_units, whose FIRST statement is
--     sync_requirement_request (117): the same phantom, reached through
--     the unit observer. (Its unit work self-corrects because
--     quantity_reserved updates re-fire it, but the request it creates
--     mid-flight does not.)
--
-- Seconds later the reserve loop's status/quantity_reserved update
-- re-fires the triggers, the shortfall computes as covered, and
-- release_jm_request cancels the request — leaving a cancelled request
-- row and a "Transfer requested" timeline line on orders that never
-- needed a transfer (SJ-MS00135 creation, qty edit, Quoted->paid;
-- SJ-MS00132).
--
-- Fix: make BOTH triggers DEFERRABLE CONSTRAINT TRIGGERs
-- (initially deferred). Nothing fires at row-write time; at COMMIT each
-- queued row fires its function once, when quantity_reserved, unit
-- assignments and journey state all reflect the finished transaction.
-- A covered order then computes shortfall = 0 and no request is ever
-- created; a genuinely uncovered order still gets exactly one request,
-- with correct quantity and hold, in the same transaction.
--
-- Safety of deferring the unit observer: evaluate_journey_inventory
-- never reads the units table — it reserves via inventory_positions
-- (on_hand - committed) and journey_inventory_requirements only. No
-- code path reads unit status/assigned_requirement_id after a
-- requirement write within the same transaction; receive/ship flows
-- assign or move units explicitly by id. Unit assignment therefore
-- only needs to be correct at commit, which is when it now runs.
--
-- Notes:
--  * jm_journey_state_sync and trg_sj_units_observer stay immediate:
--    they key off the sleep_journeys row (current_state/cancelled_at),
--    which is already updated when they fire, and they cover the
--    Quoted/cancel transitions the row triggers cannot see.
--  * Direct callers of reconcile_requirement_units (unassign_unit,
--    observe_journey_units, the 109 backfill) and of
--    sync_requirement_request / sync_order_transfer / cancel_transfer
--    are unaffected — they run outside evaluate's mid-flight window.
--  * If any code issues SET CONSTRAINTS ALL IMMEDIATE the observers
--    would fire early again — nothing in the codebase does.

drop trigger if exists trg_jm_requirement_sync on public.journey_inventory_requirements;
drop trigger if exists trg_jir_units_observer on public.journey_inventory_requirements;

create constraint trigger trg_jm_requirement_sync
  after insert or update of quantity_required, location_id, status
  on public.journey_inventory_requirements
  deferrable initially deferred
  for each row execute function public.jm_requirement_sync();

create constraint trigger trg_jir_units_observer
  after insert or update of status, quantity_reserved, quantity_required
  on public.journey_inventory_requirements
  deferrable initially deferred
  for each row execute function public.observe_requirement_units();
