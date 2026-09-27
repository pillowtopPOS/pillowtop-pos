-- PillowTop POS Phase 8 foundation: fulfillment type and warehouse-aware sourcing

-- 1. Fulfillment and warehouse fields

do $$
begin
  if not exists (select 1 from pg_type where typname = 'fulfillment_type') then
    create type public.fulfillment_type as enum ('delivery', 'pickup');
  end if;
end $$;

alter table public.sleep_journeys
  add column if not exists fulfillment_type public.fulfillment_type
  not null default 'delivery';

alter table public.stores
  add column if not exists assigned_warehouse_id uuid
  references public.stores(id) on delete set null;

-- A store may point only to a warehouse in the same company. The trigger is
-- intentional because the referenced row's location_type is not expressible
-- as a normal foreign-key constraint.
create or replace function public.validate_assigned_warehouse()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_warehouse public.stores%rowtype;
begin
  if new.assigned_warehouse_id is null then
    return new;
  end if;

  if new.location_type <> 'STORE' then
    raise exception 'Only STORE locations may have an assigned warehouse';
  end if;

  select * into v_warehouse
  from public.stores
  where id = new.assigned_warehouse_id;

  if not found or v_warehouse.location_type <> 'WAREHOUSE' then
    raise exception 'Assigned warehouse must be a WAREHOUSE location';
  end if;

  if v_warehouse.company_id is distinct from new.company_id then
    raise exception 'Assigned warehouse must belong to the same company';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_validate_assigned_warehouse on public.stores;
create trigger trg_validate_assigned_warehouse
before insert or update of assigned_warehouse_id, company_id, location_type
on public.stores
for each row execute function public.validate_assigned_warehouse();

-- 2. Preserve requirement history across sourcing changes.
--    The old full unique constraint is replaced by an active-only partial index.
alter table public.journey_inventory_requirements
  drop constraint if exists journey_inventory_requirements_journey_id_variant_id_key;

alter table public.journey_inventory_requirements
  drop constraint if exists journey_inventory_requirements_status_check;
alter table public.journey_inventory_requirements
  add constraint journey_inventory_requirements_status_check
  check (status in ('pending', 'ready', 'cancelled', 'superseded'));

drop index if exists public.idx_journey_inventory_requirements_active;
create unique index idx_journey_inventory_requirements_active
  on public.journey_inventory_requirements (journey_id, variant_id, location_id)
  where status in ('pending', 'ready');

-- 3. Resolve the inventory source for a Journey.
create or replace function public.resolve_journey_inventory_location(p_journey_id uuid)
returns uuid
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_source uuid;
begin
  select case
    when sj.fulfillment_type = 'pickup'
      then sj.store_id
    else coalesce(s.assigned_warehouse_id, sj.store_id)
  end
  into v_source
  from public.sleep_journeys sj
  join public.stores s on s.id = sj.store_id
  where sj.id = p_journey_id;
  return v_source;
end;
$$;
revoke execute on function public.resolve_journey_inventory_location(uuid) from authenticated, anon;

-- 4. Re-evaluate reservations against the resolved source location.
create or replace function public.evaluate_journey_inventory(p_journey_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare
  v_journey public.sleep_journeys%rowtype;
  v_company uuid;
  v_trigger text;
  v_paid numeric;
  v_should_run boolean := false;
  v_any_short boolean := false;
  v_req record;
  v_available integer;
  v_needed integer;
  v_old_state public.journey_state;
  v_new_state public.journey_state;
  v_event_type public.journey_event_type;
begin
  select * into v_journey from public.sleep_journeys where id = p_journey_id for update;
  if not found or v_journey.cancelled_at is not null then return; end if;

  select company_id into v_company
  from public.stores
  where id = v_journey.store_id;
  if v_company is null then return; end if;

  select trigger_type into v_trigger
  from public.reservation_policies
  where company_id = v_company;
  v_trigger := coalesce(v_trigger, 'paid_in_full');

  if v_trigger = 'order_creation' then
    v_should_run := exists (select 1 from public.journey_line_items where journey_id = p_journey_id and product_id is not null);
  elsif v_trigger = 'deposit_received' then
    v_should_run := exists (select 1 from public.journey_events where journey_id = p_journey_id and event_type = 'deposit_received' and outcome = 'SUCCEEDED');
  elsif v_trigger = 'order_confirmed' then
    v_should_run := exists (select 1 from public.journey_events where journey_id = p_journey_id and event_type::text = 'order_confirmed');
  else
    v_paid := public.total_paid(p_journey_id);
    v_should_run := v_journey.price is not null and v_paid >= v_journey.price;
  end if;
  if not v_should_run then return; end if;

  -- Requirements are grouped by (variant, effective location), so one
  -- Journey may reserve different line items at different locations. Create
  -- missing groups independently: an existing active requirement for item A
  -- must not prevent a newly-added item B from receiving its requirement.
  insert into public.journey_inventory_requirements (
    journey_id, variant_id, location_id, quantity_required
  )
  select
    p_journey_id,
    effective.variant_id,
    effective.location_id,
    sum(effective.quantity)
  from (
    select
      jli.product_id as variant_id,
      jli.quantity,
      case
        when coalesce(jli.fulfillment_type_override, v_journey.fulfillment_type) = 'pickup'
          then coalesce(jli.pickup_location_id, v_journey.store_id)
        else coalesce(
          (select assigned_warehouse_id from public.stores where id = v_journey.store_id),
          v_journey.store_id
        )
      end as location_id
    from public.journey_line_items jli
    where jli.journey_id = p_journey_id and jli.product_id is not null
  ) effective
  where not exists (
    select 1
    from public.journey_inventory_requirements existing
    where existing.journey_id = p_journey_id
      and existing.variant_id = effective.variant_id
      and existing.location_id = effective.location_id
      and existing.status in ('pending', 'ready')
  )
  group by effective.variant_id, effective.location_id
  on conflict (journey_id, variant_id, location_id)
    where status in ('pending', 'ready')
    do nothing;

  perform pg_advisory_xact_lock(hashtextextended(p_journey_id::text, 7137));
  for v_req in
    select * from public.journey_inventory_requirements
    where journey_id = p_journey_id and status = 'pending'
    order by variant_id
  loop
    perform pg_advisory_xact_lock(hashtextextended(v_req.variant_id::text || ':' || v_req.location_id::text || ':Prime', 7137));
    v_needed := v_req.quantity_required - v_req.quantity_reserved;
    if v_needed <= 0 then
      update public.journey_inventory_requirements set status = 'ready' where id = v_req.id;
      continue;
    end if;

    select coalesce(on_hand_quantity - committed_quantity, 0) into v_available
    from public.inventory_positions
    where variant_id = v_req.variant_id and location_id = v_req.location_id
      and disposition = 'Prime' and sublocation_id is null
    for update;

    if coalesce(v_available, 0) >= v_needed then
      update public.inventory_positions
      set committed_quantity = committed_quantity + v_needed, updated_at = now()
      where variant_id = v_req.variant_id and location_id = v_req.location_id
        and disposition = 'Prime' and sublocation_id is null;
      update public.journey_inventory_requirements
      set quantity_reserved = quantity_reserved + v_needed, status = 'ready'
      where id = v_req.id;
    else
      v_any_short := true;
    end if;
  end loop;

  select exists (select 1 from public.journey_inventory_requirements where journey_id = p_journey_id and status = 'pending') into v_any_short;
  v_old_state := v_journey.current_state;
  v_new_state := case when v_any_short then 'Waiting for Inventory' else 'Ready to Schedule' end;

  update public.sleep_journeys
  set current_state = v_new_state,
      inventory_ready_notified_at = case when not v_any_short and inventory_ready_notified_at is null then now() else inventory_ready_notified_at end,
      updated_at = now()
  where id = p_journey_id;

  if v_old_state is distinct from v_new_state then
    v_event_type := case when v_any_short then 'inventory_required' else 'inventory_received' end;
    insert into public.journey_events (journey_id, event_type, event_data, triggered_by)
    values (p_journey_id, v_event_type, jsonb_build_object('automated', true, 'requirements_ready', not v_any_short), 'system');
  end if;
end;
$$;
revoke execute on function public.evaluate_journey_inventory(uuid) from authenticated, anon;

-- 5. Fulfillment changes release old reservations, preserve the old row's
--    quantity_reserved, and evaluate a fresh requirement at the new location.
--    This deliberately rebuilds every active requirement, including items
--    whose effective location did not change. Release-then-re-reserve nets
--    out safely in this transaction; the tradeoff is minor audit-history
--    churn in exchange for simpler code.
create or replace function public.handle_journey_fulfillment_change()
returns trigger language plpgsql security definer set search_path = public
as $$
declare r record;
begin
  perform pg_advisory_xact_lock(hashtextextended(new.id::text, 7137));
  for r in select * from public.journey_inventory_requirements where journey_id = new.id and status in ('pending', 'ready') order by variant_id for update loop
    if r.quantity_reserved > 0 then
      perform pg_advisory_xact_lock(hashtextextended(r.variant_id::text || ':' || r.location_id::text || ':Prime', 7137));
      update public.inventory_positions
      set committed_quantity = committed_quantity - r.quantity_reserved, updated_at = now()
      where variant_id = r.variant_id and location_id = r.location_id
        and disposition = 'Prime' and sublocation_id is null;
    end if;
    -- Preserve quantity_reserved as an honest historical record; it is not zeroed.
    update public.journey_inventory_requirements set status = 'superseded' where id = r.id;
  end loop;

  perform public.evaluate_journey_inventory(new.id);
  return new;
end;
$$;
revoke execute on function public.handle_journey_fulfillment_change() from authenticated, anon;

drop trigger if exists trg_journey_fulfillment_change on public.sleep_journeys;
create trigger trg_journey_fulfillment_change
after update of fulfillment_type on public.sleep_journeys
for each row when (old.fulfillment_type is distinct from new.fulfillment_type)
execute function public.handle_journey_fulfillment_change();

-- Existing journey-event and line-item hooks call the replacement evaluator.
