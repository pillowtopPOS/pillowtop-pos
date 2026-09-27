-- PillowTop POS: transfer stock reservations + request groups + ship/finalize gating
--
-- Part A — reserve stock at approval.
--   approve_transfer_request now increments inventory_positions.committed_quantity
--   at the origin by the request's quantity, inside the same row-locked read
--   that performs the availability check, so two concurrent approvals against
--   the same origin/variant cannot both pass.
--   cancel_transfer_request releases that reservation when cancelling an
--   approved request (nothing to release for pending_approval).
--   finalize_transfer releases the reservation at the origin per line item by
--   quantity_requested — the amount originally committed — regardless of what
--   was actually shipped/received. (finalize_transfer only ever increments
--   on_hand at the destination; the origin decrement happens at
--   mark_transfer_in_transit, unchanged.)
--
--   mark_transfer_in_transit keeps its "don't ship committed stock" guard but
--   now excludes this line's own reservation from the committed total —
--   otherwise a fully committed shipment could never be marked in transit.
--   Reservations stay held between ship and finalize by design (the spec's
--   model: the reservation's job ends at finalize regardless of outcome).
--
--   Releases are clamped with greatest(0, ...) because requests approved before
--   this migration (or born-approved threshold_auto rows predating the cron
--   change below) hold no reservation — an unclamped release could push
--   committed_quantity negative, violating its check constraint.
--
--   run_transfer_cron_for_date also commits stock when it creates
--   born-approved threshold_auto requests, so the "approved => committed"
--   invariant holds for every path, not just approve_transfer_request.
--
-- Part B — transfer_requests.request_group_id ties together the rows created
--   by one multi-item manual request submission, and
--   expedite_transfer_request_group turns a whole group into ONE transfer
--   atomically.
--
-- Part C — mark_transfer_in_transit and finalize_transfer now use
--   verify_transfer_approver (owner/admin or warehouse-based), matching
--   approve/reject/cancel. Store managers can no longer ship or finalize.

-- 1. request_group_id

alter table public.transfer_requests
  add column if not exists request_group_id uuid;

create index if not exists idx_transfer_requests_group
  on public.transfer_requests (request_group_id)
  where request_group_id is not null;

-- 2. approve_transfer_request: commit stock on approval (row-locked)

create or replace function public.approve_transfer_request(
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
  v_pos public.inventory_positions%rowtype;
  v_available integer;
  v_origin_name text;
  v_product_name text;
begin
  v_actor := public.verify_transfer_approver(p_employee_id);

  select * into v_req
  from public.transfer_requests
  where id = p_request_id
  for update;

  if not found then
    raise exception 'Transfer request not found';
  end if;

  if v_req.status <> 'pending_approval' then
    raise exception 'Only pending_approval requests can be approved';
  end if;

  if not (public.is_store_visible(v_req.origin_location_id) or public.is_store_visible(v_req.destination_location_id)) then
    raise exception 'Transfer request is not visible to this employee';
  end if;

  -- Lock the origin position row so the availability check and the commit
  -- increment are atomic against other approvals.
  perform pg_advisory_xact_lock(
    hashtextextended(v_req.variant_id::text || ':' || v_req.origin_location_id::text || ':Prime', 7137)
  );

  select * into v_pos
  from public.inventory_positions
  where variant_id = v_req.variant_id
    and location_id = v_req.origin_location_id
    and disposition = 'Prime'
    and sublocation_id is null
  for update;

  v_available := coalesce(v_pos.on_hand_quantity, 0) - coalesce(v_pos.committed_quantity, 0);

  if v_req.quantity > v_available then
    select coalesce(s.name, v_req.origin_location_id::text) into v_origin_name
    from public.stores s where s.id = v_req.origin_location_id;

    select coalesce(p.item_name, v_req.variant_id::text) into v_product_name
    from public.products p where p.id = v_req.variant_id;

    raise exception 'Origin "%" has only % units of "%" available; requested %',
      v_origin_name, v_available, v_product_name, v_req.quantity;
  end if;

  update public.inventory_positions
    set committed_quantity = committed_quantity + v_req.quantity,
        updated_at = now()
  where id = v_pos.id;

  update public.transfer_requests
    set status = 'approved',
        approved_by = v_actor,
        approved_at = now()
  where id = p_request_id;
end;
$$;

grant execute on function public.approve_transfer_request(uuid, uuid) to authenticated;

-- 3. cancel_transfer_request: release the reservation when cancelling an
--    approved request

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

  -- Approved requests hold an origin reservation; release it.
  if v_req.status = 'approved' then
    perform pg_advisory_xact_lock(
      hashtextextended(v_req.variant_id::text || ':' || v_req.origin_location_id::text || ':Prime', 7137)
    );
    update public.inventory_positions
      set committed_quantity = greatest(0, committed_quantity - v_req.quantity),
          updated_at = now()
    where variant_id = v_req.variant_id
      and location_id = v_req.origin_location_id
      and disposition = 'Prime'
      and sublocation_id is null;
  end if;

  update public.transfer_requests
    set status = 'cancelled'
  where id = p_request_id;
end;
$$;

grant execute on function public.cancel_transfer_request(uuid, uuid) to authenticated;

-- 4. mark_transfer_in_transit: approver-gated (Part C) + exclude the line's
--    own reservation from the committed-stock guard (Part A)

create or replace function public.mark_transfer_in_transit(
  p_transfer_id uuid,
  p_employee_id uuid,
  p_shipped jsonb default null
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
      set quantity_shipped = v_ship_qty
    where id = v_line.id;
  end loop;

  update public.transfers
    set status = 'in_transit',
        in_transit_at = now()
  where id = p_transfer_id;
end;
$$;

grant execute on function public.mark_transfer_in_transit(uuid, uuid, jsonb) to authenticated;

-- 5. finalize_transfer: approver-gated (Part C) + release the origin
--    reservation per line by quantity_requested (Part A)

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

    -- Release the approval-time reservation at the origin, by the amount
    -- originally committed (quantity_requested) regardless of what arrived.
    perform pg_advisory_xact_lock(
      hashtextextended(v_line.variant_id::text || ':' || v_t.origin_location_id::text || ':Prime', 7137)
    );
    update public.inventory_positions
      set committed_quantity = greatest(0, committed_quantity - v_line.quantity_requested),
          updated_at = now()
    where variant_id = v_line.variant_id
      and location_id = v_t.origin_location_id
      and disposition = 'Prime'
      and sublocation_id is null;

    update public.transfer_line_items
      set quantity_received = v_recv
    where id = v_line.id;
  end loop;

  update public.transfers
    set status = 'finalized',
        finalized_at = now(),
        finalized_by = v_actor
  where id = p_transfer_id;
end;
$$;

grant execute on function public.finalize_transfer(uuid, jsonb, uuid) to authenticated;

-- 6. run_transfer_cron_for_date: born-approved threshold_auto requests commit
--    stock at creation, so "approved => committed" holds on every path.
--    Everything else identical to the 042 definition.

create or replace function public.run_transfer_cron_for_date(p_run_date date)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_target_date date := p_run_date + interval '1 day';
  v_target_dow integer := extract(dow from v_target_date);
  v_store record;
  v_par record;
  v_ats integer;
  v_need integer;
  v_origin record;
  v_route record;
  v_new_transfer_id uuid;
  v_total integer;
  v_existing_request_id uuid;
  v_existing_transfer_id uuid;
begin
  -- Threshold check: for every active store with an assigned warehouse whose
  -- company is in 'automatic' restock mode, compare Prime ATS per product to
  -- that store's par-level reorder_point.
  for v_store in
    select s.id, s.company_id, s.assigned_warehouse_id
    from public.stores s
    join public.companies c on c.id = s.company_id
    where s.is_active = true
      and s.assigned_warehouse_id is not null
      and s.assigned_warehouse_id <> s.id
      and c.restock_generation_mode = 'automatic'
  loop
    for v_par in
      select pl.id as par_level_id, pl.variant_id, pl.reorder_point, pl.target_quantity
      from public.par_levels pl
      where pl.store_id = v_store.id
    loop
      select coalesce(ip.on_hand_quantity, 0) - coalesce(ip.committed_quantity, 0)
      into v_ats
      from public.inventory_positions ip
      where ip.variant_id = v_par.variant_id
        and ip.location_id = v_store.id
        and ip.disposition = 'Prime'
        and ip.sublocation_id is null;

      if v_ats is null then v_ats := 0; end if;

      if v_ats <= v_par.reorder_point then
        v_need := v_par.target_quantity - v_ats;
        if v_need > 0 then
          -- Do not create a duplicate unconsolidated threshold_auto request for
          -- this exact product + origin + destination.
          select id into v_existing_request_id
          from public.transfer_requests
          where origin_location_id = v_store.assigned_warehouse_id
            and destination_location_id = v_store.id
            and variant_id = v_par.variant_id
            and source_type = 'threshold_auto'
            and status not in ('consolidated', 'cancelled', 'rejected')
          limit 1;

          if v_existing_request_id is null then
            insert into public.transfer_requests (
              origin_location_id,
              destination_location_id,
              variant_id,
              quantity,
              source_type,
              source_reference_id,
              status
            ) values (
              v_store.assigned_warehouse_id,
              v_store.id,
              v_par.variant_id,
              v_need,
              'threshold_auto',
              v_par.par_level_id,
              'approved'
            );

            -- Born-approved requests hold stock like ones approved through
            -- approve_transfer_request: commit at the origin warehouse.
            perform pg_advisory_xact_lock(
              hashtextextended(v_par.variant_id::text || ':' || v_store.assigned_warehouse_id::text || ':Prime', 7137)
            );
            update public.inventory_positions
              set committed_quantity = committed_quantity + v_need,
                  updated_at = now()
            where variant_id = v_par.variant_id
              and location_id = v_store.assigned_warehouse_id
              and disposition = 'Prime'
              and sublocation_id is null;
            if not found then
              insert into public.inventory_positions (
                variant_id, location_id, disposition,
                on_hand_quantity, committed_quantity
              ) values (
                v_par.variant_id, v_store.assigned_warehouse_id, 'Prime',
                0, v_need
              );
            end if;
          end if;
        end if;
      end if;
    end loop;
  end loop;

  -- Consolidation: for every destination whose transfer_schedule_day is tomorrow,
  -- and every origin with approved requests bound for that destination, create one
  -- consolidated transfer per exact origin->destination route.
  for v_route in
    select distinct
      r.origin_location_id,
      r.destination_location_id
    from public.transfer_requests r
    join public.stores d on d.id = r.destination_location_id
    where r.status = 'approved'
      and d.transfer_schedule_day = v_target_dow
      and d.is_active = true
  loop
    select id into v_existing_transfer_id
    from public.transfers
    where origin_location_id = v_route.origin_location_id
      and destination_location_id = v_route.destination_location_id
      and scheduled_date = v_target_date
    limit 1;

    if v_existing_transfer_id is not null then
      continue;
    end if;

    insert into public.transfers (
      origin_location_id,
      destination_location_id,
      status,
      scheduled_date
    ) values (
      v_route.origin_location_id,
      v_route.destination_location_id,
      'pending',
      v_target_date
    ) returning id into v_new_transfer_id;

    -- Aggregate per-variant quantities for this route
    insert into public.transfer_line_items (
      transfer_id,
      variant_id,
      quantity_requested
    )
    select
      v_new_transfer_id,
      r.variant_id,
      sum(r.quantity)
    from public.transfer_requests r
    where r.status = 'approved'
      and r.origin_location_id = v_route.origin_location_id
      and r.destination_location_id = v_route.destination_location_id
    group by r.variant_id;

    -- Mark the contributing requests as consolidated
    update public.transfer_requests
      set status = 'consolidated',
          transfer_id = v_new_transfer_id
    where status = 'approved'
      and origin_location_id = v_route.origin_location_id
      and destination_location_id = v_route.destination_location_id;
  end loop;
end;
$$;

revoke execute on function public.run_transfer_cron_for_date(date) from authenticated;
revoke execute on function public.run_transfer_cron_for_date(date) from public;
grant execute on function public.run_transfer_cron_for_date(date) to service_role;

-- 7. expedite_transfer_request_group: one approved group -> one transfer,
--    atomically, off-schedule.

create or replace function public.expedite_transfer_request_group(
  p_group_id uuid,
  p_employee_id uuid,
  p_scheduled_date date
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid;
  v_req public.transfer_requests%rowtype;
  v_count integer := 0;
  v_new_transfer_id uuid;
begin
  if p_scheduled_date is null then
    raise exception 'A scheduled date is required';
  end if;
  if p_scheduled_date < current_date then
    raise exception 'Scheduled date cannot be in the past';
  end if;

  v_actor := public.verify_transfer_approver(p_employee_id);

  -- Lock and validate every member before creating anything: all-or-nothing.
  for v_req in
    select * from public.transfer_requests
    where request_group_id = p_group_id
    order by created_at
    for update
  loop
    v_count := v_count + 1;
    if v_req.status <> 'approved' or v_req.transfer_id is not null then
      raise exception 'Every request in the group must be approved and unconsolidated to expedite';
    end if;
    if not (public.is_store_visible(v_req.origin_location_id) or public.is_store_visible(v_req.destination_location_id)) then
      raise exception 'Transfer request is not visible to this employee';
    end if;
  end loop;

  if v_count = 0 then
    raise exception 'Request group not found';
  end if;

  -- Members of a group share one origin/destination by construction.
  select * into v_req
  from public.transfer_requests
  where request_group_id = p_group_id
  order by created_at
  limit 1;

  insert into public.transfers (
    origin_location_id,
    destination_location_id,
    status,
    scheduled_date
  ) values (
    v_req.origin_location_id,
    v_req.destination_location_id,
    'pending',
    p_scheduled_date
  ) returning id into v_new_transfer_id;

  insert into public.transfer_line_items (
    transfer_id,
    variant_id,
    quantity_requested
  )
  select
    v_new_transfer_id,
    r.variant_id,
    sum(r.quantity)
  from public.transfer_requests r
  where r.request_group_id = p_group_id
  group by r.variant_id;

  update public.transfer_requests
    set status = 'consolidated',
        transfer_id = v_new_transfer_id
  where request_group_id = p_group_id;
end;
$$;

grant execute on function public.expedite_transfer_request_group(uuid, uuid, date) to authenticated;
