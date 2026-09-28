-- Lock fulfillment_type on delivered journeys (companion to 076).
--
-- Same hole as the line-item lock: `updateJourneyFulfillment` writes
-- sleep_journeys.fulfillment_type directly (no RPC), so the frontend's
-- orderLocked gate is UI-only. Once delivered, whether an order was
-- delivered or picked up is a historical fact; it should never change.
--
-- A BEFORE UPDATE OF fulfillment_type column trigger fires only when
-- this column is in the SET list, so the constant churn of journey
-- updates (state transitions, reassignments, delivery address edits,
-- provisioning metadata) never touches it.
create or replace function public.guard_delivered_fulfillment_type()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- No-op when the column is written but not changed (defensive —
  -- `update of` should already filter these, but row-level triggers
  -- can fire on `set x = x` writes too).
  if new.fulfillment_type is not distinct from old.fulfillment_type then
    return new;
  end if;

  -- The row being updated IS the journey — check its post-update
  -- state, so a fulfillment change bundled into the delivery
  -- transition itself is also blocked.
  if new.delivered_at is not null
     or new.current_state in ('Sleep Trial', 'Completed') then
    raise exception 'Cannot change fulfillment type on a delivered journey';
  end if;

  return new;
end;
$$;

drop trigger if exists sleep_journeys_delivered_fulfillment_lock on public.sleep_journeys;

create trigger sleep_journeys_delivered_fulfillment_lock
  before update of fulfillment_type on public.sleep_journeys
  for each row execute function public.guard_delivered_fulfillment_type();
