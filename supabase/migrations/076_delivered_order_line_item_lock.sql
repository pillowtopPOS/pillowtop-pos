-- 076_delivered_order_line_item_lock.sql
--
-- The JourneyWorkspace orderLocked rule (delivered_at set, or state in
-- Sleep Trial/Completed) hid the edit controls, but journey_line_items is
-- written by direct table access — no RPC — so any caller could still
-- rewrite a delivered order's items, quantities, or prices in place and
-- bypass the exchange flow. This trigger enforces the same rule at the
-- database layer, which also closes the gap for every other write path.
--
-- One carve-out: provision_sleep_trial_items (069) stamps
-- trial_ineligible_reason (+updated_at) on line items at delivery time,
-- inside the trial it just created. An UPDATE where every business field
-- is unchanged is allowed through so trial provisioning keeps working.
-- A future exchange flow that needs to mutate items should use a
-- dedicated function with an explicit bypass, not this table directly.

create or replace function public.guard_journey_line_item_mutation()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_journey_id uuid;
  v_delivered date;
  v_state public.journey_state;
begin
  v_journey_id := coalesce(new.journey_id, old.journey_id);

  select delivered_at, current_state
    into v_delivered, v_state
  from public.sleep_journeys
  where id = v_journey_id;

  if not found then
    return coalesce(new, old);
  end if;

  -- Pre-delivery journeys are unaffected.
  if v_delivered is null
     and v_state not in ('Sleep Trial', 'Completed') then
    return coalesce(new, old);
  end if;

  -- Delivered / trial-active / completed: business fields are frozen.
  -- System metadata updates (trial_ineligible_reason, updated_at) pass.
  if tg_op = 'UPDATE'
     and new.journey_id = old.journey_id
     and new.product_id is not distinct from old.product_id
     and new.item_name is not distinct from old.item_name
     and new.quantity is not distinct from old.quantity
     and new.unit_price is not distinct from old.unit_price
     and new.fulfillment_type_override is not distinct from old.fulfillment_type_override
     and new.pickup_location_id is not distinct from old.pickup_location_id
     and new.pair_group_id is not distinct from old.pair_group_id
     and new.sold_condition is not distinct from old.sold_condition
  then
    return new;
  end if;

  raise exception 'Cannot modify line items on a delivered journey — use the exchange flow';
end;
$$;

drop trigger if exists journey_line_items_delivered_lock on public.journey_line_items;

create trigger journey_line_items_delivered_lock
  before insert or update or delete on public.journey_line_items
  for each row execute function public.guard_journey_line_item_mutation();
