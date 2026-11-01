-- ============================================================================
-- Unit ID, slice S1: foundations
--
-- A Unit ID is a company-wide sequential number assigned to one physical
-- piece of a tracked product. Tracked per category with a per-product
-- override. This migration creates the model and the internals only: it
-- changes NO existing function and ships inert until a category is flagged.
--
-- Mirror rule (see design Part 2): inventory_positions stays the quantity
-- mirror. Exactly one party applies each mirror effect: pure-unit moves
-- (VOID, MISSING, found, variant reclassification, non-Prime relocation)
-- are mirrored by move_unit itself via unit_transitions.position_delta;
-- quantity changes that already have an existing ledger path (PO receive,
-- transfer ship/receive, delivery, returned receipt) stay owned by the
-- existing wrapper functions and carry position_delta = 0 here.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Tracked flags: category default + per-product override (null = inherit)
-- ----------------------------------------------------------------------------

alter table public.product_categories
  add column if not exists unit_tracked boolean not null default false;

alter table public.products
  add column if not exists unit_tracked boolean;

create or replace function public.is_unit_tracked(p_product_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    p.unit_tracked,
    (select c.unit_tracked
     from public.product_categories c
     where c.id = p.category_id),
    false
  )
  from public.products p
  where p.id = p_product_id;
$$;

revoke execute on function public.is_unit_tracked(uuid) from authenticated, anon;

-- ----------------------------------------------------------------------------
-- 2. Company settings on companies (the established alter pattern)
-- ----------------------------------------------------------------------------

alter table public.companies
  add column if not exists unit_assignment_mode text not null default 'MANUAL'
    check (unit_assignment_mode in ('MANUAL', 'AUTOMATIC')),
  add column if not exists unit_set_mode text not null default 'WAIT'
    check (unit_set_mode in ('WAIT', 'ASSIGN_AVAILABLE')),
  add column if not exists unit_counter_start bigint not null default 1
    check (unit_counter_start >= 1);

-- ----------------------------------------------------------------------------
-- 3. Counter: one row per company, allocated under the row lock
-- ----------------------------------------------------------------------------

create table if not exists public.unit_counters (
  company_id uuid primary key references public.companies (id) on delete cascade,
  next_value bigint not null check (next_value >= 1)
);

alter table public.unit_counters enable row level security;
-- No policies: not readable or writable by clients at all.

-- Internal allocator. Creates the counter row at the configured start if it
-- is missing, then UPDATE ... RETURNING under the row lock, so concurrent
-- receivers can never draw the same number and numbers are never reused.
create or replace function public.allocate_unit_number(p_company_id uuid)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_next bigint;
begin
  insert into public.unit_counters (company_id, next_value)
  select c.id, c.unit_counter_start
  from public.companies c
  where c.id = p_company_id
  on conflict (company_id) do nothing;

  update public.unit_counters
  set next_value = next_value + 1
  where company_id = p_company_id
  returning next_value - 1 into v_next;

  if v_next is null then
    raise exception 'That company was not found.';
  end if;

  return v_next;
end;
$$;

revoke execute on function public.allocate_unit_number(uuid)
  from authenticated, anon, public;

-- ----------------------------------------------------------------------------
-- 4. units + unit_events
-- ----------------------------------------------------------------------------

create table if not exists public.units (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete restrict,
  product_id uuid not null references public.products (id) on delete restrict,
  unit_number bigint not null,
  status text not null default 'STOCK' check (status in (
    'STOCK', 'RESERVED', 'IN_TRANSIT', 'STAGED', 'DELIVERED',
    'RETURNED', 'QUARANTINE', 'DAMAGED', 'MISSING', 'VOID')),
  location_id uuid references public.stores (id) on delete restrict,
  disposition public.disposition not null default 'Prime',
  purchase_order_line_item_id uuid
    references public.purchase_order_line_items (id) on delete set null,
  assigned_requirement_id uuid
    references public.journey_inventory_requirements (id) on delete set null,
  delivered_journey_id uuid
    references public.sleep_journeys (id) on delete set null,
  voided_at timestamptz,
  voided_by uuid references public.employees (id) on delete set null,
  void_reason text,
  created_at timestamptz not null default now(),
  created_by uuid references public.employees (id) on delete set null,
  unique (company_id, unit_number)
);

-- One unit can fill at most one requirement at a time.
create unique index if not exists idx_units_one_assignment
  on public.units (assigned_requirement_id)
  where assigned_requirement_id is not null;

create index if not exists idx_units_product_location
  on public.units (product_id, location_id, disposition, status);
create index if not exists idx_units_company_number
  on public.units (company_id, unit_number);

comment on table public.units is
  'Unit ID registry: one row per physical piece of a tracked product. '
  'VOID rows are kept forever; unit_number is never reused.';

create table if not exists public.unit_events (
  id uuid primary key default gen_random_uuid(),
  unit_id uuid not null references public.units (id) on delete restrict,
  company_id uuid not null references public.companies (id) on delete restrict,
  event_type text not null,
  actor_id uuid references public.employees (id) on delete set null,
  journey_id uuid references public.sleep_journeys (id) on delete set null,
  transfer_id uuid references public.transfers (id) on delete set null,
  from_status text,
  to_status text,
  from_location_id uuid references public.stores (id) on delete set null,
  to_location_id uuid references public.stores (id) on delete set null,
  data jsonb,
  created_at timestamptz not null default now()
);

create index if not exists idx_unit_events_unit
  on public.unit_events (unit_id, created_at);
create index if not exists idx_unit_events_journey
  on public.unit_events (journey_id) where journey_id is not null;

comment on table public.unit_events is
  'Append-only lifecycle history per unit. No update or delete for anyone.';

-- Append-only enforcement: block update and delete for every caller,
-- including superuser paths through this table's own RLS-exempt roles.
create or replace function public.unit_events_no_mutation()
returns trigger
language plpgsql
as $$
begin
  raise exception 'unit_events is append-only.';
end;
$$;

drop trigger if exists trg_unit_events_no_update on public.unit_events;
create trigger trg_unit_events_no_update
before update on public.unit_events
for each row execute function public.unit_events_no_mutation();

drop trigger if exists trg_unit_events_no_delete on public.unit_events;
create trigger trg_unit_events_no_delete
before delete on public.unit_events
for each row execute function public.unit_events_no_mutation();

revoke update, delete on public.unit_events from public;

-- ----------------------------------------------------------------------------
-- 5. Allowed transitions and their mirror delta
--    position_delta is applied by move_unit itself at the unit's current
--    location and disposition (on_hand_quantity). 0 means either no quantity
--    effect or the mirror is owned by an existing wrapper function.
-- ----------------------------------------------------------------------------

create table if not exists public.unit_transitions (
  from_status text not null,
  to_status text not null,
  position_delta integer not null default 0,
  ledger_reason text,
  mirror_owner text not null default 'move_unit'
    check (mirror_owner in ('move_unit', 'wrapper', 'none')),
  two_leg boolean not null default false,
  primary key (from_status, to_status)
);

insert into public.unit_transitions
  (from_status, to_status, position_delta, ledger_reason, mirror_owner, two_leg)
values
  -- creation is handled by create_unit, not this table.
  -- mirror_owner=wrapper: the existing function (PO receive, transfer
  -- ship/receive, delivery, returned receipt) already writes the position
  -- and ledger, so move_unit must not also write them.
  ('STOCK',        'RESERVED',    0, null,                'wrapper',   false),
  ('RESERVED',     'STOCK',       0, null,                'wrapper',   false),
  ('RESERVED',     'IN_TRANSIT',  0, 'transfer_ship',     'wrapper',   false),
  ('STOCK',        'IN_TRANSIT',  0, 'transfer_ship',     'wrapper',   false),
  ('IN_TRANSIT',   'STOCK',       0, 'transfer_receive',  'wrapper',   false),
  ('IN_TRANSIT',   'RESERVED',    0, 'transfer_receive',  'wrapper',   false),
  ('RESERVED',     'STAGED',      0, null,                'none',      false),
  ('STAGED',       'RESERVED',    0, null,                'none',      false),
  ('STAGED',       'DELIVERED',   0, 'sale_delivery',     'wrapper',   false),
  ('RESERVED',     'DELIVERED',   0, 'sale_delivery',     'wrapper',   false),
  ('DELIVERED',    'RETURNED',    0, 'return_received',   'wrapper',   false),
  ('RETURNED',     'QUARANTINE',  0, null,                'none',      false),
  -- two-leg relocations: minus 1 at the old bucket, plus 1 at the new,
  -- two ledger rows with a shared correlation id. Disposition is preserved
  -- on the plus leg unless the caller converts it explicitly in context.
  ('QUARANTINE',   'STOCK',       0, 'unit_relocated',    'move_unit', true),
  ('QUARANTINE',   'DAMAGED',     0, 'unit_relocated',    'move_unit', true),
  ('DAMAGED',      'STOCK',       0, 'unit_relocated',    'move_unit', true),
  ('STOCK',        'STOCK',       0, 'unit_reclassified', 'move_unit', true),
  ('STOCK',        'MISSING',    -1, 'unit_missing',      'move_unit', false),
  ('MISSING',      'STOCK',       1, 'unit_found',        'move_unit', false),
  ('STOCK',        'VOID',       -1, 'unit_voided',       'move_unit', false),
  ('QUARANTINE',   'VOID',        0, 'unit_voided',       'wrapper',   false)
on conflict (from_status, to_status) do nothing;

comment on table public.unit_transitions is
  'Allowed unit status transitions. position_delta is applied by move_unit '
  'at the unit location; mirror_owner=wrapper rows mean the existing '
  'function (receive_purchase_order_line, transfer ship/receive, delivery, '
  'returned receipt) already writes the position and ledger, so move_unit '
  'must not also write them.';

-- ----------------------------------------------------------------------------
-- 6. Internal create_unit and move_unit
-- ----------------------------------------------------------------------------

create or replace function public.create_unit(
  p_company_id uuid,
  p_product_id uuid,
  p_location_id uuid,
  p_disposition public.disposition default 'Prime',
  p_purchase_order_line_item_id uuid default null,
  p_created_by uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_number bigint;
  v_id uuid;
begin
  if not public.is_unit_tracked(p_product_id) then
    raise exception 'This product is not tracked per unit.';
  end if;

  v_number := public.allocate_unit_number(p_company_id);

  insert into public.units (
    company_id, product_id, unit_number, status, location_id,
    disposition, purchase_order_line_item_id, created_by
  ) values (
    p_company_id, p_product_id, v_number, 'STOCK', p_location_id,
    p_disposition, p_purchase_order_line_item_id, p_created_by
  ) returning id into v_id;

  insert into public.unit_events (
    unit_id, company_id, event_type, actor_id,
    to_status, to_location_id, data
  ) values (
    v_id, p_company_id, 'UNIT_CREATED', p_created_by,
    'STOCK', p_location_id,
    jsonb_build_object(
      'unit_number', v_number,
      'product_id', p_product_id,
      'purchase_order_line_item_id', p_purchase_order_line_item_id)
  );

  return v_id;
end;
$$;

revoke execute on function public.create_unit(uuid, uuid, uuid,
  public.disposition, uuid, uuid) from authenticated, anon, public;

create or replace function public.move_unit(
  p_unit_id uuid,
  p_to_status text,
  p_to_location_id uuid default null,
  p_context jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_unit public.units%rowtype;
  v_rule public.unit_transitions%rowtype;
  v_employee uuid;
  v_delta int;
  v_new_product uuid;
  v_new_disposition public.disposition;
begin
  select * into v_unit from public.units where id = p_unit_id for update;
  if not found then
    raise exception 'That unit was not found.';
  end if;

  select * into v_rule
  from public.unit_transitions
  where from_status = v_unit.status and to_status = p_to_status;
  if not found then
    raise exception 'A unit cannot move from % to %.', v_unit.status, p_to_status;
  end if;

  -- A RESERVED unit always knows which requirement it fills: new
  -- reservations must pass requirement_id; preserved assignments
  -- (STAGED -> RESERVED, IN_TRANSIT -> RESERVED) already carry it.
  if p_to_status = 'RESERVED'
     and coalesce((p_context ->> 'requirement_id')::uuid,
                  v_unit.assigned_requirement_id) is null then
    raise exception 'Reserving a unit requires the requirement it will fill.';
  end if;

  select e.id into v_employee
  from public.employees e
  where e.auth_user_id = auth.uid() and e.is_active;

  -- Context product/disposition changes are honored only on two-leg
  -- (relocation or condition-change) transitions. On any other transition a
  -- key that differs from the current value is refused; an equal value is
  -- ignored.
  if not v_rule.two_leg then
    if (p_context ? 'new_product_id'
          and (p_context ->> 'new_product_id')::uuid is distinct from v_unit.product_id)
       or (p_context ? 'new_disposition'
          and (p_context ->> 'new_disposition')::public.disposition
              is distinct from v_unit.disposition) then
      raise exception 'Product or disposition can only change in a relocation or condition change.';
    end if;
  end if;

  v_delta := v_rule.position_delta;
  v_new_product := case when v_rule.two_leg
    then coalesce((p_context ->> 'new_product_id')::uuid, v_unit.product_id)
    else v_unit.product_id end;
  v_new_disposition := case when v_rule.two_leg
    then coalesce(p_context ->> 'new_disposition',
                  v_unit.disposition::text)::public.disposition
    else v_unit.disposition end;

  -- Same-bucket two-leg with nothing changing is pointless; refuse it.
  if v_rule.two_leg
     and v_new_product = v_unit.product_id
     and v_new_disposition = v_unit.disposition
     and coalesce(p_to_location_id, v_unit.location_id) = v_unit.location_id then
    raise exception 'Nothing changed: give a new product, disposition or location to move this unit.';
  end if;

  -- A reclassified product must exist, belong to this company and be tracked.
  if v_new_product <> v_unit.product_id then
    if not exists (
      select 1 from public.products pr
      where pr.id = v_new_product and pr.company_id = v_unit.company_id
    ) then
      raise exception 'That product does not exist in this company.';
    end if;
    if not public.is_unit_tracked(v_new_product) then
      raise exception 'That product is not tracked per unit.';
    end if;
  end if;

  -- Returned or Damaged stock may never silently regain Prime: only a
  -- finished inspection may authorize it, recorded in the event data.
  -- Checked against the RESULTING disposition on every transition.
  if v_unit.disposition in ('Returned', 'Damaged')
     and v_new_disposition = 'Prime'
     and coalesce(p_context ->> 'authorized_by', '') <> 'inspection_finish' then
    raise exception 'Only a finished inspection can return a unit to Prime stock.';
  end if;

  -- Two-leg relocation: minus 1 at the old (product, location,
  -- disposition), plus 1 at the new, two ledger rows sharing the unit id
  -- as correlation. The minus leg may never take on_hand below zero.
  if v_rule.mirror_owner = 'move_unit' and v_rule.two_leg then
    update public.inventory_positions
    set on_hand_quantity = on_hand_quantity - 1, updated_at = now()
    where variant_id = v_unit.product_id
      and location_id = v_unit.location_id
      and sublocation_id is null
      and disposition = v_unit.disposition
      and on_hand_quantity >= 1;
    if not found then
      raise exception 'The inventory mirror does not have this unit to move. Run the consistency check and reconcile first.';
    end if;
    insert into public.inventory_positions (
      variant_id, location_id, sublocation_id, disposition,
      on_hand_quantity, committed_quantity
    ) values (
      v_new_product, coalesce(p_to_location_id, v_unit.location_id),
      null, v_new_disposition, 1, 0
    )
    on conflict (variant_id, location_id, sublocation_id, disposition)
    do update set
      on_hand_quantity = inventory_positions.on_hand_quantity + 1,
      updated_at = now();
    if v_rule.ledger_reason is not null then
      insert into public.stock_ledger_entries (
        variant_id, location_id, disposition, quantity_delta,
        reason, reference_type, actor_id, correlation_id
      ) values
        (v_unit.product_id, v_unit.location_id, v_unit.disposition, -1,
         v_rule.ledger_reason, 'unit', v_employee::text, v_unit.id),
        (v_new_product, coalesce(p_to_location_id, v_unit.location_id),
         v_new_disposition, 1,
         v_rule.ledger_reason, 'unit', v_employee::text, v_unit.id);
    end if;

  -- Single-leg mirror effect applied here only when this transition owns it.
  -- on_hand may never go below zero: that is the legitimate block.
  elsif v_rule.mirror_owner = 'move_unit' and v_delta <> 0 then
    if v_delta < 0 then
      update public.inventory_positions
      set on_hand_quantity = on_hand_quantity + v_delta, updated_at = now()
      where variant_id = v_unit.product_id
        and location_id = v_unit.location_id
        and sublocation_id is null
        and disposition = v_unit.disposition
        and on_hand_quantity + v_delta >= 0;
      if not found then
        raise exception 'The inventory mirror does not have this unit to remove. Run the consistency check and reconcile first.';
      end if;
    else
      insert into public.inventory_positions (
        variant_id, location_id, sublocation_id, disposition,
        on_hand_quantity, committed_quantity
      ) values (
        v_new_product, coalesce(p_to_location_id, v_unit.location_id),
        null, v_new_disposition, v_delta, 0
      )
      on conflict (variant_id, location_id, sublocation_id, disposition)
      do update set
        on_hand_quantity = inventory_positions.on_hand_quantity + v_delta,
        updated_at = now();
    end if;

    if v_rule.ledger_reason is not null then
      insert into public.stock_ledger_entries (
        variant_id, location_id, disposition, quantity_delta,
        reason, reference_type, actor_id, correlation_id
      ) values (
        v_new_product,
        coalesce(p_to_location_id, v_unit.location_id),
        v_new_disposition, v_delta,
        v_rule.ledger_reason, 'unit', v_employee::text, v_unit.id
      );
    end if;
  end if;

  -- Variant reclassification: STOCK -> STOCK with a different product or
  -- disposition relocates the unit's identity, not just its status.
  update public.units
  set status = p_to_status,
      location_id = coalesce(p_to_location_id, v_unit.location_id),
      product_id = v_new_product,
      disposition = v_new_disposition,
      assigned_requirement_id = case
        -- An assigned unit keeps its assignment through a transfer and
        -- staging. RESERVED -> STOCK is the unassign path and clears it.
        when p_to_status = 'RESERVED'
          then coalesce((p_context ->> 'requirement_id')::uuid,
                        v_unit.assigned_requirement_id)
        when v_unit.status = 'RESERVED' and p_to_status = 'STOCK'
          then null
        when p_to_status in ('DELIVERED', 'RETURNED', 'VOID', 'MISSING')
          then null
        else v_unit.assigned_requirement_id
      end,
      delivered_journey_id = case
        when p_to_status = 'DELIVERED'
          then coalesce((p_context ->> 'journey_id')::uuid,
                        v_unit.delivered_journey_id)
        else delivered_journey_id
      end,
      voided_at = case when p_to_status = 'VOID' then now() else voided_at end,
      voided_by = case when p_to_status = 'VOID' then v_employee else voided_by end,
      void_reason = case when p_to_status = 'VOID'
        then p_context ->> 'reason' else void_reason end
  where id = p_unit_id;

  insert into public.unit_events (
    unit_id, company_id, event_type, actor_id, journey_id, transfer_id,
    from_status, to_status, from_location_id, to_location_id, data
  ) values (
    p_unit_id, v_unit.company_id,
    coalesce(p_context ->> 'event_type', 'UNIT_MOVED'),
    v_employee,
    (p_context ->> 'journey_id')::uuid,
    (p_context ->> 'transfer_id')::uuid,
    v_unit.status, p_to_status,
    v_unit.location_id, coalesce(p_to_location_id, v_unit.location_id),
    p_context
  );

  return v_unit.id;
end;
$$;

revoke execute on function public.move_unit(uuid, text, uuid, jsonb)
  from authenticated, anon, public;

-- ----------------------------------------------------------------------------
-- 7. check_unit_consistency: read-only drift report, tracked products only.
--    Compares units that represent physical stock
--    (STOCK, RESERVED, STAGED, QUARANTINE, DAMAGED, RETURNED) against
--    inventory_positions.on_hand_quantity, and RESERVED units against
--    committed_quantity. Reports mismatches; never fixes anything.
-- ----------------------------------------------------------------------------

create or replace function public.check_unit_consistency(p_company_id uuid)
returns table (
  product_id uuid,
  location_id uuid,
  disposition public.disposition,
  units_on_hand bigint,
  mirror_on_hand integer,
  units_reserved bigint,
  mirror_committed integer
)
language sql
stable
security definer
set search_path = public
as $$
  with tracked_products as (
    select p.id
    from public.products p
    where public.is_unit_tracked(p.id)
  ),
  unit_counts as (
    select u.product_id, u.location_id, u.disposition,
      count(*) filter (where u.status in
        ('STOCK','RESERVED','STAGED','QUARANTINE','DAMAGED','RETURNED'))
        as on_hand_units,
      count(*) filter (where u.status = 'RESERVED') as reserved_units
    from public.units u
    where u.company_id = p_company_id
      and u.status <> 'VOID'
      and u.product_id in (select id from tracked_products)
    group by u.product_id, u.location_id, u.disposition
  ),
  mirror_counts as (
    select ip.variant_id as product_id, ip.location_id, ip.disposition,
      ip.on_hand_quantity, ip.committed_quantity
    from public.inventory_positions ip
    where ip.variant_id in (select id from tracked_products)
  )
  select
    coalesce(u.product_id, m.product_id) as product_id,
    coalesce(u.location_id, m.location_id) as location_id,
    coalesce(u.disposition, m.disposition) as disposition,
    coalesce(u.on_hand_units, 0) as units_on_hand,
    coalesce(m.on_hand_quantity, 0) as mirror_on_hand,
    coalesce(u.reserved_units, 0) as units_reserved,
    coalesce(m.committed_quantity, 0) as mirror_committed
  from unit_counts u
  full outer join mirror_counts m
    on m.product_id = u.product_id
    and m.location_id = u.location_id
    and m.disposition = u.disposition
  where coalesce(u.on_hand_units, 0) <> coalesce(m.on_hand_quantity, 0)
     or coalesce(u.reserved_units, 0) <> coalesce(m.committed_quantity, 0);
$$;

revoke execute on function public.check_unit_consistency(uuid)
  from authenticated, anon, public;

-- Stage 2 discrepancy view calls this: a thin permission-checked wrapper.
create or replace function public.get_unit_discrepancies(p_company_id uuid)
returns table (
  product_id uuid,
  location_id uuid,
  disposition public.disposition,
  units_on_hand bigint,
  mirror_on_hand integer,
  units_reserved bigint,
  mirror_committed integer
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_company uuid;
begin
  if not public.has_permission('units.manage_settings') then
    raise exception 'You do not have permission to view unit discrepancies.';
  end if;

  -- The company comes from the caller's employee record, never from the
  -- argument alone: an admin of one company cannot read another's.
  select s.company_id into v_company
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid()
    and e.is_active;
  if v_company is null then
    raise exception 'Your employee record was not found or is inactive.';
  end if;
  if p_company_id is distinct from v_company then
    raise exception 'That company is not yours.';
  end if;

  return query
    select * from public.check_unit_consistency(v_company);
end;
$$;

grant execute on function public.get_unit_discrepancies(uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- 8. RLS: read scoped to the caller's company the same way products are
--    (is_product_visible_by_company, 005:56, checks the caller can see a
--    store of that company). No write policies anywhere: every write goes
--    through security-definer functions.
-- ----------------------------------------------------------------------------

alter table public.units enable row level security;
drop policy if exists "Units readable" on public.units;
create policy "Units readable"
  on public.units for select
  to authenticated
  using (public.is_own_company(company_id));

alter table public.unit_events enable row level security;
drop policy if exists "Unit events readable" on public.unit_events;
create policy "Unit events readable"
  on public.unit_events for select
  to authenticated
  using (public.is_own_company(company_id));

alter table public.unit_transitions enable row level security;
drop policy if exists "Unit transitions readable" on public.unit_transitions;
create policy "Unit transitions readable"
  on public.unit_transitions for select
  to authenticated
  using (true);

-- ----------------------------------------------------------------------------
-- 9. Permission keys: same VALUES-driven seed pattern as 066.
--    Proposed defaults, flagged for review:
--      units.assign, units.unassign: all roles (sold on the floor)
--      units.override_set, units.swap: owner, admin, manager
--      units.void, units.manage_settings: owner, admin
-- ----------------------------------------------------------------------------

create or replace function public.seed_unit_permission_defaults(p_company_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.role_permission_grants (company_id, role, permission_key)
  select p_company_id, g.role, g.permission_key
  from (
    values
      ('owner',    'units.assign'),
      ('admin',    'units.assign'),
      ('manager',  'units.assign'),
      ('sales',    'units.assign'),
      ('employee', 'units.assign'),
      ('owner',    'units.unassign'),
      ('admin',    'units.unassign'),
      ('manager',  'units.unassign'),
      ('sales',    'units.unassign'),
      ('employee', 'units.unassign'),
      ('owner',    'units.override_set'),
      ('admin',    'units.override_set'),
      ('manager',  'units.override_set'),
      ('owner',    'units.swap'),
      ('admin',    'units.swap'),
      ('manager',  'units.swap'),
      ('owner',    'units.void'),
      ('admin',    'units.void'),
      ('owner',    'units.manage_settings'),
      ('admin',    'units.manage_settings')
  ) as g (role, permission_key)
  on conflict do nothing;
end;
$$;

-- Seed existing companies once at migration time.
do $$
declare
  v_company uuid;
begin
  for v_company in select id from public.companies loop
    perform public.seed_unit_permission_defaults(v_company);
  end loop;
end $$;

-- Seed future companies on insert (companion to the 066 seed trigger).
create or replace function public.trg_seed_unit_permissions()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.seed_unit_permission_defaults(new.id);
  return new;
end;
$$;

revoke execute on function public.seed_unit_permission_defaults(uuid)
  from authenticated, anon, public;
revoke execute on function public.trg_seed_unit_permissions()
  from authenticated, anon, public;

drop trigger if exists trg_companies_seed_unit_permissions on public.companies;
create trigger trg_companies_seed_unit_permissions
after insert on public.companies
for each row execute function public.trg_seed_unit_permissions();

-- ----------------------------------------------------------------------------
-- 10. set_role_permission: extend the allowed-key list with the units.* keys.
--     Latest prior definition: 091_exchange_ui_support.sql:107. This is the
--     one existing function this migration changes; every existing key is
--     preserved verbatim.
-- ----------------------------------------------------------------------------

create or replace function public.set_role_permission(
  p_role text,
  p_key text,
  p_granted boolean
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor_id uuid;
  v_caller_role text;
  v_company_id uuid;
  v_grant_id uuid;
begin
  select e.id, e.role::text, s.company_id
    into v_actor_id, v_caller_role, v_company_id
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid()
    and e.is_active;

  if v_actor_id is null then
    raise exception 'Not authenticated as an employee';
  end if;

  if v_caller_role not in ('owner', 'admin') then
    raise exception 'Only owners and admins can change permissions';
  end if;

  if not exists (
    select 1
    from unnest(enum_range(null::public.employee_role)) as v
    where v::text = p_role
  ) then
    raise exception 'Unknown role: %', p_role;
  end if;

  if p_key not in (
    'sleep_trial.manage_concerns',
    'sleep_trial.start_exchange',
    'sleep_trial.start_return',
    'sleep_trial.request_exceptions',
    'sleep_trial.approve_exceptions',
    'sleep_trial.approve_own_exceptions',
    'sleep_trial.override_protector',
    'sleep_trial.correct_dates',
    'sleep_trial.manage_policy',
    'sleep_trial.view_policy_details',
    'inventory.reduce_below_committed',
    'sleep_trial.complete_exchange',
    'inventory.inspect_returns',
    'inventory.manage_inspection_checklist',
    'sleep_trial.void_refund',
    'units.assign',
    'units.unassign',
    'units.override_set',
    'units.swap',
    'units.void',
    'units.manage_settings'
  ) then
    raise exception 'Unknown permission key: %', p_key;
  end if;

  if p_role = 'owner' and not p_granted then
    raise exception 'Owner permissions cannot be removed';
  end if;

  select id into v_grant_id
  from public.role_permission_grants
  where company_id = v_company_id
    and role = p_role
    and permission_key = p_key;

  if p_granted and v_grant_id is null then
    insert into public.role_permission_grants (company_id, role, permission_key, created_by)
    values (v_company_id, p_role, p_key, v_actor_id)
    returning id into v_grant_id;

    perform public.log_audit_event(
      p_company_id   := v_company_id,
      p_entity_type  := 'role_permission_grant',
      p_entity_id    := v_grant_id,
      p_event_type   := 'SLEEP_TRIAL_PERMISSION_GRANTED',
      p_after        := jsonb_build_object('role', p_role, 'permission_key', p_key, 'granted', true),
      p_actor_employee_id := v_actor_id
    );
  elsif not p_granted and v_grant_id is not null then
    delete from public.role_permission_grants where id = v_grant_id;

    perform public.log_audit_event(
      p_company_id   := v_company_id,
      p_entity_type  := 'role_permission_grant',
      p_entity_id    := v_grant_id,
      p_event_type   := 'SLEEP_TRIAL_PERMISSION_REVOKED',
      p_before       := jsonb_build_object('role', p_role, 'permission_key', p_key, 'granted', true),
      p_after        := jsonb_build_object('role', p_role, 'permission_key', p_key, 'granted', false),
      p_actor_employee_id := v_actor_id
    );
  end if;
  -- Granting an existing grant or revoking a missing one is a no-op; nothing
  -- changed, so nothing is audited.
end;
$$;

grant execute on function public.set_role_permission(text, text, boolean) to authenticated;
