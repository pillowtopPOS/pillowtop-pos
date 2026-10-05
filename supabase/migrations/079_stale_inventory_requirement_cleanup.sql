-- PillowTop POS: supersede inventory requirements stranded at a stale location
--
-- journey_inventory_requirements rows are keyed by (journey_id, variant_id,
-- location_id). The evaluator's insert path only ADDS rows at the current
-- effective location; an active row at a location that is no longer the
-- effective fulfillment location was never released. Live data showed rows
-- left behind at a store location after sourcing moved to the store's
-- assigned warehouse — one journey stayed "Waiting for Inventory" on a
-- phantom requirement, another held a committed unit at the wrong location.
--
-- evaluate_journey_inventory now supersedes any pending/ready requirement
-- whose (variant_id, location_id) is not in the current effective set,
-- releasing committed_quantity under the same advisory locks used by the
-- reserve loop. A one-time backfill at the end of this file cleans up the
-- existing bad rows; it is idempotent and safe to run twice.
--
-- Lock order for the new supersede block (same as
-- supersede_journey_inventory_reservations / release_journey_inventory):
--   1. Journey advisory lock  hashtextextended(journey_id, 7137)
--   2. Requirement row locks  FOR UPDATE, ordered by variant_id, location_id
--   3. Per-row variant:location advisory lock
--      hashtextextended(variant_id || ':' || location_id || ':Prime', 7137)
--   4. inventory_positions row update

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

  select company_id into v_company from public.stores where id = v_journey.store_id;
  if v_company is null then return; end if;
  select trigger_type into v_trigger from public.reservation_policies where company_id = v_company;
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

  insert into public.journey_inventory_requirements (journey_id, variant_id, location_id, quantity_required)
  select p_journey_id, effective.variant_id, effective.location_id, sum(effective.quantity)
  from (
    select
      jli.product_id as variant_id,
      jli.quantity,
      case
        when coalesce(jli.fulfillment_type_override, v_journey.fulfillment_type) = 'pickup'
          then coalesce(jli.pickup_location_id, v_journey.store_id)
        else coalesce((select assigned_warehouse_id from public.stores where id = v_journey.store_id), v_journey.store_id)
      end as location_id
    from public.journey_line_items jli
    where jli.journey_id = p_journey_id and jli.product_id is not null
  ) effective
  where not exists (
    select 1 from public.journey_inventory_requirements existing
    where existing.journey_id = p_journey_id
      and existing.variant_id = effective.variant_id
      and existing.location_id = effective.location_id
      and existing.status in ('pending', 'ready')
  )
  group by effective.variant_id, effective.location_id
  on conflict (journey_id, variant_id, location_id)
    where status in ('pending', 'ready') do nothing;

  perform pg_advisory_xact_lock(hashtextextended(p_journey_id::text, 7137));

  -- Supersede active requirements whose (variant_id, location_id) is no
  -- longer in the effective set for the Journey's current line items — e.g.
  -- rows left at the store after fulfillment moved sourcing to the store's
  -- warehouse. Releases their committed quantity under the same
  -- variant:location advisory locks and variant/location ordering as the
  -- reserve loop below, so stale rows can never hold stock or keep the
  -- Journey waiting.
  for v_req in
    select jir.* from public.journey_inventory_requirements jir
    where jir.journey_id = p_journey_id
      and jir.status in ('pending', 'ready')
      and not exists (
        select 1
        from (
          select
            jli.product_id as variant_id,
            case
              when coalesce(jli.fulfillment_type_override, v_journey.fulfillment_type) = 'pickup'
                then coalesce(jli.pickup_location_id, v_journey.store_id)
              else coalesce((select assigned_warehouse_id from public.stores where id = v_journey.store_id), v_journey.store_id)
            end as location_id
          from public.journey_line_items jli
          where jli.journey_id = p_journey_id and jli.product_id is not null
        ) effective
        where effective.variant_id is not distinct from jir.variant_id
          and effective.location_id = jir.location_id
      )
    order by jir.variant_id, jir.location_id
    for update of jir
  loop
    if v_req.quantity_reserved > 0 then
      perform pg_advisory_xact_lock(hashtextextended(v_req.variant_id::text || ':' || v_req.location_id::text || ':Prime', 7137));
      update public.inventory_positions
      set committed_quantity = committed_quantity - v_req.quantity_reserved,
          updated_at = now()
      where variant_id = v_req.variant_id
        and location_id = v_req.location_id
        and disposition = 'Prime'
        and sublocation_id is null;
    end if;
    update public.journey_inventory_requirements
    set status = 'superseded'
    where id = v_req.id;
  end loop;

  for v_req in
    select * from public.journey_inventory_requirements
    where journey_id = p_journey_id and status = 'pending'
    order by variant_id, location_id
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
      inventory_ready_notified_at = case
        when v_any_short then null
        when inventory_ready_notified_at is null then now()
        else inventory_ready_notified_at
      end,
      updated_at = now()
  where id = p_journey_id;

  if v_old_state is distinct from v_new_state then
    v_event_type := case when v_any_short then 'inventory_required' else 'inventory_received' end;
    insert into public.journey_events (journey_id, event_type, event_data, triggered_by)
    values (p_journey_id, v_event_type, jsonb_build_object('automated', true, 'requirements_ready', not v_any_short), 'system');
  end if;
end;
$$;

-- One-time backfill: supersede stale rows on journeys that already have them.
-- Idempotent — a second run finds no stale rows and touches nothing.
--
-- Journeys in Quoted/Sold/Waiting for Inventory/Ready to Schedule are run
-- through evaluate_journey_inventory afterwards so they re-reserve and settle
-- on the correct state. Journeys already past those states (Scheduled,
-- Sleep Trial, Completed) must NOT go through the evaluator — it rewrites
-- current_state — so their stale rows are superseded directly and their
-- state is left untouched.

do $$
declare
  v_journey record;
  v_req record;
  v_evaluated integer := 0;
begin
  for v_journey in
    select distinct sj.id, sj.current_state
    from public.journey_inventory_requirements jir
    join public.sleep_journeys sj on sj.id = jir.journey_id
    where jir.status in ('pending', 'ready')
      and sj.cancelled_at is null
      and not exists (
        select 1
        from (
          select
            jli.product_id as variant_id,
            case
              when coalesce(jli.fulfillment_type_override, sj.fulfillment_type) = 'pickup'
                then coalesce(jli.pickup_location_id, sj.store_id)
              else coalesce((select assigned_warehouse_id from public.stores where id = sj.store_id), sj.store_id)
            end as location_id
          from public.journey_line_items jli
          where jli.journey_id = sj.id and jli.product_id is not null
        ) effective
        where effective.variant_id is not distinct from jir.variant_id
          and effective.location_id = jir.location_id
      )
    order by sj.id
  loop
    raise notice 'Stale requirement cleanup: journey % (state %)', v_journey.id, v_journey.current_state;

    -- Release the stale rows directly first (same lock order as
    -- supersede_journey_inventory_reservations).
    perform pg_advisory_xact_lock(hashtextextended(v_journey.id::text, 7137));
    for v_req in
      select jir.* from public.journey_inventory_requirements jir
      where jir.journey_id = v_journey.id
        and jir.status in ('pending', 'ready')
        and not exists (
          select 1
          from (
            select
              jli.product_id as variant_id,
              case
                when coalesce(jli.fulfillment_type_override, sj.fulfillment_type) = 'pickup'
                  then coalesce(jli.pickup_location_id, sj.store_id)
                else coalesce((select assigned_warehouse_id from public.stores where id = sj.store_id), sj.store_id)
              end as location_id
            from public.journey_line_items jli
            join public.sleep_journeys sj on sj.id = jli.journey_id
            where jli.journey_id = v_journey.id and jli.product_id is not null
          ) effective
          where effective.variant_id is not distinct from jir.variant_id
            and effective.location_id = jir.location_id
        )
      order by jir.variant_id, jir.location_id
      for update of jir
    loop
      raise notice '  superseding requirement % (variant %, location %, reserved %)',
        v_req.id, v_req.variant_id, v_req.location_id, v_req.quantity_reserved;
      if v_req.quantity_reserved > 0 then
        perform pg_advisory_xact_lock(hashtextextended(v_req.variant_id::text || ':' || v_req.location_id::text || ':Prime', 7137));
        update public.inventory_positions
        set committed_quantity = committed_quantity - v_req.quantity_reserved,
            updated_at = now()
        where variant_id = v_req.variant_id
          and location_id = v_req.location_id
          and disposition = 'Prime'
          and sublocation_id is null;
      end if;
      update public.journey_inventory_requirements
      set status = 'superseded'
      where id = v_req.id;
    end loop;

    if v_journey.current_state in (
      'Quoted', 'Sold', 'Waiting for Inventory', 'Ready to Schedule'
    ) then
      perform public.evaluate_journey_inventory(v_journey.id);
      v_evaluated := v_evaluated + 1;
    end if;
  end loop;

  raise notice 'Stale requirement cleanup complete: % journey(s) re-evaluated', v_evaluated;
end $$;
