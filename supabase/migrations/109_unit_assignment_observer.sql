-- ============================================================================
-- Unit ID S3a: automatic unit assignment behind the reservation observer
--
-- When stock is reserved for a customer's order, matching physical units
-- are assigned to that order automatically; when the reservation shrinks or
-- goes away, units are released. AUTOMATIC is the default company mode; in
-- MANUAL mode the observer does nothing.
--
-- Hard rule: the sale or reservation must NEVER fail because of units. The
-- observer trigger catches every error from the unit layer, records it on
-- the audit trail, and swallows it.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- A. Cap: a requirement may hold at most quantity_required units.
--    Replaces the one-unit-only index with a real cap so qty > 1 works.
-- ----------------------------------------------------------------------------

drop index if exists public.idx_units_one_assignment;
create index if not exists idx_units_assigned_requirement
  on public.units (assigned_requirement_id)
  where assigned_requirement_id is not null;

create or replace function public.cap_requirement_units()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_required integer;
  v_count integer;
begin
  if new.assigned_requirement_id is null then
    return new;
  end if;
  select quantity_required into v_required
  from public.journey_inventory_requirements
  where id = new.assigned_requirement_id
  for update;
  if v_required is null then
    raise exception 'That requirement was not found.';
  end if;
  select count(*) into v_count
  from public.units
  where assigned_requirement_id = new.assigned_requirement_id
    and id <> new.id;
  if v_count + 1 > v_required then
    raise exception 'That requirement already has every unit it needs.';
  end if;
  return new;
end;
$$;

revoke execute on function public.cap_requirement_units() from public, anon;

drop trigger if exists trg_units_cap_assignment on public.units;
create trigger trg_units_cap_assignment
before insert or update of assigned_requirement_id on public.units
for each row execute function public.cap_requirement_units();

-- ----------------------------------------------------------------------------
-- B. Default mode: AUTOMATIC. Existing companies still on MANUAL move over.
-- ----------------------------------------------------------------------------

alter table public.companies
  alter column unit_assignment_mode set default 'AUTOMATIC';

do $$
declare v_n integer;
begin
  update public.companies
  set unit_assignment_mode = 'AUTOMATIC'
  where unit_assignment_mode = 'MANUAL';
  get diagnostics v_n = row_count;
  raise notice 'companies moved to AUTOMATIC: %', v_n;
end $$;

-- ----------------------------------------------------------------------------
-- C. reconcile_requirement_units: make assigned units match the reservation.
--    Internal only; the observer and the RPCs reach it, clients cannot.
-- ----------------------------------------------------------------------------

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
  v_assigned uuid[];
  v_count integer;
  v_unit uuid;
  v_shortfall integer;
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

  -- Desired count: the reservation's quantity, capped at what was ordered.
  -- Cancelled or superseded requirements, cancelled journeys and quotes
  -- (a quote reserves nothing) want zero.
  if v_req.status in ('cancelled', 'superseded')
     or v_journey.cancelled_at is not null
     or v_journey.current_state = 'Quoted' then
    v_desired := 0;
  elsif v_req.status in ('delivered', 'consumed') then
    -- Delivery consumed the reservation: the assigned units leave with the
    -- order, they are not released back to stock.
    for v_unit in
      select id from public.units
      where assigned_requirement_id = v_req.id and status = 'RESERVED'
    loop
      perform public.move_unit(v_unit, 'DELIVERED', null,
        jsonb_build_object('journey_id', v_req.journey_id));
    end loop;
    return;
  else
    v_desired := least(v_req.quantity_reserved, v_req.quantity_required);
  end if;

  select array_agg(id order by unit_number)
    into v_assigned
  from public.units
  where assigned_requirement_id = v_req.id;
  v_count := coalesce(array_length(v_assigned, 1), 0);

  -- Too many units: release the newest first back to in-stock here.
  if v_count > v_desired then
    for i in reverse v_count..(v_desired + 1) loop
      perform public.move_unit(v_assigned[i], 'STOCK', null, '{}'::jsonb);
    end loop;
    v_count := v_desired;
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

    -- Still short (stock predates unit tracking or is unlabeled): record it
    -- on the audit trail so the discrepancy is visible, then continue.
    v_shortfall := v_desired - v_count;
    if v_shortfall > 0 then
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

-- ----------------------------------------------------------------------------
-- D. Observers. Requirement changes reconcile that row; journey state
--    leaving Quoted or being cancelled reconciles all its requirements.
--    Every error is caught, audited and swallowed: units never fail a sale.
-- ----------------------------------------------------------------------------

create or replace function public.observe_requirement_units()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  begin
    perform public.reconcile_requirement_units(new.id);
  exception when others then
    insert into public.audit_events (
      company_id, actor_type, entity_type, entity_id, journey_id,
      event_type, after
    )
    select s.company_id, 'SYSTEM', 'journey_inventory_requirement', new.id,
      new.journey_id, 'UNIT_ASSIGNMENT_ERROR',
      jsonb_build_object('error', sqlerrm)
    from public.sleep_journeys sj
    join public.stores s on s.id = sj.store_id
    where sj.id = new.journey_id;
  end;
  return new;
end;
$$;

revoke execute on function public.observe_requirement_units() from public, anon;

drop trigger if exists trg_jir_units_observer on public.journey_inventory_requirements;
create trigger trg_jir_units_observer
after insert or update of status, quantity_reserved, quantity_required
  on public.journey_inventory_requirements
for each row execute function public.observe_requirement_units();

create or replace function public.observe_journey_units()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
begin
  if (old.current_state = 'Quoted' and new.current_state <> 'Quoted')
     or (old.cancelled_at is null and new.cancelled_at is not null) then
    for r in
      select id from public.journey_inventory_requirements
      where journey_id = new.id
    loop
      begin
        perform public.reconcile_requirement_units(r.id);
      exception when others then
        insert into public.audit_events (
          company_id, actor_type, entity_type, entity_id, journey_id,
          event_type, after
        )
        select s.company_id, 'SYSTEM', 'journey_inventory_requirement', r.id,
          new.id, 'UNIT_ASSIGNMENT_ERROR',
          jsonb_build_object('error', sqlerrm)
        from public.stores s where s.id = new.store_id;
      end;
    end loop;
  end if;
  return new;
end;
$$;

revoke execute on function public.observe_journey_units() from public, anon;

drop trigger if exists trg_sj_units_observer on public.sleep_journeys;
create trigger trg_sj_units_observer
after update of current_state, cancelled_at on public.sleep_journeys
for each row execute function public.observe_journey_units();

-- ----------------------------------------------------------------------------
-- E. Manual overrides for later UI. Work in AUTOMATIC mode too: reconcile
--    only adds or removes the difference, so a manual pick stays put.
-- ----------------------------------------------------------------------------

create or replace function public.assign_unit_to_requirement(
  p_unit_id uuid,
  p_requirement_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company uuid;
  v_unit public.units%rowtype;
  v_req public.journey_inventory_requirements%rowtype;
begin
  if not public.has_permission('units.assign') then
    raise exception 'You do not have permission to assign units.';
  end if;
  select s.company_id into v_company
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid() and e.is_active;

  select * into v_unit from public.units where id = p_unit_id;
  if not found or v_unit.company_id <> v_company then
    raise exception 'That unit was not found.';
  end if;
  select * into v_req
  from public.journey_inventory_requirements
  where id = p_requirement_id;
  if not found then
    raise exception 'That requirement was not found.';
  end if;
  if v_unit.product_id <> v_req.variant_id then
    raise exception 'That unit is a different product.';
  end if;
  if v_unit.location_id <> v_req.location_id
     or v_unit.disposition <> 'Prime'
     or v_unit.status <> 'STOCK' then
    raise exception 'Only in-stock units at this location can be assigned.';
  end if;

  perform public.move_unit(p_unit_id, 'RESERVED', null,
    jsonb_build_object('requirement_id', p_requirement_id));
  return jsonb_build_object('assigned', p_requirement_id,
    'unit_number', v_unit.unit_number);
end;
$$;

create or replace function public.unassign_unit(p_unit_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company uuid;
  v_unit public.units%rowtype;
begin
  if not public.has_permission('units.unassign') then
    raise exception 'You do not have permission to unassign units.';
  end if;
  select s.company_id into v_company
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid() and e.is_active;

  select * into v_unit from public.units where id = p_unit_id;
  if not found or v_unit.company_id <> v_company then
    raise exception 'That unit was not found.';
  end if;
  if v_unit.assigned_requirement_id is null then
    return jsonb_build_object('released', false, 'unit_number', v_unit.unit_number);
  end if;

  perform public.move_unit(p_unit_id, 'STOCK', null, '{}'::jsonb);
  return jsonb_build_object('released', true, 'unit_number', v_unit.unit_number);
end;
$$;

grant execute on function public.assign_unit_to_requirement(uuid, uuid) to authenticated;
grant execute on function public.unassign_unit(uuid) to authenticated;
revoke execute on function public.assign_unit_to_requirement(uuid, uuid) from public, anon;
revoke execute on function public.unassign_unit(uuid) from public, anon;

-- ----------------------------------------------------------------------------
-- G. Backfill: reconcile every open requirement once. Errors go to the audit
--    trail, never abort the backfill.
-- ----------------------------------------------------------------------------

do $$
declare
  r record;
begin
  for r in
    select jir.id
    from public.journey_inventory_requirements jir
    join public.sleep_journeys sj on sj.id = jir.journey_id
    where sj.cancelled_at is null
      and jir.status not in ('cancelled', 'superseded')
  loop
    begin
      perform public.reconcile_requirement_units(r.id);
    exception when others then
      insert into public.audit_events (
        company_id, actor_type, entity_type, entity_id, journey_id,
        event_type, after
      )
      select s.company_id, 'SYSTEM', 'journey_inventory_requirement', r.id,
        (select journey_id from public.journey_inventory_requirements
          where id = r.id),
        'UNIT_ASSIGNMENT_ERROR',
        jsonb_build_object('error', sqlerrm, 'phase', 'backfill')
      from public.sleep_journeys sj
      join public.stores s on s.id = sj.store_id
      where sj.id = (select journey_id from public.journey_inventory_requirements
        where id = r.id);
    end;
  end loop;
end $$;

-- Install confirmation
select
  (select count(*) from public.journey_inventory_requirements
    where quantity_reserved > 0 and status = 'ready') as requirements_reserved,
  (select count(*) from public.units where assigned_requirement_id is not null) as units_assigned,
  (select count(*) from public.audit_events
    where event_type in ('UNIT_ASSIGNMENT_SHORTFALL', 'UNIT_ASSIGNMENT_ERROR')) as discrepancies_logged,
  (select unit_assignment_mode from public.companies limit 1) as default_mode;
