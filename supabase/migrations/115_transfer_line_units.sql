-- ============================================================================
-- S4a-1: unit-level pick for transfers (schema + preview + pick only).
--
-- transfer_line_units records WHICH physical units are on a shipment.
-- Nothing moves yet: ship/receive/finalize stay quantity-only until
-- S4a-2/3 extend them. Untracked variants never get rows here.
--
-- Pick rule (Zach): units already assigned to the destination's customer
-- orders go first, then oldest unit_number STOCK at the origin. A unit is
-- only ever picked from the transfer's own origin — warehouse-first is
-- enforced upstream by request creation.
-- ============================================================================

create table if not exists public.transfer_line_units (
  id uuid primary key default gen_random_uuid(),
  transfer_id uuid not null references public.transfers(id) on delete cascade,
  transfer_line_item_id uuid not null
    references public.transfer_line_items(id) on delete cascade,
  unit_id uuid not null references public.units(id) on delete restrict,
  unit_number bigint not null,
  picked_status text not null check (picked_status in ('STOCK', 'RESERVED')),
  picked_requirement_id uuid
    references public.journey_inventory_requirements(id) on delete set null,
  picked_by uuid references public.employees(id) on delete set null,
  picked_at timestamptz not null default now(),
  received_at timestamptz,
  received_by uuid references public.employees(id) on delete set null,
  missing_at timestamptz,
  missing_by uuid references public.employees(id) on delete set null,
  missing_reason text,
  unique (transfer_line_item_id, unit_id)
);

comment on table public.transfer_line_units is
  'Physical units picked onto a transfer shipment. Rows exist from pick '
  'until receive/missing resolves them; quantity accounting stays with '
  'transfer_line_items until S4a-2/3.';

-- A unit can be on at most one unresolved shipment at a time.
create unique index if not exists idx_tlu_one_inflight_unit
  on public.transfer_line_units (unit_id)
  where received_at is null and missing_at is null;
create index if not exists idx_tlu_transfer
  on public.transfer_line_units (transfer_id);
create index if not exists idx_tlu_line
  on public.transfer_line_units (transfer_line_item_id);

alter table public.transfer_line_units enable row level security;
drop policy if exists "Transfer line units readable" on public.transfer_line_units;
drop policy if exists "Transfer line units viewable by visible transfer" on public.transfer_line_units;
create policy "Transfer line units viewable by visible transfer"
  on public.transfer_line_units for select
  to authenticated using (exists (
    select 1 from public.transfers t
    where t.id = transfer_line_units.transfer_id
      and (public.is_store_visible(t.origin_location_id)
           or public.is_store_visible(t.destination_location_id))));

-- Shared candidate list for one line, in pick order. RESERVED units bound
-- to a DIFFERENT destination are excluded outright — they can never ride
-- to a store their order isn't at.
create or replace function public.transfer_line_unit_candidates(
  p_line_item_id uuid
)
returns table (
  unit_id uuid,
  unit_number bigint,
  status text,
  assigned_requirement_id uuid,
  bound_journey_id uuid,
  is_order_bound boolean
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_line public.transfer_line_items%rowtype;
  v_t public.transfers%rowtype;
begin
  select * into v_line from public.transfer_line_items
  where id = p_line_item_id;
  if not found then return; end if;
  select * into v_t from public.transfers where id = v_line.transfer_id;

  return query
  select u.id, u.unit_number, u.status::text, u.assigned_requirement_id,
         jir.journey_id,
         (u.status = 'RESERVED'
          and jir.location_id = v_t.destination_location_id) as is_order_bound
  from public.units u
  left join public.journey_inventory_requirements jir
    on jir.id = u.assigned_requirement_id
  where u.product_id = v_line.variant_id
    and u.location_id = v_t.origin_location_id
    and u.disposition = 'Prime'
    and u.status in ('STOCK', 'RESERVED')
    and (
      u.status = 'STOCK'
      or (jir.id is not null and jir.location_id = v_t.destination_location_id)
    )
    and not exists (
      select 1 from public.transfer_line_units tlu
      where tlu.unit_id = u.id
        and tlu.received_at is null
        and tlu.missing_at is null
    )
  order by
    (u.status = 'RESERVED'
     and jir.location_id = v_t.destination_location_id) desc,
    u.unit_number;
end;
$$;

revoke execute on function public.transfer_line_unit_candidates(uuid)
  from public, anon, authenticated;

-- preview_transfer_units: read-only. Returns per tracked line the ordered
-- candidate list and the auto-pick (first quantity_requested). Untracked
-- lines are omitted entirely.
create or replace function public.preview_transfer_units(p_transfer_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_t public.transfers%rowtype;
  v_line public.transfer_line_items%rowtype;
  v_lines jsonb := '[]'::jsonb;
  v_cands jsonb;
  v_pick jsonb;
  v_qty integer;
begin
  select * into v_t from public.transfers where id = p_transfer_id;
  if not found then raise exception 'Transfer not found'; end if;
  if not (public.is_store_visible(v_t.origin_location_id)
          or public.is_store_visible(v_t.destination_location_id)) then
    raise exception 'Transfer is not visible to this employee';
  end if;

  for v_line in
    select * from public.transfer_line_items
    where transfer_id = p_transfer_id
  loop
    if not public.is_unit_tracked(v_line.variant_id) then
      continue;
    end if;

    select coalesce(jsonb_agg(jsonb_build_object(
             'unit_id', c.unit_id,
             'unit_number', c.unit_number,
             'status', c.status,
             'is_order_bound', c.is_order_bound,
             'journey_id', c.bound_journey_id
           ) order by c.is_order_bound desc, c.unit_number), '[]'::jsonb)
      into v_cands
    from public.transfer_line_unit_candidates(v_line.id) c;

    select coalesce(jsonb_agg(c.unit_id order by ord), '[]'::jsonb)
      into v_pick
    from (
      select c.unit_id, row_number() over (
               order by c.is_order_bound desc, c.unit_number) as ord
      from public.transfer_line_unit_candidates(v_line.id) c
      limit v_line.quantity_requested
    ) c;

    v_qty := v_line.quantity_requested;

    v_lines := v_lines || jsonb_build_object(
      'line_item_id', v_line.id,
      'variant_id', v_line.variant_id,
      'quantity_requested', v_qty,
      'candidates', v_cands,
      'auto_pick', v_pick,
      'shortfall', greatest(0, v_qty - jsonb_array_length(v_pick))
    );
  end loop;

  return jsonb_build_object(
    'transfer_id', v_t.id,
    'status', v_t.status,
    'lines', v_lines);
end;
$$;

grant execute on function public.preview_transfer_units(uuid) to authenticated;

-- pick_transfer_units: writes the pick. p_picks = null means auto-pick
-- every tracked line; otherwise a jsonb array of
-- {"line_item_id": "...", "unit_ids": ["..."]} for staff overrides.
-- Re-picking while the transfer is still 'pending' replaces the set —
-- idempotent. Requires transfer-approver rights (same as ship/finalize).
create or replace function public.pick_transfer_units(
  p_transfer_id uuid,
  p_picks jsonb,
  p_employee_id uuid
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
  v_pick record;
  v_unit record;
  v_uid uuid;
  v_ids uuid[];
  v_expected integer;
  v_count integer;
  v_result jsonb := '[]'::jsonb;
begin
  v_actor := public.verify_transfer_approver(p_employee_id);

  select * into v_t from public.transfers
  where id = p_transfer_id for update;
  if not found then raise exception 'Transfer not found'; end if;
  if v_t.status <> 'pending' then
    raise exception 'Units can only be picked while the transfer is pending';
  end if;

  -- Re-pick replaces the whole set: delete first so overrides are clean.
  delete from public.transfer_line_units where transfer_id = p_transfer_id;

  for v_line in
    select * from public.transfer_line_items
    where transfer_id = p_transfer_id
  loop
    if not public.is_unit_tracked(v_line.variant_id) then
      continue;
    end if;

    -- Resolve this line's pick: explicit ids from p_picks, else auto.
    v_ids := null;
    if p_picks is not null then
      select array_agg(x::uuid) into v_ids
      from jsonb_array_elements_text(
        coalesce(
          (select p -> 'unit_ids'
             from jsonb_array_elements(p_picks) p
            where (p ->> 'line_item_id')::uuid = v_line.id
            limit 1),
          '[]'::jsonb)) x;
    end if;

    if v_ids is null then
      select array_agg(unit_id order by ord) into v_ids from (
        select c.unit_id, row_number() over (
                 order by c.is_order_bound desc, c.unit_number) as ord
        from public.transfer_line_unit_candidates(v_line.id) c
        limit v_line.quantity_requested
      ) s;
    end if;

    v_count := coalesce(array_length(v_ids, 1), 0);
    if v_count <> v_line.quantity_requested then
      raise exception
        'Line % needs % units picked, got % (only % eligible units at origin)',
        v_line.id, v_line.quantity_requested, v_count,
        (select count(*) from public.transfer_line_unit_candidates(v_line.id));
    end if;

    foreach v_uid in array v_ids loop
      -- Re-validate each explicit pick (auto picks come pre-validated).
      if p_picks is not null then
        select u.id, u.product_id, u.location_id, u.status::text,
               u.unit_number, u.assigned_requirement_id,
               jir.location_id as req_location
          into v_unit
        from public.units u
        left join public.journey_inventory_requirements jir
          on jir.id = u.assigned_requirement_id
        where u.id = v_uid
        for update of u;
        if not found then
          raise exception 'Unit % not found', v_uid;
        end if;
        if v_unit.product_id <> v_line.variant_id then
          raise exception 'Unit % is a different product', v_unit.unit_number;
        end if;
        if v_unit.location_id <> v_t.origin_location_id then
          raise exception 'Unit % is not at the transfer origin', v_unit.unit_number;
        end if;
        if v_unit.status not in ('STOCK', 'RESERVED') then
          raise exception 'Unit % is not available (status %)',
            v_unit.unit_number, v_unit.status;
        end if;
        if v_unit.status = 'RESERVED'
           and (v_unit.req_location is null
                or v_unit.req_location <> v_t.destination_location_id) then
          raise exception
            'Unit % is reserved for an order at a different store',
            v_unit.unit_number;
        end if;
        if exists (
          select 1 from public.transfer_line_units tlu
          where tlu.unit_id = v_uid
            and tlu.received_at is null and tlu.missing_at is null
        ) then
          raise exception 'Unit % is already on another shipment',
            v_unit.unit_number;
        end if;
      end if;

      insert into public.transfer_line_units (
        transfer_id, transfer_line_item_id, unit_id, unit_number,
        picked_status, picked_requirement_id, picked_by
      ) values (
        p_transfer_id, v_line.id, v_uid,
        (select unit_number from public.units where id = v_uid),
        (select status::text from public.units where id = v_uid),
        (select assigned_requirement_id from public.units where id = v_uid),
        v_actor
      );
    end loop;

    v_result := v_result || jsonb_build_object(
      'line_item_id', v_line.id,
      'unit_ids', to_jsonb(v_ids)
    );
  end loop;

  return jsonb_build_object('transfer_id', p_transfer_id, 'lines', v_result);
end;
$$;

grant execute on function public.pick_transfer_units(uuid, jsonb, uuid) to authenticated;
