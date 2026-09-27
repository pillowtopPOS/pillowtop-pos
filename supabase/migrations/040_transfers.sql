-- PillowTop POS Phase 7d-ii: stock transfers between locations

-- 0. Stores need a schedule day to participate in automatic consolidation.
--    NULL means manual/finalize works, but no auto-consolidation.

alter table public.stores
  add column if not exists transfer_schedule_day integer
  check (transfer_schedule_day is null or transfer_schedule_day between 0 and 6);

-- 1. Enums

do $$
begin
  if not exists (select 1 from pg_type where typname = 'transfer_source_type') then
    create type public.transfer_source_type as enum (
      'manager_requested',
      'journey_mismatch',
      'manual',
      'threshold_auto'
    );
  end if;
  if not exists (select 1 from pg_type where typname = 'transfer_request_status') then
    create type public.transfer_request_status as enum (
      'pending_approval',
      'approved',
      'rejected',
      'consolidated',
      'cancelled'
    );
  end if;
  if not exists (select 1 from pg_type where typname = 'transfer_status') then
    create type public.transfer_status as enum (
      'pending',
      'in_transit',
      'finalized',
      'cancelled'
    );
  end if;
end $$;

grant usage on type public.transfer_source_type to authenticated;
grant usage on type public.transfer_request_status to authenticated;
grant usage on type public.transfer_status to authenticated;

-- 2. Cron state table (so the once-per-day guard is durable)

create table if not exists public.cron_state (
  task_name text primary key,
  last_run_date date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.cron_state is 'Tracks last-run dates for /api/cron tasks';

alter table public.cron_state enable row level security;

create policy "Cron state viewable by authenticated" on public.cron_state
  for select to authenticated using (true);

create policy "Cron state manageable by owner admin" on public.cron_state
  for all to authenticated
  using (public.current_employee_role()::text in ('owner', 'admin'))
  with check (public.current_employee_role()::text in ('owner', 'admin'));

-- 3. Core transfer tables

-- transfers must exist before transfer_requests can reference it via transfer_id,
-- and before transfer_line_items can reference it via transfer_id.
create table if not exists public.transfers (
  id uuid primary key default gen_random_uuid(),
  origin_location_id uuid not null references public.stores(id) on delete restrict,
  destination_location_id uuid not null references public.stores(id) on delete restrict,
  status public.transfer_status not null default 'pending',
  scheduled_date date not null,
  created_at timestamptz not null default now(),
  in_transit_at timestamptz,
  finalized_at timestamptz,
  finalized_by uuid references public.employees(id) on delete set null,
  constraint transfer_origin_neq_destination check (origin_location_id <> destination_location_id)
);

comment on table public.transfers is 'Consolidated shipment for one origin->destination route on one scheduled day';

create index if not exists idx_transfers_origin
  on public.transfers (origin_location_id);
create index if not exists idx_transfers_destination
  on public.transfers (destination_location_id);
create index if not exists idx_transfers_status
  on public.transfers (status);
create index if not exists idx_transfers_scheduled
  on public.transfers (scheduled_date);

create table if not exists public.transfer_requests (
  id uuid primary key default gen_random_uuid(),
  origin_location_id uuid not null references public.stores(id) on delete restrict,
  destination_location_id uuid not null references public.stores(id) on delete restrict,
  variant_id uuid not null references public.products(id) on delete restrict,
  quantity integer not null check (quantity > 0),
  source_type public.transfer_source_type not null,
  source_reference_id uuid,
  status public.transfer_request_status not null default 'pending_approval',
  requested_by uuid references public.employees(id) on delete set null,
  approved_by uuid references public.employees(id) on delete set null,
  approved_at timestamptz,
  transfer_id uuid references public.transfers(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint transfer_request_origin_neq_destination check (origin_location_id <> destination_location_id)
);

comment on table public.transfer_requests is 'Granular stock-movement needs before consolidation';

create index if not exists idx_transfer_requests_origin
  on public.transfer_requests (origin_location_id);
create index if not exists idx_transfer_requests_destination
  on public.transfer_requests (destination_location_id);
create index if not exists idx_transfer_requests_status
  on public.transfer_requests (status);
create index if not exists idx_transfer_requests_transfer
  on public.transfer_requests (transfer_id);

create table if not exists public.transfer_line_items (
  id uuid primary key default gen_random_uuid(),
  transfer_id uuid not null references public.transfers(id) on delete cascade,
  variant_id uuid not null references public.products(id) on delete restrict,
  quantity_requested integer not null check (quantity_requested > 0),
  quantity_shipped integer not null default 0 check (quantity_shipped >= 0),
  quantity_received integer not null default 0 check (quantity_received >= 0),
  constraint transfer_line_shipped_lte_requested check (quantity_shipped <= quantity_requested),
  constraint transfer_line_received_lte_shipped check (quantity_received <= quantity_shipped),
  unique (transfer_id, variant_id)
);

comment on table public.transfer_line_items is 'Aggregated product quantities inside a consolidated transfer';

create index if not exists idx_transfer_line_items_transfer
  on public.transfer_line_items (transfer_id);

-- 3a. Cross-company guard for transfer routes

-- A transfer request or consolidated transfer must move stock between two
-- locations that belong to the same company. This is enforced at the row
-- level so the existing OR-based visibility checks remain safe by construction.
create or replace function public.validate_transfer_same_company()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_origin_company_id uuid;
  v_destination_company_id uuid;
begin
  select company_id into v_origin_company_id
  from public.stores
  where id = new.origin_location_id;

  select company_id into v_destination_company_id
  from public.stores
  where id = new.destination_location_id;

  if v_origin_company_id is distinct from v_destination_company_id then
    raise exception 'Transfer origin and destination must belong to the same company';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_validate_transfer_request_same_company on public.transfer_requests;
create trigger trg_validate_transfer_request_same_company
  before insert or update on public.transfer_requests
  for each row
  execute function public.validate_transfer_same_company();

drop trigger if exists trg_validate_transfer_same_company on public.transfers;
create trigger trg_validate_transfer_same_company
  before insert or update on public.transfers
  for each row
  execute function public.validate_transfer_same_company();

-- 4. RLS policies

alter table public.transfer_requests enable row level security;
alter table public.transfers enable row level security;
alter table public.transfer_line_items enable row level security;

create policy "Transfer requests viewable by visible location" on public.transfer_requests
  for select to authenticated
  using (public.is_store_visible(origin_location_id) or public.is_store_visible(destination_location_id));

-- Client-side inserts are allowed only for fresh, unapproved, human-originated requests.
-- Status transitions (approve/reject/cancel/consolidate) are forced through
-- security-definer functions; no client UPDATE or DELETE is permitted.
create policy "Transfer requests client insert only" on public.transfer_requests
  for insert to authenticated
  with check (
    public.current_employee_role()::text in ('owner', 'admin', 'manager')
    and (public.is_store_visible(origin_location_id) or public.is_store_visible(destination_location_id))
    and source_type in ('manager_requested', 'manual')
    and status = 'pending_approval'
    and approved_by is null
    and approved_at is null
    and transfer_id is null
  );

create policy "Transfers viewable by visible location" on public.transfers
  for select to authenticated
  using (public.is_store_visible(origin_location_id) or public.is_store_visible(destination_location_id));

create policy "Transfer line items viewable by visible transfer" on public.transfer_line_items
  for select to authenticated
  using (exists (
    select 1 from public.transfers t
    where t.id = transfer_id
      and (public.is_store_visible(t.origin_location_id) or public.is_store_visible(t.destination_location_id))
  ));

-- 5. Table grants
--    transfer_requests can be SELECTed/INSERTed by clients (under the strict policy above).
--    transfers and transfer_line_items are written only via atomic security-definer
--    functions, never directly by clients — same pattern as inventory_positions.

grant select, insert on public.transfer_requests to authenticated;
grant select on public.transfers to authenticated;
grant select on public.transfer_line_items to authenticated;
grant select, insert, update, delete on public.cron_state to authenticated;

-- 6. Helper: verify the acting employee is owner/admin/manager and belongs to the company
--    of at least one of the two stores. Returns the employee id if valid.

create or replace function public.verify_transfer_actor(p_employee_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_emp public.employees%rowtype;
begin
  if p_employee_id is null then
    raise exception 'Employee id is required';
  end if;

  select * into v_emp from public.employees where id = p_employee_id;
  if not found then
    raise exception 'Employee not found';
  end if;

  if v_emp.auth_user_id is distinct from auth.uid() then
    raise exception 'Employee does not match the authenticated user';
  end if;

  if v_emp.role::text not in ('owner', 'admin', 'manager') then
    raise exception 'Only owner, admin, or manager can manage transfers';
  end if;

  return v_emp.id;
end;
$$;

grant execute on function public.verify_transfer_actor(uuid) to authenticated;

-- 7. Approve, reject, cancel a transfer request

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
  v_available integer;
  v_origin_name text;
  v_product_name text;
begin
  v_actor := public.verify_transfer_actor(p_employee_id);

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

  -- Revalidate origin stock at approval time (covers all source types and
  -- catches stock changes since the request was created).
  select coalesce(ip.on_hand_quantity, 0) - coalesce(ip.committed_quantity, 0)
  into v_available
  from public.inventory_positions ip
  where ip.variant_id = v_req.variant_id
    and ip.location_id = v_req.origin_location_id
    and ip.disposition = 'Prime'
    and ip.sublocation_id is null;

  if v_available is null then
    v_available := 0;
  end if;

  if v_req.quantity > v_available then
    select coalesce(s.name, v_req.origin_location_id::text) into v_origin_name
    from public.stores s where s.id = v_req.origin_location_id;

    select coalesce(p.item_name, v_req.variant_id::text) into v_product_name
    from public.products p where p.id = v_req.variant_id;

    raise exception 'Origin "%" has only % units of "%" available; requested %',
      v_origin_name, v_available, v_product_name, v_req.quantity;
  end if;

  update public.transfer_requests
    set status = 'approved',
        approved_by = v_actor,
        approved_at = now()
  where id = p_request_id;
end;
$$;

grant execute on function public.approve_transfer_request(uuid, uuid) to authenticated;

create or replace function public.reject_transfer_request(
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
  v_actor := public.verify_transfer_actor(p_employee_id);

  select * into v_req
  from public.transfer_requests
  where id = p_request_id
  for update;

  if not found then raise exception 'Transfer request not found'; end if;
  if v_req.status <> 'pending_approval' then
    raise exception 'Only pending_approval requests can be rejected';
  end if;
  if not (public.is_store_visible(v_req.origin_location_id) or public.is_store_visible(v_req.destination_location_id)) then
    raise exception 'Transfer request is not visible to this employee';
  end if;

  update public.transfer_requests
    set status = 'rejected'
  where id = p_request_id;
end;
$$;

grant execute on function public.reject_transfer_request(uuid, uuid) to authenticated;

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
  v_actor := public.verify_transfer_actor(p_employee_id);

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

  update public.transfer_requests
    set status = 'cancelled'
  where id = p_request_id;
end;
$$;

grant execute on function public.cancel_transfer_request(uuid, uuid) to authenticated;

-- 8. Atomic ship: mark a transfer in_transit and decrement origin stock

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
begin
  v_actor := public.verify_transfer_actor(p_employee_id);

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
    if v_new_on_hand < v_pos.committed_quantity then
      raise exception 'Cannot ship % units of variant % — % are committed to open orders at the origin',
        v_ship_qty, v_line.variant_id, v_pos.committed_quantity;
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

-- 9. Atomic receive: finalize a transfer and increment destination stock

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
  v_actor := public.verify_transfer_actor(p_employee_id);

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

-- 10. Cron logic: threshold check + consolidation, run as one idempotent day

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
  -- Threshold check: for every active store with an assigned warehouse,
  -- compare Prime ATS per product to that store's par-level reorder_point.
  for v_store in
    select s.id, s.company_id, s.assigned_warehouse_id
    from public.stores s
    where s.is_active = true
      and s.assigned_warehouse_id is not null
      and s.assigned_warehouse_id <> s.id
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

-- This function is intended to be called only from /api/cron via a service-role
-- connection. It is not exposed to client-side authenticated users.
revoke execute on function public.run_transfer_cron_for_date(date) from authenticated;
revoke execute on function public.run_transfer_cron_for_date(date) from public;
grant execute on function public.run_transfer_cron_for_date(date) to service_role;

-- 11. Journey mismatch helper: create an approved transfer request when a journey's
--     fulfillment location doesn't have stock but another visible location does.

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

  -- Look up the destination store for the journey
  select s.* into v_journey_store
  from public.sleep_journeys sj
  join public.stores s on s.id = sj.store_id
  where sj.id = p_journey_id;

  if not found then raise exception 'Journey not found'; end if;

  -- The fulfillment location is the destination for the transfer
  if p_fulfillment_location_id is null then
    p_fulfillment_location_id := v_journey_store.id;
  end if;

  -- Find the best source: a visible store (including the journey store) with the
  -- highest Prime ATS for this product that is not the fulfillment location.
  select ip.location_id, (ip.on_hand_quantity - ip.committed_quantity) as available
  into v_origin, v_ats
  from public.inventory_positions ip
  where ip.variant_id = p_variant_id
    and ip.disposition = 'Prime'
    and ip.sublocation_id is null
    and ip.location_id <> p_fulfillment_location_id
    and exists (select 1 from public.stores s where s.id = ip.location_id and s.company_id = v_journey_store.company_id)
  order by available desc
  limit 1;

  if v_origin is null or v_ats <= 0 then
    return null;
  end if;

  v_need := least(v_need, v_ats);

  -- Avoid duplicate open journey_mismatch requests for the same journey+product+route.
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

  return v_req_id;
end;
$$;

grant execute on function public.create_journey_mismatch_transfer(uuid, uuid, integer, uuid) to authenticated;
