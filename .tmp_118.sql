-- ============================================================================
-- Migration 118: cancel a pending transfer (S4a-4).
--
-- cancel_transfer(p_transfer_id, p_employee_id, p_reason):
--   * approver-gated (verify_transfer_approver), transfer row locked.
--   * 'pending' only. in_transit / finalized / cancelled are refused with a
--     clear message -- a shipped transfer can never be un-shipped here.
--   * Releases the origin committed hold per line
--     (quantity_requested - committed_released_qty; pending lines have
--     released 0, so the full approval hold comes off).
--   * Deletes the transfer's transfer_line_units pick rows. Picked units
--     were never moved (units only move at ship), so there is nothing to
--     put back -- the rows were the only link.
--   * Resets every consolidated transfer_request back to 'approved' with
--     transfer_id cleared so it can re-consolidate or be expedited:
--       - journey_mismatch requests get held_quantity = 0, then
--         sync_order_transfer rebuilds quantity + hold from live need.
--       - other sources keep held_quantity and their committed is
--         re-added per request, so committed returns to the sum of open
--         holds (the approve trigger re-stamps held when it sees 0).
--   * Writes a TRANSFER_CANCELLED audit_events row and returns a summary.
--
-- Mask fix (review requirement): the 114 consolidated-quantity mask now
-- only counts consolidated requests whose transfer is NOT cancelled, in
-- both sync_order_transfer and sync_requirement_request. The function
-- bodies are otherwise identical to 114.
-- ============================================================================

create or replace function public.cancel_transfer(
  p_transfer_id uuid,
  p_employee_id uuid,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid;
  v_t public.transfers%rowtype;
  v_line public.transfer_line_items%rowtype;
  v_req record;
  v_units int;
  v_released int := 0;
  v_reset int := 0;
  v_reheld int := 0;
  v_jm_routes jsonb := '[]'::jsonb;
begin
  v_actor := public.verify_transfer_approver(p_employee_id);

  select * into v_t from public.transfers
  where id = p_transfer_id for update;
  if not found then raise exception 'Transfer not found'; end if;

  if v_t.status = 'in_transit' then
    raise exception 'Cannot cancel transfer %: it is already in transit',
      v_t.id;
  end if;
  if v_t.status = 'finalized' then
    raise exception 'Cannot cancel transfer %: it is already finalized',
      v_t.id;
  end if;
  if v_t.status = 'cancelled' then
    raise exception 'Transfer % is already cancelled', v_t.id;
  end if;

  if not (public.is_store_visible(v_t.origin_location_id)
          or public.is_store_visible(v_t.destination_location_id)) then
    raise exception 'Transfer is not visible to this employee';
  end if;

  -- Release the origin committed hold per line. Pending lines never
  -- shipped, so committed_released_qty is 0 and the full
  -- quantity_requested hold comes off.
  for v_line in
    select * from public.transfer_line_items
    where transfer_id = p_transfer_id for update
  loop
    perform pg_advisory_xact_lock(hashtextextended(
      v_line.variant_id::text || ':' || v_t.origin_location_id::text
      || ':Prime', 7137));
    update public.inventory_positions
      set committed_quantity = greatest(0,
            committed_quantity - (v_line.quantity_requested
                                  - v_line.committed_released_qty)),
          updated_at = now()
    where variant_id = v_line.variant_id
      and location_id = v_t.origin_location_id
      and disposition = 'Prime'
      and sublocation_id is null;
    v_released := v_released + v_line.quantity_requested
                   - v_line.committed_released_qty;
  end loop;

  -- Picked units never moved (move_unit only runs at ship); deleting the
  -- rows frees them for other shipments.
  with del as (
    delete from public.transfer_line_units
    where transfer_id = p_transfer_id
    returning 1
  ) select count(*) into v_units from del;

  -- Reset consolidated requests to approved so they can re-consolidate or
  -- be expedited. journey_mismatch holds are rebuilt by
  -- sync_order_transfer below; other sources keep their hold and get
  -- their committed re-added.
  for v_req in
    update public.transfer_requests
      set status = 'approved',
          transfer_id = null,
          held_quantity = case
            when source_type = 'journey_mismatch' then 0
            else held_quantity end
    where transfer_id = p_transfer_id
      and status = 'consolidated'
    returning id, source_type, source_reference_id, variant_id,
              origin_location_id, destination_location_id, held_quantity
  loop
    v_reset := v_reset + 1;

    if v_req.source_type = 'journey_mismatch' then
      v_jm_routes := v_jm_routes || jsonb_build_object(
        'journey_id', v_req.source_reference_id,
        'variant_id', v_req.variant_id,
        'origin', v_req.origin_location_id,
        'dest', v_req.destination_location_id);
    else
      -- Non-JM hold survives the reset; put its committed back.
      perform pg_advisory_xact_lock(hashtextextended(
        v_req.variant_id::text || ':' || v_req.origin_location_id::text
        || ':Prime', 7137));
      update public.inventory_positions
        set committed_quantity = committed_quantity + v_req.held_quantity,
            updated_at = now()
      where variant_id = v_req.variant_id
        and location_id = v_req.origin_location_id
        and disposition = 'Prime'
        and sublocation_id is null;
      v_reheld := v_reheld + v_req.held_quantity;
    end if;
  end loop;

  -- Rebuild journey_mismatch quantity + hold from live need at each
  -- affected route (idempotent; also corrects quantity drift).
  for v_req in
    select distinct (r ->> 'journey_id')::uuid as journey_id,
           (r ->> 'variant_id')::uuid as variant_id,
           (r ->> 'origin')::uuid as origin_location_id,
           (r ->> 'dest')::uuid as destination_location_id
    from jsonb_array_elements(v_jm_routes) r
  loop
    perform public.sync_order_transfer(
      v_req.journey_id, v_req.variant_id,
      v_req.origin_location_id, v_req.destination_location_id);
  end loop;

  update public.transfers
    set status = 'cancelled'
  where id = p_transfer_id;

  insert into public.audit_events (
    company_id, actor_type, actor_employee_id, entity_type, entity_id,
    event_type, after
  )
  select s.company_id, 'EMPLOYEE', v_actor, 'transfer', p_transfer_id,
         'TRANSFER_CANCELLED',
         jsonb_build_object('reason', p_reason,
           'committed_released', v_released,
           'units_unpicked', v_units,
           'requests_reset', v_reset,
           'committed_reheld', v_reheld)
  from public.stores s
  where s.id = v_t.origin_location_id;

  return jsonb_build_object(
    'transfer_id', p_transfer_id,
    'status', 'cancelled',
    'committed_released', v_released,
    'units_unpicked', v_units,
    'requests_reset', v_reset,
    'committed_reheld', v_reheld);
end;
$$;

grant execute on function public.cancel_transfer(uuid, uuid, text) to authenticated;
revoke execute on function public.cancel_transfer(uuid, uuid, text)
  from public, anon;

-- 2. sync_order_transfer: identical to 114 except the consolidated mask
--    ignores requests whose transfer is cancelled.

create or replace function public.sync_order_transfer(
  p_journey_id uuid,
  p_variant_id uuid,
  p_origin_location_id uuid,
  p_destination_location_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_need integer;
  v_shortfall integer;
  v_open public.transfer_requests%rowtype;
  v_consolidated integer;
  v_target integer;
  v_delta integer;
begin
  if p_origin_location_id = p_destination_location_id then
    return;
  end if;

  select count(*) into v_need
  from public.units u
  join public.journey_inventory_requirements jir
    on jir.id = u.assigned_requirement_id
  where jir.journey_id = p_journey_id
    and jir.variant_id = p_variant_id
    and jir.location_id = p_destination_location_id
    and u.location_id = p_origin_location_id
    and u.status = 'RESERVED';

  select coalesce(sum(quantity), 0) into v_consolidated
  from public.transfer_requests
  where source_type = 'journey_mismatch'
    and source_reference_id = p_journey_id
    and variant_id = p_variant_id
    and destination_location_id = p_destination_location_id
    and status = 'consolidated
    and exists (select 1 from public.transfers t
                where t.id = transfer_requests.transfer_id
                  and t.status <> 'cancelled');

  -- Uncovered need across live requirements on this route: what is not yet
  -- reserved at the pickup store and has no unit assigned anywhere.
  select coalesce(sum(greatest(0,
            jir.quantity_required
            - coalesce(jir.quantity_reserved, 0)
            - (select count(*) from public.units u
                where u.assigned_requirement_id = jir.id))), 0)
    into v_shortfall
  from public.journey_inventory_requirements jir
  where jir.journey_id = p_journey_id
    and jir.variant_id = p_variant_id
    and jir.location_id = p_destination_location_id
    and jir.status in ('pending', 'ready');

  -- Total still needed from elsewhere = units riding + uncovered quantity,
  -- minus what consolidated transfers already cover (no duplicate request
  -- or second hold once the cron has turned a request into a transfer).
  v_target := greatest(0, v_need + v_shortfall - v_consolidated);

  select * into v_open
  from public.transfer_requests
  where source_type = 'journey_mismatch'
    and source_reference_id = p_journey_id
    and variant_id = p_variant_id
    and destination_location_id = p_destination_location_id
    and status in ('pending_approval', 'approved')
    and transfer_id is null
  limit 1
  for update;

  if v_open.id is not null then
    if v_open.origin_location_id is distinct from p_origin_location_id then
      if v_open.held_quantity > 0 then
        perform pg_advisory_xact_lock(hashtextextended(
          p_variant_id::text || ':' || v_open.origin_location_id::text || ':Prime', 7137));
        update public.inventory_positions
          set committed_quantity = greatest(0, committed_quantity - v_open.held_quantity),
              updated_at = now()
        where variant_id = p_variant_id
          and location_id = v_open.origin_location_id
          and disposition = 'Prime' and sublocation_id is null;
      end if;
      update public.transfer_requests
        set origin_location_id = p_origin_location_id,
            held_quantity = 0
      where id = v_open.id;
      v_open.held_quantity := 0;
      v_open.quantity := 0;
    end if;

    v_delta := v_target - v_open.held_quantity;

    if v_target = 0 then
      perform public.release_jm_request(v_open.id);
    else
      if v_delta <> 0 then
        perform pg_advisory_xact_lock(hashtextextended(
          p_variant_id::text || ':' || p_origin_location_id::text || ':Prime', 7137));
        update public.inventory_positions
          set committed_quantity = greatest(0, committed_quantity + v_delta),
              updated_at = now()
        where variant_id = p_variant_id
          and location_id = p_origin_location_id
          and disposition = 'Prime' and sublocation_id is null;
      end if;
      update public.transfer_requests
        set quantity = v_target, held_quantity = v_target
      where id = v_open.id;
    end if;

  elsif v_target > 0 then
    insert into public.transfer_requests (
      origin_location_id, destination_location_id, variant_id,
      quantity, held_quantity, source_type, source_reference_id, status
    ) values (
      p_origin_location_id, p_destination_location_id, p_variant_id,
      v_target, v_target, 'journey_mismatch', p_journey_id, 'approved'
    );

    perform pg_advisory_xact_lock(hashtextextended(
      p_variant_id::text || ':' || p_origin_location_id::text || ':Prime', 7137));
    update public.inventory_positions
      set committed_quantity = committed_quantity + v_target,
          updated_at = now()
    where variant_id = p_variant_id
      and location_id = p_origin_location_id
      and disposition = 'Prime' and sublocation_id is null;
  end if;
end;
$$;

revoke execute on function public.sync_order_transfer(uuid, uuid, uuid, uuid)
  from public, anon, authenticated;

-- 3. sync_requirement_request: identical to 114 except the same mask fix.

create or replace function public.sync_requirement_request(p_requirement_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_req public.journey_inventory_requirements%rowtype;
  v_journey public.sleep_journeys%rowtype;
  v_origin uuid;
  v_shortfall integer;
  v_consolidated integer;
begin
  select * into v_req
  from public.journey_inventory_requirements
  where id = p_requirement_id;
  if not found then
    return;
  end if;

  select * into v_journey
  from public.sleep_journeys where id = v_req.journey_id;

  -- Dead order or dead requirement: cancel open requests, release holds.
  if v_req.status in ('cancelled', 'superseded')
     or v_journey.cancelled_at is not null
     or v_journey.current_state = 'Quoted' then
    perform public.cancel_journey_mismatch_requests(
      v_req.journey_id, v_req.variant_id, v_req.location_id);
    return;
  end if;

  -- Re-sync every open request on this route at its own origin (grow,
  -- shrink, or cancel-by-zero inside sync_order_transfer).
  for v_origin in
    select distinct origin_location_id
    from public.transfer_requests
    where source_type = 'journey_mismatch'
      and source_reference_id = v_req.journey_id
      and variant_id = v_req.variant_id
      and destination_location_id = v_req.location_id
      and status in ('pending_approval', 'approved')
      and transfer_id is null
  loop
    perform public.sync_order_transfer(
      v_req.journey_id, v_req.variant_id, v_origin, v_req.location_id);
  end loop;

  -- No open request: create one for the uncovered need, warehouse-first.
  select coalesce(sum(greatest(0,
            jir.quantity_required
            - coalesce(jir.quantity_reserved, 0)
            - (select count(*) from public.units u
                where u.assigned_requirement_id = jir.id))), 0)
    into v_shortfall
  from public.journey_inventory_requirements jir
  where jir.journey_id = v_req.journey_id
    and jir.variant_id = v_req.variant_id
    and jir.location_id = v_req.location_id
    and jir.status in ('pending', 'ready');

  select coalesce(sum(quantity), 0) into v_consolidated
  from public.transfer_requests
  where source_type = 'journey_mismatch'
    and source_reference_id = v_req.journey_id
    and variant_id = v_req.variant_id
    and destination_location_id = v_req.location_id
    and status = 'consolidated
    and exists (select 1 from public.transfers t
                where t.id = transfer_requests.transfer_id
                  and t.status <> 'cancelled');
  v_shortfall := greatest(0, v_shortfall - v_consolidated);

  if v_shortfall > 0 and not exists (
    select 1 from public.transfer_requests
    where source_type = 'journey_mismatch'
      and source_reference_id = v_req.journey_id
      and variant_id = v_req.variant_id
      and destination_location_id = v_req.location_id
      and status in ('pending_approval', 'approved')
      and transfer_id is null
  ) then
    perform public.create_journey_mismatch_transfer(
      v_req.journey_id, v_req.variant_id, v_shortfall, v_req.location_id);
  end if;
end;
$$;

revoke execute on function public.sync_requirement_request(uuid)
  from public, anon, authenticated;
