-- ============================================================================
-- Unit ID S3a-fix v3: warehouse receives fill customer orders company-wide.
--
-- Standing rules in play:
--   * Only just-received units (plus older STOCK at the same warehouse) can
--     fill a waiting order; STOCK at any other location is never raided.
--   * The main warehouse is the default fulfilling hub:
--     create_journey_mismatch_transfer now prefers a company warehouse as
--     origin, falling back to the highest-ATS other store.
--   * Every approved journey_mismatch request holds committed_quantity =
--     quantity at its origin (same pattern as approve_transfer_request),
--     created, re-pointed, shrunk and cancelled through one sync function.
--   * All-or-nothing per requirement, oldest requirement first.
--   * Everything stays undoable by a human.
-- ============================================================================

-- 1. create_journey_mismatch_transfer: warehouse-first sourcing and a real
--    origin hold at creation.

create or replace function public.create_journey_mismatch_transfer(
  p_journey_id uuid,
  p_variant_id uuid,
  p_quantity integer,
  p_fulfillment_location_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_journey_store public.stores%rowtype;
  v_origin uuid;
  v_ats integer;
  v_need integer := p_quantity;
  v_existing uuid;
  v_req_id uuid;
begin
  if not public.is_journey_visible(p_journey_id) then
    raise exception 'Journey is not visible to this employee';
  end if;

  select s.* into v_journey_store
  from public.sleep_journeys sj
  join public.stores s on s.id = sj.store_id
  where sj.id = p_journey_id;

  if not found then raise exception 'Journey not found'; end if;

  if p_fulfillment_location_id is null then
    p_fulfillment_location_id := v_journey_store.id;
  end if;

  -- Sourcing rule: the main warehouse is the default hub. Prefer a company
  -- warehouse whose available-to-sell covers the shortfall.
  select ip.location_id,
         (ip.on_hand_quantity - ip.committed_quantity) as available
    into v_origin, v_ats
  from public.inventory_positions ip
  join public.stores s on s.id = ip.location_id
  where ip.variant_id = p_variant_id
    and ip.disposition = 'Prime'
    and ip.sublocation_id is null
    and ip.location_id <> p_fulfillment_location_id
    and s.company_id = v_journey_store.company_id
    and s.location_type = 'WAREHOUSE'
  order by available desc
  limit 1;

  -- Only when no warehouse can cover it: fall back to the other store
  -- with the highest available-to-sell.
  if v_origin is null or v_ats < v_need then
    select ip.location_id,
           (ip.on_hand_quantity - ip.committed_quantity) as available
      into v_origin, v_ats
    from public.inventory_positions ip
    join public.stores s on s.id = ip.location_id
    where ip.variant_id = p_variant_id
      and ip.disposition = 'Prime'
      and ip.sublocation_id is null
      and ip.location_id <> p_fulfillment_location_id
      and s.company_id = v_journey_store.company_id
    order by available desc
    limit 1;
  end if;

  if v_origin is null or v_ats <= 0 then
    return null;
  end if;

  v_need := least(v_need, v_ats);

  -- Avoid duplicate open journey_mismatch requests for the same
  -- journey+product+route.
  select id into v_existing
  from public.transfer_requests
  where source_reference_id = p_journey_id
    and variant_id = p_variant_id
    and origin_location_id = v_origin
    and destination_location_id = p_fulfillment_location_id
    and source_type = 'journey_mismatch'
    and status not in ('consolidated', 'cancelled', 'rejected')
  limit 1;

  if v_existing is not null then
    return v_existing;
  end if;

  insert into public.transfer_requests (
    origin_location_id,
    destination_location_id,
    variant_id,
    quantity,
    source_type,
    source_reference_id,
    status
  ) values (
    v_origin,
    p_fulfillment_location_id,
    p_variant_id,
    v_need,
    'journey_mismatch',
    p_journey_id,
    'approved'
  ) returning id into v_req_id;

  -- Every approved journey_mismatch request holds committed_quantity =
  -- quantity at its origin, same pattern as approve_transfer_request.
  perform pg_advisory_xact_lock(
    hashtextextended(p_variant_id::text || ':' || v_origin::text || ':Prime', 7137)
  );
  update public.inventory_positions
    set committed_quantity = committed_quantity + v_need,
        updated_at = now()
  where variant_id = p_variant_id
    and location_id = v_origin
    and disposition = 'Prime'
    and sublocation_id is null;

  return v_req_id;
end;
$$;

grant execute on function public.create_journey_mismatch_transfer(uuid, uuid, integer, uuid) to authenticated;

-- 2. sync_order_transfer: keep ONE open journey_mismatch request per
--    journey + variant + destination matching the units still at the
--    origin; the origin always holds committed_quantity = quantity.
--    Internal only.

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
  v_open public.transfer_requests%rowtype;
  v_consolidated integer;
  v_target integer;
  v_delta integer;
begin
  if p_origin_location_id = p_destination_location_id then
    return;
  end if;

  -- Units at the origin still needing the ride: assigned to this journey's
  -- requirement for this variant at the destination and not yet shipped.
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
    and status = 'consolidated';

  v_target := greatest(0, v_need - v_consolidated);

  select * into v_open
  from public.transfer_requests
  where source_type = 'journey_mismatch'
    and source_reference_id = p_journey_id
    and variant_id = p_variant_id
    and destination_location_id = p_destination_location_id
    and status in ('pending_approval', 'approved')
  limit 1
  for update;

  if v_open.id is not null then
    -- Re-point: release the full hold at the old origin (hold = quantity
    -- by rule), then everything after this treats the new origin.
    if v_open.origin_location_id is distinct from p_origin_location_id then
      perform pg_advisory_xact_lock(hashtextextended(
        p_variant_id::text || ':' || v_open.origin_location_id::text || ':Prime', 7137));
      update public.inventory_positions
        set committed_quantity = greatest(0, committed_quantity - v_open.quantity),
            updated_at = now()
      where variant_id = p_variant_id
        and location_id = v_open.origin_location_id
        and disposition = 'Prime' and sublocation_id is null;

      update public.transfer_requests
        set origin_location_id = p_origin_location_id
      where id = v_open.id;
      v_open.quantity := 0; -- nothing held at the new origin yet
    end if;

    v_delta := v_target - v_open.quantity;

    if v_target = 0 then
      if v_open.quantity > 0 then
        perform pg_advisory_xact_lock(hashtextextended(
          p_variant_id::text || ':' || p_origin_location_id::text || ':Prime', 7137));
        update public.inventory_positions
          set committed_quantity = greatest(0, committed_quantity - v_open.quantity),
              updated_at = now()
        where variant_id = p_variant_id
          and location_id = p_origin_location_id
          and disposition = 'Prime' and sublocation_id is null;
      end if;
      update public.transfer_requests
        set status = 'cancelled'
      where id = v_open.id;
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
        set quantity = v_target
      where id = v_open.id;
    end if;

  elsif v_target > 0 then
    insert into public.transfer_requests (
      origin_location_id, destination_location_id, variant_id,
      quantity, source_type, source_reference_id, status
    ) values (
      p_origin_location_id, p_destination_location_id, p_variant_id,
      v_target, 'journey_mismatch', p_journey_id, 'approved'
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

-- 3. assign_received_units_to_orders: all-or-nothing, oldest requirement
--    first. Candidates: the just-received units; at a warehouse also older
--    unassigned STOCK/Prime units at that same warehouse. Units at any
--    other location are never touched.

create or replace function public.assign_received_units_to_orders(
  p_unit_ids uuid[],
  p_variant_id uuid,
  p_receive_location_id uuid,
  p_company_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_req record;
  v_unit uuid;
  v_need integer;
  v_count integer;
  v_pool integer;
  v_is_warehouse boolean;
  i integer;
begin
  if p_unit_ids is null or p_unit_ids = '{}' then
    return;
  end if;

  select (location_type = 'WAREHOUSE') into v_is_warehouse
  from public.stores where id = p_receive_location_id;

  for v_req in
    select jir.id, jir.journey_id, jir.variant_id, jir.location_id,
           jir.quantity_required, jir.quantity_reserved
    from public.journey_inventory_requirements jir
    join public.sleep_journeys sj on sj.id = jir.journey_id
    join public.stores s on s.id = jir.location_id
    where jir.variant_id = p_variant_id
      and s.company_id = p_company_id
      and jir.status in ('pending', 'ready')
      and sj.cancelled_at is null
      and sj.current_state <> 'Quoted'
    order by jir.created_at, jir.id
    for update of jir
  loop
    select count(*) into v_count
    from public.units
    where assigned_requirement_id = v_req.id;

    v_need := v_req.quantity_required - v_count;
    if v_need <= 0 then
      continue;
    end if;

    -- Pool: just-received units always; at a warehouse, older unassigned
    -- stock at that same warehouse too. Never any other location.
    select count(*) into v_pool
    from public.units
    where status = 'STOCK'
      and disposition = 'Prime'
      and assigned_requirement_id is null
      and (
        id = any(p_unit_ids)
        or (v_is_warehouse
            and location_id = p_receive_location_id
            and product_id = p_variant_id)
      );

    -- All-or-nothing: cannot cover this requirement in full, skip it.
    if v_pool < v_need then
      continue;
    end if;

    for i in 1..v_need loop
      select id into v_unit
      from public.units
      where status = 'STOCK'
        and disposition = 'Prime'
        and assigned_requirement_id is null
        and (
          id = any(p_unit_ids)
          or (v_is_warehouse
              and location_id = p_receive_location_id
              and product_id = p_variant_id)
        )
      order by unit_number
      limit 1
      for update skip locked;

      exit when v_unit is null;
      perform public.move_unit(v_unit, 'RESERVED', null,
        jsonb_build_object('requirement_id', v_req.id));
    end loop;

    -- Cross-location fill: keep the journey's transfer request in sync.
    if v_req.location_id is distinct from p_receive_location_id then
      perform public.sync_order_transfer(
        v_req.journey_id, p_variant_id,
        p_receive_location_id, v_req.location_id);
    end if;
  end loop;
end;
$$;

revoke execute on function public.assign_received_units_to_orders(uuid[], uuid, uuid, uuid)
  from public, anon, authenticated;

-- 4. reconcile_requirement_units: cross-location assigned units (RESERVED
--    or IN_TRANSIT elsewhere, riding a transfer) count toward the fill and
--    are never released by the "too many" rule. Cancelled/quoted/fulfilled
--    handling is unchanged; a released cross-location unit re-syncs its
--    transfer request.

create or replace function public.reconcile_requirement_units(p_requirement_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_req public.journey_inventory_requirements%rowtype;
  v_journey public.sleep_journeys%rowtype;
  v_company uuid;
  v_mode text;
  v_desired integer;
  v_cross integer;
  v_assigned uuid[];
  v_local uuid[];
  v_count integer;
  v_unit uuid;
  v_shortfall integer;
  i integer;
begin
  select * into v_req
  from public.journey_inventory_requirements
  where id = p_requirement_id;
  if not found then
    return;
  end if;

  if not public.is_unit_tracked(v_req.variant_id) then
    return;
  end if;

  select * into v_journey
  from public.sleep_journeys where id = v_req.journey_id;
  select s.company_id, c.unit_assignment_mode
    into v_company, v_mode
  from public.stores s
  join public.companies c on c.id = s.company_id
  where s.id = v_journey.store_id;

  if v_mode <> 'AUTOMATIC' then
    return;
  end if;

  -- Units assigned that sit at a different location: riding a transfer,
  -- never released by the excess rule.
  select count(*) into v_cross
  from public.units
  where assigned_requirement_id = v_req.id
    and location_id is distinct from v_req.location_id
    and status in ('RESERVED', 'IN_TRANSIT');

  if v_req.status in ('cancelled', 'superseded')
     or v_journey.cancelled_at is not null
     or v_journey.current_state = 'Quoted' then
    v_desired := 0;
  elsif v_req.status = 'fulfilled' then
    for v_unit in
      select id from public.units
      where assigned_requirement_id = v_req.id
        and status in ('RESERVED', 'STAGED')
    loop
      perform public.move_unit(v_unit, 'DELIVERED', null,
        jsonb_build_object('journey_id', v_req.journey_id));
    end loop;
    return;
  else
    v_desired := least(v_req.quantity_required,
                       v_req.quantity_reserved + v_cross);
  end if;

  select array_agg(id order by unit_number)
    into v_assigned
  from public.units
  where assigned_requirement_id = v_req.id;
  v_count := coalesce(array_length(v_assigned, 1), 0);

  if v_desired = 0 then
    -- Cancelled/quoted/superseded: release everything, then re-sync any
    -- transfer that was carrying a cross-location unit.
    for i in reverse v_count..1 loop
      perform public.move_unit(v_assigned[i], 'STOCK', null, '{}'::jsonb);
    end loop;
    if v_cross > 0 then
      perform public.sync_order_transfer(
        v_req.journey_id, v_req.variant_id,
        (select location_id from public.units where id = v_assigned[1]),
        v_req.location_id);
    end if;
    v_count := 0;
  else
    select coalesce(array_agg(id order by unit_number), '{}')
      into v_local
    from public.units
    where assigned_requirement_id = v_req.id
      and location_id = v_req.location_id;

    while v_count > v_desired loop
      if coalesce(array_length(v_local, 1), 0) = 0 then
        exit;
      end if;
      v_unit := v_local[array_length(v_local, 1)];
      v_local := v_local[1:array_length(v_local, 1) - 1];
      perform public.move_unit(v_unit, 'STOCK', null, '{}'::jsonb);
      v_count := v_count - 1;
    end loop;
  end if;

  -- Too few units: assign the oldest in-stock units at this location.
  if v_count < v_desired then
    for v_unit in
      select id from public.units
      where product_id = v_req.variant_id
        and location_id = v_req.location_id
        and disposition = 'Prime'
        and status = 'STOCK'
        and assigned_requirement_id is null
      order by unit_number
      limit v_desired - v_count
      for update skip locked
    loop
      perform public.move_unit(v_unit, 'RESERVED', null,
        jsonb_build_object('requirement_id', v_req.id));
      v_count := v_count + 1;
    end loop;

    v_shortfall := v_desired - v_count;
    if v_shortfall > 0 and not exists (
      select 1 from public.audit_events ae
      where ae.entity_type = 'journey_inventory_requirement'
        and ae.entity_id = v_req.id
        and ae.event_type = 'UNIT_ASSIGNMENT_SHORTFALL'
        and (ae.after->>'shortfall')::int = v_shortfall
        and (ae.after->>'required')::int = v_desired
      order by ae.occurred_at desc
      limit 1
    ) then
      insert into public.audit_events (
        company_id, actor_type, entity_type, entity_id, journey_id,
        event_type, after
      ) values (
        v_company, 'SYSTEM', 'journey_inventory_requirement', v_req.id,
        v_req.journey_id, 'UNIT_ASSIGNMENT_SHORTFALL',
        jsonb_build_object('required', v_desired, 'assigned', v_count,
          'shortfall', v_shortfall, 'variant_id', v_req.variant_id,
          'location_id', v_req.location_id)
      );
    end if;
  end if;
end;
$$;

revoke execute on function public.reconcile_requirement_units(uuid)
  from public, anon, authenticated;

-- 5. receive_purchase_order_line: identical to 110 plus the helper call and
--    an assign_failed flag in the return payload.

drop function if exists public.receive_purchase_order_line(uuid, integer);

create function public.receive_purchase_order_line(p_line_item_id uuid, p_quantity integer)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  v_line public.purchase_order_line_items%rowtype;
  v_po public.purchase_orders%rowtype;
  v_role text;
  v_remaining integer;
  v_position_id uuid;
  v_old_on_hand integer;
  v_actor uuid;
  v_company_id uuid;
  v_new_received integer;
  v_new_status text;
  v_unit_ids uuid[] := '{}';
  v_unit_numbers bigint[] := '{}';
  v_assignments jsonb := '[]'::jsonb;
  v_assign_failed boolean := false;
  v_new_unit uuid;
  i integer;
begin
  if p_quantity <= 0 then raise exception 'Receipt quantity must be greater than zero'; end if;
  select * into v_line from public.purchase_order_line_items where id = p_line_item_id for update;
  if not found then raise exception 'Purchase order line not found'; end if;
  select * into v_po from public.purchase_orders where id = v_line.purchase_order_id for update;
  if v_po.status not in ('submitted','partially_received') then raise exception 'Only submitted purchase orders can be received'; end if;
  if v_po.fulfillment_type <> 'stock' then raise exception 'Drop-ship purchase orders do not receive into inventory'; end if;
  if not exists (select 1 from public.stores where id = v_po.destination_location_id and location_type in ('STORE','WAREHOUSE')) then raise exception 'Invalid purchase order destination'; end if;
  select e.role::text, e.id, ds.company_id into v_role, v_actor, v_company_id from public.employees e join public.stores hs on hs.id = e.home_store_id join public.stores ds on ds.id = v_po.destination_location_id where e.auth_user_id = auth.uid() and hs.company_id = ds.company_id;
  if v_actor is null or not public.has_permission('inventory.receive_po') then raise exception 'You do not have permission to receive purchase orders.'; end if;
  if public.is_unit_tracked(v_line.variant_id) and p_quantity > 500 then
    raise exception 'Cannot create % units at once. That many labels is almost certainly a typo; receive in smaller batches or check the quantity.', p_quantity;
  end if;
  v_remaining := v_line.quantity_ordered - v_line.quantity_received;
  if p_quantity > v_remaining then raise exception 'Receipt exceeds remaining quantity'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_line.variant_id::text || ':' || v_po.destination_location_id::text || ':Prime', 7137));
  select id, on_hand_quantity into v_position_id, v_old_on_hand from public.inventory_positions where variant_id = v_line.variant_id and location_id = v_po.destination_location_id and disposition = 'Prime' and sublocation_id is null for update;
  if not found then
    insert into public.inventory_positions (variant_id, location_id, disposition, on_hand_quantity, committed_quantity) values (v_line.variant_id, v_po.destination_location_id, 'Prime', p_quantity, 0) returning id into v_position_id;
    v_old_on_hand := 0;
  else
    update public.inventory_positions set on_hand_quantity = on_hand_quantity + p_quantity, updated_at = now() where id = v_position_id;
  end if;
  insert into public.stock_ledger_entries (variant_id, location_id, disposition, quantity_delta, reason, reference_type, actor_id) values (v_line.variant_id, v_po.destination_location_id, 'Prime', p_quantity, 'purchase_order_receipt', 'purchase_order_line_item', v_actor::text);
  if public.is_unit_tracked(v_line.variant_id) then
    for i in 1..p_quantity loop
      v_new_unit := public.create_unit(
        v_company_id, v_line.variant_id, v_po.destination_location_id,
        'Prime', p_line_item_id, v_actor);
      v_unit_ids := v_unit_ids || v_new_unit;
      v_unit_numbers := v_unit_numbers || (
        select unit_number from public.units where id = v_new_unit);
    end loop;
  end if;
  perform set_config('app.po_line_receiving', 'true', true);
  v_new_received := v_line.quantity_received + p_quantity;
  update public.purchase_order_line_items set quantity_received = v_new_received, updated_at = now() where id = v_line.id;
  select case when exists (select 1 from public.purchase_order_line_items where purchase_order_id = v_po.id and quantity_received < quantity_ordered) then 'partially_received' else 'received' end into v_new_status;
  update public.purchase_orders set status = v_new_status, received_at = case when v_new_status = 'received' then now() else received_at end where id = v_po.id;
  insert into public.purchase_order_events (purchase_order_id, event_type, event_data, actor_id) values (v_po.id, case when v_new_status = 'received' then 'received' else 'partially_received' end, jsonb_build_object('line_item_id', v_line.id, 'quantity', p_quantity, 'destination_location_id', v_po.destination_location_id), v_actor);
  perform public.evaluate_pending_inventory_for_variant(v_line.variant_id, v_po.destination_location_id);
  -- New units may fill waiting orders company-wide; each cross-location
  -- fill syncs a journey_mismatch transfer and its origin hold.
  if v_unit_ids <> '{}' then
    begin
      perform public.assign_received_units_to_orders(
        v_unit_ids, v_line.variant_id, v_po.destination_location_id, v_company_id);
    exception when others then
      v_assign_failed := true;
      insert into public.audit_events (
        company_id, actor_type, entity_type, entity_id,
        event_type, after
      ) values (
        v_company_id, 'SYSTEM', 'purchase_order_line_item', v_line.id,
        'UNIT_ORDER_ASSIGN_FAILED',
        jsonb_build_object('error', sqlerrm, 'variant_id', v_line.variant_id,
          'location_id', v_po.destination_location_id)
      );
    end;
  end if;
  if v_unit_ids <> '{}' then
    select coalesce(jsonb_agg(jsonb_build_object(
        'unit_id', u.id,
        'unit_number', u.unit_number,
        'journey_id', jir.journey_id,
        'journey_number', sj.journey_number,
        'customer_name', nullif(trim(concat_ws(' ', c.first_name, c.last_name)), ''),
        'requirement_id', jir.id
      ) order by u.unit_number), '[]'::jsonb)
    into v_assignments
    from public.units u
    join public.journey_inventory_requirements jir
      on jir.id = u.assigned_requirement_id
    join public.sleep_journeys sj on sj.id = jir.journey_id
    join public.customers c on c.id = sj.customer_id
    where u.id = any(v_unit_ids);
  end if;
  return jsonb_build_object(
    'unit_ids', v_unit_ids,
    'unit_numbers', v_unit_numbers,
    'assignments', v_assignments,
    'assign_failed', v_assign_failed);
end;
$$;

comment on function public.receive_purchase_order_line(uuid, integer) is
  'Receives a purchase-order line into stock. For unit-tracked products it
   also creates one unit per piece, hands new units (plus older stock at
   the same warehouse) to waiting customer orders company-wide, and keeps
   a held journey_mismatch transfer to each pickup store in sync. Returns
   unit ids, numbers, assignments and an assign_failed flag.';

grant execute on function public.receive_purchase_order_line(uuid, integer) to authenticated;
revoke execute on function public.receive_purchase_order_line(uuid, integer) from public, anon;
