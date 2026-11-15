-- ============================================================================
-- S4a-2: unit-level ship + committed-release-at-ship (ATS fix).
--
-- mark_transfer_in_transit gains an optional 4th parameter
-- (p_unit_picks jsonb, default null). The old 3-arg signature is dropped and
-- replaced by the 4-arg function with a default, so existing 3-arg calls
-- resolve to the SAME code path — no duplicated quantity logic.
--
-- Unit behavior (only for unit-tracked lines that HAVE pick rows from 115):
--   ship_qty == picked count  -> every picked unit moves to IN_TRANSIT.
--   ship_qty <  picked count  -> p_unit_picks MUST name exactly ship_qty of
--                                the picked units; the rest stay behind and
--                                their pick rows are deleted. Never guessed.
--   tracked line, no picks    -> legacy quantity-only ship, unchanged.
--   untracked line            -> unchanged.
--
-- ATS fix: the origin committed hold is released AT SHIP
-- (committed -= quantity_shipped, tracked in
-- transfer_line_items.committed_released_qty) instead of entirely at
-- finalize. finalize releases only quantity_requested -
-- committed_released_qty, so transfers already in_transit under the old
-- logic (released_qty = 0) release in full at finalize exactly as before.
-- ============================================================================

alter table public.transfer_line_items
  add column if not exists committed_released_qty integer not null default 0
    check (committed_released_qty >= 0
           and committed_released_qty <= quantity_requested);

comment on column public.transfer_line_items.committed_released_qty is
  'Portion of the approval-time origin committed hold already released at '
  'ship time (S4a-2). finalize releases quantity_requested minus this, so '
  'transfers shipped before this migration (0) still release in full.';

-- New signature subsumes the old one (4th arg defaults to null).
drop function if exists public.mark_transfer_in_transit(uuid, uuid, jsonb);

create or replace function public.mark_transfer_in_transit(
  p_transfer_id uuid,
  p_employee_id uuid,
  p_shipped jsonb default null,
  p_unit_picks jsonb default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid;
  v_t public.transfers%rowtype;
  v_line public.transfer_line_items%rowtype;
  v_ship_qty integer;
  v_pos public.inventory_positions%rowtype;
  v_new_on_hand integer;
  v_other_committed integer;
  v_picked record;
  v_ship_ids uuid[];
  v_explicit uuid[];
  v_left_ids uuid[];
  v_journey uuid;
begin
  v_actor := public.verify_transfer_approver(p_employee_id);

  select * into v_t
  from public.transfers
  where id = p_transfer_id
  for update;

  if not found then raise exception 'Transfer not found'; end if;
  if v_t.status <> 'pending' then
    raise exception 'Only pending transfers can be marked in transit';
  end if;
  if not (public.is_store_visible(v_t.origin_location_id) or public.is_store_visible(v_t.destination_location_id)) then
    raise exception 'Transfer is not visible to this employee';
  end if;

  for v_line in
    select * from public.transfer_line_items where transfer_id = p_transfer_id for update
  loop
    v_ship_qty := v_line.quantity_requested;

    if p_shipped is not null and p_shipped ? v_line.id::text then
      v_ship_qty := (p_shipped ->> v_line.id::text)::integer;
    end if;

    if v_ship_qty is null or v_ship_qty < 0 or v_ship_qty > v_line.quantity_requested then
      raise exception 'Invalid shipped quantity for line %', v_line.id;
    end if;

    perform pg_advisory_xact_lock(
      hashtextextended(v_line.variant_id::text || ':' || v_t.origin_location_id::text || ':Prime', 7137)
    );

    select * into v_pos
    from public.inventory_positions
    where variant_id = v_line.variant_id
      and location_id = v_t.origin_location_id
      and disposition = 'Prime'
      and sublocation_id is null
    for update;

    if not found then
      raise exception 'No Prime stock at origin for variant %', v_line.variant_id;
    end if;

    v_new_on_hand := v_pos.on_hand_quantity - v_ship_qty;
    if v_new_on_hand < 0 then
      raise exception 'Insufficient stock at origin for variant %', v_line.variant_id;
    end if;

    -- The line's own reservation (committed at approval) must not block the
    -- shipment it was made for; only stock committed to OTHER orders does.
    v_other_committed := greatest(0, v_pos.committed_quantity - v_line.quantity_requested);
    if v_new_on_hand < v_other_committed then
      raise exception 'Cannot ship % units of variant % — % are committed to other orders at the origin',
        v_ship_qty, v_line.variant_id, v_other_committed;
    end if;

    update public.inventory_positions
      set on_hand_quantity = v_new_on_hand,
          committed_quantity = greatest(0,
            committed_quantity - v_ship_qty),
          updated_at = now()
    where id = v_pos.id;

    insert into public.stock_ledger_entries (
      variant_id, location_id, disposition, quantity_delta,
      reason, reference_type, actor_id
    ) values (
      v_line.variant_id, v_t.origin_location_id, 'Prime', -v_ship_qty,
      'transfer_ship', 'transfer_line_item', v_actor::text
    );

    update public.transfer_line_items
      set quantity_shipped = v_ship_qty,
          committed_released_qty = v_ship_qty
    where id = v_line.id;

    -- ---- unit-level ship (tracked lines with pick rows only) ----------
    if public.is_unit_tracked(v_line.variant_id) then
      -- All unresolved pick rows for this line, in unit order.
      select array_agg(tlu.unit_id order by tlu.unit_number) into v_ship_ids
      from public.transfer_line_units tlu
      where tlu.transfer_line_item_id = v_line.id
        and tlu.received_at is null
        and tlu.missing_at is null;

      if v_ship_ids is not null then
        if v_ship_qty < array_length(v_ship_ids, 1) then
          -- Partial ship of a picked line: staff must name exactly which
          -- units leave; the rest stay behind and lose their pick rows.
          if p_unit_picks is null then
            raise exception
              'Line % ships % of % picked units — an explicit unit list is required',
              v_line.id, v_ship_qty, array_length(v_ship_ids, 1);
          end if;
          select array_agg(x::uuid) into v_explicit
          from jsonb_array_elements_text(
            coalesce(
              (select p -> 'unit_ids'
                 from jsonb_array_elements(p_unit_picks) p
                where (p ->> 'line_item_id')::uuid = v_line.id
                limit 1),
              '[]'::jsonb)) x;
          if coalesce(array_length(v_explicit, 1), 0) <> v_ship_qty
             or exists (
               select 1 from unnest(v_explicit) e
               where not (e = any (v_ship_ids))) then
            raise exception
              'Ship unit list for line % must name exactly % of the picked units',
              v_line.id, v_ship_qty;
          end if;
          select array_agg(u) into v_left_ids
          from unnest(v_ship_ids) u
          where not (u = any (v_explicit));
          delete from public.transfer_line_units
          where transfer_line_item_id = v_line.id
            and unit_id = any (v_left_ids);
          v_ship_ids := v_explicit;
        elsif p_unit_picks is not null then
          -- Full ship with an explicit list supplied anyway: it must name
          -- exactly the picked set, nothing more, nothing less.
          select array_agg(x::uuid) into v_explicit
          from jsonb_array_elements_text(
            coalesce(
              (select p -> 'unit_ids'
                 from jsonb_array_elements(p_unit_picks) p
                where (p ->> 'line_item_id')::uuid = v_line.id
                limit 1),
              '[]'::jsonb)) x;
          if coalesce(array_length(v_explicit, 1), 0) <> v_ship_qty
             or exists (
               select 1 from unnest(v_explicit) e
               where not (e = any (v_ship_ids))) then
            raise exception
              'Ship unit list for line % must name exactly % of the picked units',
              v_line.id, v_ship_qty;
          end if;
          v_ship_ids := v_explicit;
        end if;
        -- v_ship_qty = picked count and no explicit list: all picked ship.
        if coalesce(array_length(v_ship_ids, 1), 0) <> v_ship_qty then
          raise exception
            'Line % ships % units but only % picked units resolved',
            v_line.id, v_ship_qty, coalesce(array_length(v_ship_ids, 1), 0);
        end if;

        -- Move each shipping unit. RESERVED units keep their assignment;
        -- the requirement's journey rides along in the event context.
        for v_picked in
          select tlu.unit_id, jir.journey_id
          from public.transfer_line_units tlu
          left join public.journey_inventory_requirements jir
            on jir.id = tlu.picked_requirement_id
          where tlu.transfer_line_item_id = v_line.id
            and tlu.unit_id = any (v_ship_ids)
        loop
          perform public.move_unit(
            v_picked.unit_id, 'IN_TRANSIT', null,
            jsonb_build_object(
              'transfer_id', p_transfer_id,
              'event_type', 'UNIT_SHIPPED',
              'journey_id', v_picked.journey_id));
        end loop;
      end if;
    end if;
  end loop;

  update public.transfers
    set status = 'in_transit',
        in_transit_at = now()
  where id = p_transfer_id;
end;
$$;

grant execute on function public.mark_transfer_in_transit(uuid, uuid, jsonb, jsonb) to authenticated;

-- finalize_transfer: same body as 078 except the origin committed release
-- is quantity_requested minus what ship already released.
create or replace function public.finalize_transfer(
  p_transfer_id uuid,
  p_received jsonb,
  p_employee_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid;
  v_t public.transfers%rowtype;
  v_line public.transfer_line_items%rowtype;
  v_recv integer;
  v_pos public.inventory_positions%rowtype;
  v_new_on_hand integer;
  v_release integer;
begin
  v_actor := public.verify_transfer_approver(p_employee_id);

  select * into v_t
  from public.transfers
  where id = p_transfer_id
  for update;

  if not found then raise exception 'Transfer not found'; end if;
  if v_t.status <> 'in_transit' then
    raise exception 'Only in_transit transfers can be finalized';
  end if;
  if not (public.is_store_visible(v_t.origin_location_id) or public.is_store_visible(v_t.destination_location_id)) then
    raise exception 'Transfer is not visible to this employee';
  end if;

  for v_line in
    select * from public.transfer_line_items where transfer_id = p_transfer_id for update
  loop
    if p_received is null or not (p_received ? v_line.id::text) then
      v_recv := v_line.quantity_shipped;
    else
      v_recv := (p_received ->> v_line.id::text)::integer;
    end if;

    if v_recv is null or v_recv < 0 or v_recv > v_line.quantity_shipped then
      raise exception 'Invalid received quantity for line %', v_line.id;
    end if;

    perform pg_advisory_xact_lock(
      hashtextextended(v_line.variant_id::text || ':' || v_t.destination_location_id::text || ':Prime', 7137)
    );

    select * into v_pos
    from public.inventory_positions
    where variant_id = v_line.variant_id
      and location_id = v_t.destination_location_id
      and disposition = 'Prime'
      and sublocation_id is null
    for update;

    if not found then
      insert into public.inventory_positions (
        variant_id, location_id, sublocation_id, disposition,
        on_hand_quantity, committed_quantity
      ) values (
        v_line.variant_id, v_t.destination_location_id, null, 'Prime',
        v_recv, 0
      ) returning * into v_pos;
    else
      v_new_on_hand := v_pos.on_hand_quantity + v_recv;
      update public.inventory_positions
        set on_hand_quantity = v_new_on_hand,
            updated_at = now()
      where id = v_pos.id;
    end if;

    insert into public.stock_ledger_entries (
      variant_id, location_id, disposition, quantity_delta,
      reason, reference_type, actor_id
    ) values (
      v_line.variant_id, v_t.destination_location_id, 'Prime', v_recv,
      'transfer_receive', 'transfer_line_item', v_actor::text
    );

    -- Release whatever remains of the approval-time reservation at the
    -- origin: ship already released committed_released_qty; this releases
    -- the rest (requested minus shipped for partial shipments, or the full
    -- amount for transfers shipped before committed_released_qty existed).
    v_release := v_line.quantity_requested - v_line.committed_released_qty;
    perform pg_advisory_xact_lock(
      hashtextextended(v_line.variant_id::text || ':' || v_t.origin_location_id::text || ':Prime', 7137)
    );
    update public.inventory_positions
      set committed_quantity = greatest(0, committed_quantity - v_release),
          updated_at = now()
    where variant_id = v_line.variant_id
      and location_id = v_t.origin_location_id
      and disposition = 'Prime'
      and sublocation_id is null;

    update public.transfer_line_items
      set quantity_received = v_recv
    where id = v_line.id;

    -- Stock just arrived at the destination; wake any Journey waiting on it.
    perform public.evaluate_pending_inventory_for_variant(
      v_line.variant_id, v_t.destination_location_id
    );
  end loop;

  update public.transfers
    set status = 'finalized',
        finalized_at = now(),
        finalized_by = v_actor
  where id = p_transfer_id;
end;
$$;

grant execute on function public.finalize_transfer(uuid, jsonb, uuid) to authenticated;
