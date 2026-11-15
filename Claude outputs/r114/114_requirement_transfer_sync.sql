-- ============================================================================
-- Migration 114: server-side order-mismatch sourcing.
--
-- The journey_mismatch request + origin hold used to be created by a
-- useEffect in the order workspace — only while someone had the order open.
-- Now the database creates and maintains it at write time.
--
-- Single source of truth: sync_requirement_request computes what a
-- requirement still needs from another location and is called from
-- reconcile_requirement_units, from the requirement trigger, and from the
-- journey state trigger. Quantity up grows the open request and its
-- held_quantity; quantity down shrinks both; cancel/Quoted releases both.
-- All trigger calls are exception-wrapped into audit_events — a failure
-- never rolls back the sale.
-- ============================================================================

-- 1. sync_order_transfer: 113 logic plus uncovered-shortfall in the target.
--    Open request quantity = units riding at the origin (minus what a
--    consolidated transfer already covers) + remaining uncovered need.

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
    and status = 'consolidated';

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

  v_target := greatest(0, v_need - v_consolidated) + v_shortfall;

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

-- 2. sync_requirement_request: the ONE place that decides what a
--    requirement still needs from another location.
--      * live requirement with uncovered need and no open request ->
--        create_journey_mismatch_transfer (warehouse-first, holds
--        held_quantity = quantity at the chosen origin, same as 113)
--      * open request exists -> sync it at each origin
--      * cancelled/superseded/quoted/cancelled-journey -> cancel open
--        requests and release holds
--    Idempotent: run twice, nothing changes.

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

-- 3. reconcile_requirement_units: 113 logic; the per-origin post-pass is
--    replaced by the shared sync_requirement_request call so requirement
--    edits, unit changes and triggers all take the same path.

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

  -- Requirement-level request sync runs even for untracked products
  -- (order-time sourcing is product-agnostic); the unit work below is not.
  perform public.sync_requirement_request(p_requirement_id);

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
    for i in reverse v_count..1 loop
      perform public.move_unit(v_assigned[i], 'STOCK', null, '{}'::jsonb);
    end loop;
    v_count := 0;
    if v_req.status in ('cancelled', 'superseded')
       or v_journey.cancelled_at is not null
       or v_journey.current_state = 'Quoted' then
      perform public.cancel_journey_mismatch_requests(
        v_req.journey_id, v_req.variant_id, v_req.location_id);
    end if;
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

-- 4. Triggers. Both write paths funnel through
--    trg_sync_requirement_request, which exception-wraps the shared
--    function into audit_events and never aborts the caller's work.

create or replace function public.trg_sync_requirement_request(p_requirement_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_jid uuid;
  v_vid uuid;
  v_company uuid;
begin
  select journey_id, variant_id into v_jid, v_vid
  from public.journey_inventory_requirements
  where id = p_requirement_id;
  begin
    perform public.sync_requirement_request(p_requirement_id);
  exception when others then
    select s.company_id into v_company
    from public.sleep_journeys sj
    join public.stores s on s.id = sj.store_id
    where sj.id = v_jid;
    insert into public.audit_events (
      company_id, actor_type, entity_type, entity_id, journey_id,
      event_type, after
    ) values (
      v_company, 'SYSTEM', 'journey_inventory_requirement', p_requirement_id,
      v_jid, 'JM_REQUEST_SYNC_FAILED',
      jsonb_build_object('error', sqlerrm, 'requirement_id', p_requirement_id,
        'journey_id', v_jid, 'variant_id', v_vid)
    );
  end;
end;
$$;

revoke execute on function public.trg_sync_requirement_request(uuid)
  from public, anon, authenticated;

create or replace function public.jm_requirement_sync()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.trg_sync_requirement_request(new.id);
  return new;
end;
$$;

drop trigger if exists trg_jm_requirement_sync on public.journey_inventory_requirements;
create trigger trg_jm_requirement_sync
  after insert or update of quantity_required, location_id, status
  on public.journey_inventory_requirements
  for each row execute function public.jm_requirement_sync();

create or replace function public.jm_journey_state_sync()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rid uuid;
begin
  if (new.cancelled_at is not null and old.cancelled_at is null)
     or (new.current_state = 'Quoted' and old.current_state is distinct from 'Quoted') then
    perform public.cancel_journey_mismatch_requests(new.id);
  elsif new.current_state is distinct from 'Quoted'
        and new.cancelled_at is null
        and (old.current_state = 'Quoted' or old.cancelled_at is not null) then
    for v_rid in
      select id from public.journey_inventory_requirements
      where journey_id = new.id
        and status in ('pending', 'ready')
    loop
      perform public.trg_sync_requirement_request(v_rid);
    end loop;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_jm_journey_state_sync on public.sleep_journeys;
create trigger trg_jm_journey_state_sync
  after update of current_state, cancelled_at on public.sleep_journeys
  for each row execute function public.jm_journey_state_sync();

-- Note: receive_purchase_order_line's assign_failed path already writes a
-- UNIT_ORDER_ASSIGN_FAILED audit_events row (112) — nothing swallowed.
