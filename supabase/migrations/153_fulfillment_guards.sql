-- 153_fulfillment_guards.sql
-- Slice 2 (per-item fulfillment) step 4: edit and cancel guards.
--
-- Once record_journey_fulfillment starts writing journey_fulfillment_units
-- rows (activated in a later migration), handed-over units are immutable
-- history. These guards keep line edits and order cancellation from
-- rewriting that history. Journeys and lines with zero fulfillment-unit rows
-- behave exactly as today; this migration alone changes nothing observable.
--
-- Guards:
--   1. journey_cancelled is refused when the journey has any row in
--      journey_fulfillment_units. Legacy delivered orders with no
--      fulfillment rows are NOT blocked by this migration.
--   2a. Deleting a journey_line_items row that has fulfillment units is
--       refused.
--   2b. Lowering a line's quantity below its handed-over count is refused.
--       Raising quantity and editing other fields stay allowed.
--   2c. Changing a line's product_id on a line with fulfillment units is
--       refused.
--
-- Rollback: drop triggers trg_guard_journey_cancel_fulfillment and
-- trg_guard_line_item_fulfillment, then drop functions
-- guard_journey_cancel_fulfillment() and guard_line_item_fulfillment().

create or replace function public.guard_journey_cancel_fulfillment()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.event_type = 'journey_cancelled'
     and exists (
       select 1 from public.journey_fulfillment_units jfu
       where jfu.journey_id = new.journey_id
     ) then
    raise exception 'Some items on this order were already handed over. Returns and refunds are handled item by item.';
  end if;
  return new;
end;
$$;

revoke execute on function public.guard_journey_cancel_fulfillment()
  from public, anon, authenticated;

drop trigger if exists trg_guard_journey_cancel_fulfillment on public.journey_events;
create trigger trg_guard_journey_cancel_fulfillment
  before insert on public.journey_events
  for each row execute function public.guard_journey_cancel_fulfillment();

create or replace function public.guard_line_item_fulfillment()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_fulfilled integer;
begin
  if tg_op = 'DELETE' then
    if exists (
      select 1 from public.journey_fulfillment_units jfu
      where jfu.line_item_id = old.id
    ) then
      raise exception 'This item was already handed over and cannot be removed.';
    end if;
    return old;
  end if;

  select count(*) into v_fulfilled
  from public.journey_fulfillment_units jfu
  where jfu.line_item_id = new.id;

  if v_fulfilled = 0 then
    return new;
  end if;

  if tg_op = 'UPDATE' then
    if new.product_id is distinct from old.product_id then
      raise exception 'This item was already handed over and cannot be changed.';
    end if;
    if new.quantity < v_fulfilled then
      raise exception 'This item was already handed over, so the quantity cannot go below the number handed over.';
    end if;
  end if;

  return new;
end;
$$;

revoke execute on function public.guard_line_item_fulfillment()
  from public, anon, authenticated;

drop trigger if exists trg_guard_line_item_fulfillment on public.journey_line_items;
create trigger trg_guard_line_item_fulfillment
  before delete or update of quantity, product_id on public.journey_line_items
  for each row execute function public.guard_line_item_fulfillment();
