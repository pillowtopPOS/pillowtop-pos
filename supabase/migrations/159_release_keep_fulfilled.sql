-- 159_release_keep_fulfilled.sql
-- Slice 2 follow-up: releases must keep handed-over units.
--
-- Three functions release a requirement's FULL quantity_reserved from
-- committed stock and mark the row superseded:
--   supersede_journey_inventory_reservations (latest: m033:5-31)
--   rebuild_journey_inventory_reservations   (latest: m032:49-64)
--   handle_journey_fulfillment_change        (latest: m031:243-263)
-- After a partial handover that double-releases units that already left
-- (committed can go negative) and the next evaluation re-reserves them.
--
-- This migration adds release_journey_reservations_keep_fulfilled, which
-- releases only the unfulfilled remainder of each live requirement row
-- and keeps rows with handed-over units live (quantity_reserved shrinks
-- to quantity_fulfilled instead of the row going superseded). The three
-- functions keep their signatures, security settings and grants; their
-- release loops now delegate to the helper.
--
-- It also freezes what a handover recorded: fulfillment_type_override
-- and pickup_location_id on a handed-over line (guard extended from m153),
-- and fulfillment_type / store_id on a journey with handed-over units.
--
-- Rollback: restore the three functions and guard_line_item_fulfillment
-- from their source migrations (031, 032, 033, 153), drop function
-- public.release_journey_reservations_keep_fulfilled(uuid), drop trigger
-- trg_guard_journey_fulfillment_method and function
-- guard_journey_fulfillment_method().

-- ---------------------------------------------------------------------------
-- Helper: release only what is still reserved for units that have not left.
-- Called by the three rewrites below under their existing journey-level lock.
-- ---------------------------------------------------------------------------
create or replace function public.release_journey_reservations_keep_fulfilled(
  p_journey_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
  v_outstanding integer;
begin
  for r in
    select * from public.journey_inventory_requirements
    where journey_id = p_journey_id and status in ('pending', 'ready')
    order by variant_id, location_id
    for update
  loop
    v_outstanding := greatest(
      r.quantity_reserved - coalesce(r.quantity_fulfilled, 0),
      0
    );
    if v_outstanding > 0 then
      perform pg_advisory_xact_lock(hashtextextended(r.variant_id::text || ':' || r.location_id::text || ':Prime', 7137));
      update public.inventory_positions
      set committed_quantity = greatest(0, committed_quantity - v_outstanding),
          updated_at = now()
      where variant_id = r.variant_id
        and location_id = r.location_id
        and disposition = 'Prime'
        and sublocation_id is null;
    end if;
    if coalesce(r.quantity_fulfilled, 0) = 0 then
      -- No handed-over units: today's behavior, the row is done.
      update public.journey_inventory_requirements
      set status = 'superseded'
      where id = r.id;
    else
      -- The row stays live as the record of units already handed over;
      -- its reservation shrinks to exactly what was consumed. When units
      -- are still outstanding the row goes back to 'pending' so the next
      -- evaluation tops it up for only the unfulfilled units; when
      -- quantity_required equals quantity_fulfilled the status is kept.
      update public.journey_inventory_requirements
      set quantity_reserved = coalesce(r.quantity_fulfilled, 0),
          status = case when r.quantity_required > coalesce(r.quantity_fulfilled, 0) then 'pending' else r.status end
      where id = r.id;
    end if;
  end loop;
end;
$$;

revoke execute on function public.release_journey_reservations_keep_fulfilled(uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- supersede_journey_inventory_reservations: same journey lock, release via
-- the helper. Previously released the full quantity_reserved (m033:5-31).
-- ---------------------------------------------------------------------------
create or replace function public.supersede_journey_inventory_reservations(p_journey_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
begin
  perform pg_advisory_xact_lock(hashtextextended(p_journey_id::text, 7137));
  perform public.release_journey_reservations_keep_fulfilled(p_journey_id);
end;
$$;
revoke execute on function public.supersede_journey_inventory_reservations(uuid) from authenticated, anon;

-- ---------------------------------------------------------------------------
-- rebuild_journey_inventory_reservations: same journey lock, release via the
-- helper, then re-evaluate exactly as before (m032:49-64).
-- ---------------------------------------------------------------------------
create or replace function public.rebuild_journey_inventory_reservations(p_journey_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
begin
  perform pg_advisory_xact_lock(hashtextextended(p_journey_id::text, 7137));
  perform public.release_journey_reservations_keep_fulfilled(p_journey_id);
  perform public.evaluate_journey_inventory(p_journey_id);
end;
$$;
revoke execute on function public.rebuild_journey_inventory_reservations(uuid) from authenticated, anon;

-- ---------------------------------------------------------------------------
-- handle_journey_fulfillment_change: same journey lock, release via the
-- helper, then re-evaluate and return new exactly as before (m031:243-263).
-- ---------------------------------------------------------------------------
create or replace function public.handle_journey_fulfillment_change()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  perform pg_advisory_xact_lock(hashtextextended(new.id::text, 7137));
  perform public.release_journey_reservations_keep_fulfilled(new.id);
  perform public.evaluate_journey_inventory(new.id);
  return new;
end;
$$;
revoke execute on function public.handle_journey_fulfillment_change() from authenticated, anon;

-- ---------------------------------------------------------------------------
-- guard_line_item_fulfillment: verbatim copy of the m153 body plus two new
-- frozen columns. A line with handed-over units may no longer change its
-- fulfillment_type_override or pickup_location_id either; every m153 rule
-- is unchanged. The trigger's UPDATE column list grows to match.
-- ---------------------------------------------------------------------------
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
    if new.fulfillment_type_override is distinct from old.fulfillment_type_override
       or new.pickup_location_id is distinct from old.pickup_location_id then
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
  before delete or update of quantity, product_id, fulfillment_type_override, pickup_location_id
  on public.journey_line_items
  for each row execute function public.guard_line_item_fulfillment();

-- ---------------------------------------------------------------------------
-- guard_journey_fulfillment_method: a journey with handed-over units may no
-- longer change its fulfillment_type or store_id. Without this, changing
-- the method after a partial handover would rewrite what was recorded.
-- ---------------------------------------------------------------------------
create or replace function public.guard_journey_fulfillment_method()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if (new.fulfillment_type is distinct from old.fulfillment_type
      or new.store_id is distinct from old.store_id)
     and exists (
       select 1 from public.journey_fulfillment_units jfu
       where jfu.journey_id = new.id
     ) then
    raise exception 'Some items on this order were already handed over, so the fulfillment method cannot be changed.';
  end if;
  return new;
end;
$$;

revoke execute on function public.guard_journey_fulfillment_method()
  from public, anon, authenticated;

drop trigger if exists trg_guard_journey_fulfillment_method on public.sleep_journeys;
create trigger trg_guard_journey_fulfillment_method
  before update of fulfillment_type, store_id on public.sleep_journeys
  for each row execute function public.guard_journey_fulfillment_method();
