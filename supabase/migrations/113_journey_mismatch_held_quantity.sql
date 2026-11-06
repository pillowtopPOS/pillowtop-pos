-- ============================================================================
-- Migration 113: journey_mismatch hold bookkeeping + cancel propagation.
--
-- Fixes: cancelling an order left its open journey_mismatch request
-- 'approved' with its origin hold when no unit was ever assigned.
--
-- Held-quantity rule: transfer_requests.held_quantity is the amount the
-- request currently holds in committed_quantity at its origin. Only
-- requests created after 112 (>= 2026-11-06 13:00 UTC) ever placed a hold;
-- older journey_mismatch requests hold 0 and must release 0 (a release of
-- `quantity` would steal a hold belonging to a different order).
--
-- Backfill: approved non-journey_mismatch requests always held `quantity`
-- (approve_transfer_request), so they get held_quantity = quantity
-- regardless of age. Approved journey_mismatch requests get quantity only
-- at/after the 112 cutoff. pending_approval requests hold nothing.
-- ============================================================================

alter table public.transfer_requests
  add column if not exists held_quantity integer not null default 0;

update public.transfer_requests
   set held_quantity = quantity
 where status = 'approved'
   and (source_type is distinct from 'journey_mismatch'
        or created_at >= '2026-11-06 13:00:00+00'::timestamptz);

-- 1. Internal helper: release an open journey_mismatch request's hold and
--    cancel it. Skips consolidated requests and anything on a transfer.

create or replace function public.release_jm_request(p_request_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_req public.transfer_requests%rowtype;
begin
  select * into v_req from public.transfer_requests
  where id = p_request_id for update;
  if not found then return; end if;
  if v_req.status not in ('pending_approval', 'approved')
     or v_req.transfer_id is not null then
    return;
  end if;
  if v_req.held_quantity > 0 then
    perform pg_advisory_xact_lock(hashtextextended(
      v_req.variant_id::text || ':' || v_req.origin_location_id::text || ':Prime', 7137));
    update public.inventory_positions
      set committed_quantity = greatest(0, committed_quantity - v_req.held_quantity),
          updated_at = now()
    where variant_id = v_req.variant_id
      and location_id = v_req.origin_location_id
      and disposition = 'Prime' and sublocation_id is null;
  end if;
  update public.transfer_requests
    set status = 'cancelled', held_quantity = 0
  where id = v_req.id;
end;
$$;

revoke execute on function public.release_jm_request(uuid)
  from public, anon, authenticated;

create or replace function public.cancel_journey_mismatch_requests(
  p_journey_id uuid,
  p_variant_id uuid default null,
  p_destination_location_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  for v_id in
    select id from public.transfer_requests
    where source_type = 'journey_mismatch'
      and source_reference_id = p_journey_id
      and status in ('pending_approval', 'approved')
      and transfer_id is null
      and (p_variant_id is null or variant_id = p_variant_id)
      and (p_destination_location_id is null
           or destination_location_id = p_destination_location_id)
  loop
    perform public.release_jm_request(v_id);
  end loop;
end;
$$;

revoke execute on function public.cancel_journey_mismatch_requests(uuid, uuid, uuid)
  from public, anon, authenticated;

-- 2. create_journey_mismatch_transfer: same as 112 plus held_quantity.

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
    origin_location_id, destination_location_id, variant_id,
    quantity, held_quantity, source_type, source_reference_id, status
  ) values (
    v_origin, p_fulfillment_location_id, p_variant_id,
    v_need, v_need, 'journey_mismatch', p_journey_id, 'approved'
  ) returning id into v_req_id;

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

-- 3. sync_order_transfer: maintain held_quantity; when no units are
--    assigned, keep the request at the lesser of its size and the
--    remaining requirement shortfall (shrink on qty reduction), else cancel.

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

  v_target := greatest(0, v_need - v_consolidated);

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

  -- No units riding yet: the request is a proactive sourcing hold. Keep it
  -- at min(current size, remaining shortfall); cancel when nothing needed.
  if v_target = 0 and v_open.id is not null then
    select coalesce(sum(greatest(0,
              jir.quantity_required
              - (select count(*) from public.units u
                  where u.assigned_requirement_id = jir.id))), 0)
      into v_shortfall
    from public.journey_inventory_requirements jir
    where jir.journey_id = p_journey_id
      and jir.variant_id = p_variant_id
      and jir.location_id = p_destination_location_id
      and jir.status in ('pending', 'ready');
    v_target := least(v_open.quantity, v_shortfall);
  end if;

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

-- 4. reconcile_requirement_units: 112 logic, plus request cleanup on
--    cancel/supersede/quoted and a post-pass that syncs every open request
--    for this journey+variant+destination (covers shrink and the
--    never-assigned case).

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
  v_origin uuid;
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
    -- Only when the order/requirement is actually cancelled, superseded or
    -- back to Quoted. desired = 0 can also just mean "nothing reserved here
    -- yet" for an order still waiting on a transfer, which must keep its request.
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

  -- Post-pass: re-sync every open request for journey+variant+destination
  -- at its own origin (shrinks holds on qty reduction, including requests
  -- that never had a unit assigned).
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
end;
$$;

revoke execute on function public.reconcile_requirement_units(uuid)
  from public, anon, authenticated;

-- 5. Journey-level propagation: cancel or back-to-Quoted cancels ALL open
--    journey_mismatch requests for the journey.

create or replace function public.jm_on_journey_cancel()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if (new.cancelled_at is not null and old.cancelled_at is null)
     or (new.current_state = 'Quoted' and old.current_state is distinct from 'Quoted') then
    perform public.cancel_journey_mismatch_requests(new.id);
  end if;
  return new;
end;
$$;

drop trigger if exists trg_jm_on_journey_cancel on public.sleep_journeys;
create trigger trg_jm_on_journey_cancel
  after update on public.sleep_journeys
  for each row execute function public.jm_on_journey_cancel();

-- 6. Cron guard: a journey_mismatch request whose journey is cancelled can
--    never consolidate into a real transfer; it cancels and releases only
--    its own held_quantity instead.

create or replace function public.jm_cron_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cancelled boolean;
begin
  if new.status = 'consolidated'
     and old.status is distinct from 'consolidated'
     and old.source_type = 'journey_mismatch' then
    select (sj.cancelled_at is not null) into v_cancelled
    from public.sleep_journeys sj
    where sj.id = old.source_reference_id;
    if v_cancelled then
      if old.held_quantity > 0 then
        perform pg_advisory_xact_lock(hashtextextended(
          old.variant_id::text || ':' || old.origin_location_id::text || ':Prime', 7137));
        update public.inventory_positions
          set committed_quantity = greatest(0, committed_quantity - old.held_quantity),
              updated_at = now()
        where variant_id = old.variant_id
          and location_id = old.origin_location_id
          and disposition = 'Prime' and sublocation_id is null;
      end if;
      -- The cron inserts transfer_line_items before marking the request
      -- consolidated; back out this request's contribution (line items are
      -- merged per variant, so subtract rather than delete blindly).
      if new.transfer_id is not null then
        update public.transfer_line_items
          set quantity_requested = quantity_requested - old.quantity
        where transfer_id = new.transfer_id
          and variant_id = old.variant_id;
        delete from public.transfer_line_items
        where transfer_id = new.transfer_id
          and variant_id = old.variant_id
          and quantity_requested <= 0;
      end if;
      -- a transfer left with no lines would show as an empty transfer
      if not exists (select 1 from public.transfer_line_items
                      where transfer_id = new.transfer_id) then
        delete from public.transfers where id = new.transfer_id;
      end if;
      new.status := 'cancelled';
      new.transfer_id := null;
      new.held_quantity := 0;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_jm_cron_guard on public.transfer_requests;
create trigger trg_jm_cron_guard
  before update of status on public.transfer_requests
  for each row execute function public.jm_cron_guard();

-- 7. cancel_transfer_request: release held_quantity, not quantity, so a
--    pre-112 request (held_quantity 0) cannot steal another order's hold.

create or replace function public.cancel_transfer_request(
  p_request_id uuid,
  p_employee_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid;
  v_req public.transfer_requests%rowtype;
begin
  v_actor := public.verify_transfer_approver(p_employee_id);

  select * into v_req
  from public.transfer_requests
  where id = p_request_id
  for update;

  if not found then raise exception 'Transfer request not found'; end if;
  if v_req.status in ('consolidated', 'cancelled', 'rejected') then
    raise exception 'Transfer request cannot be cancelled in status %', v_req.status;
  end if;
  if not (public.is_store_visible(v_req.origin_location_id) or public.is_store_visible(v_req.destination_location_id)) then
    raise exception 'Transfer request is not visible to this employee';
  end if;

  if v_req.status = 'approved' and v_req.held_quantity > 0 then
    perform pg_advisory_xact_lock(
      hashtextextended(v_req.variant_id::text || ':' || v_req.origin_location_id::text || ':Prime', 7137)
    );
    update public.inventory_positions
      set committed_quantity = greatest(0, committed_quantity - v_req.held_quantity),
          updated_at = now()
    where variant_id = v_req.variant_id
      and location_id = v_req.origin_location_id
      and disposition = 'Prime'
      and sublocation_id is null;
  end if;

  update public.transfer_requests
    set status = 'cancelled', held_quantity = 0
  where id = p_request_id;
end;
$$;

grant execute on function public.cancel_transfer_request(uuid, uuid) to authenticated;

-- 8. Non-journey_mismatch requests entering 'approved' hold their quantity
--    (approve_transfer_request and the threshold_auto cron commit it).
create or replace function public.tr_set_held_on_approve()
returns trigger language plpgsql as $$
begin
  if new.status = 'approved'
     and new.source_type is distinct from 'journey_mismatch'
     and new.held_quantity = 0
     and (tg_op = 'INSERT' or old.status is distinct from 'approved') then
    new.held_quantity := new.quantity;
  end if;
  return new;
end;
$$;
drop trigger if exists trg_tr_set_held_on_approve on public.transfer_requests;
create trigger trg_tr_set_held_on_approve
  before insert or update of status on public.transfer_requests
  for each row execute function public.tr_set_held_on_approve();
