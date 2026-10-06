-- PillowTop POS: an empty order is not fulfillable and not a sale
--
-- Before this migration, removing the last line item left price = 0, which
-- made reevaluate_journey_balance treat any journey as fully covered
-- (v_paid >= 0) — an unpaid Quoted journey flipped to Sold — and made
-- evaluate_journey_inventory land an itemless order on Ready to Schedule
-- once no pending requirements remained (after 079's supersede cleanup,
-- deterministically).
--
-- Both functions now return early when the journey has zero
-- journey_line_items rows. The evaluator still runs the stale-requirement
-- supersede first (079), so an emptied order releases its reserved stock —
-- it just no longer rewrites current_state, emits events, or stamps
-- inventory_ready_notified_at. Journeys whose line items exist but have
-- product_id = null keep the previous behavior by design.

-- 1. evaluate_journey_inventory: empty orders release reservations but do
--    not change state. Body is the 079 definition verbatim plus the early
--    return after the supersede block.

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
      set committed_quantity = greatest(0, committed_quantity - v_req.quantity_reserved),
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

  -- An order with no line items has nothing to fulfill. Stale reservations
  -- were released above; do not rewrite current_state, emit events, or stamp
  -- inventory_ready_notified_at — an emptied order must not land on
  -- Ready to Schedule.
  if not exists (
    select 1 from public.journey_line_items where journey_id = p_journey_id
  ) then
    return;
  end if;

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

-- 2. reevaluate_journey_balance: an order with no line items is a $0 order,
--    not a sale. Without the guard, v_paid >= v_price holds trivially
--    (anything >= 0) and an unpaid Quoted journey flips to Sold. Body is the
--    035_clear_stale_inventory_ready_flag.sql definition verbatim plus the
--    early return; a delivered/locked journey never reaches this function's
--    Quoted->Sold branch anyway, so the guard cannot weaken the
--    delivered-order lock.

create or replace function public.reevaluate_journey_balance(p_journey_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare
  v_current public.journey_state;
  v_price numeric;
  v_paid numeric;
  v_new_state public.journey_state;
  v_emp_id text;
begin
  select current_state, price into v_current, v_price
  from public.sleep_journeys where id = p_journey_id;

  if v_price is null or v_current not in (
    'Quoted'::public.journey_state,
    'Sold'::public.journey_state,
    'Waiting for Inventory'::public.journey_state,
    'Ready to Schedule'::public.journey_state
  ) then return; end if;

  -- No line items: a $0 order is not a sale and has no balance to enforce.
  -- Prevents emptying an order from flipping Quoted -> Sold via
  -- journey_updated_to_sold with price 0.
  if not exists (
    select 1 from public.journey_line_items where journey_id = p_journey_id
  ) then
    return;
  end if;

  select id::text into v_emp_id from public.employees where auth_user_id = auth.uid();
  v_paid := public.total_paid(p_journey_id);

  if v_current in (
    'Waiting for Inventory'::public.journey_state,
    'Ready to Schedule'::public.journey_state
  ) and v_paid >= v_price then return; end if;

  if v_paid >= v_price then
    v_new_state := 'Sold'::public.journey_state;
  else
    v_new_state := 'Quoted'::public.journey_state;
  end if;

  if v_new_state = v_current then
    -- A Journey already in Quoted must not retain a stale ready indicator.
    if v_new_state = 'Quoted'::public.journey_state then
      update public.sleep_journeys
      set inventory_ready_notified_at = null
      where id = p_journey_id and inventory_ready_notified_at is not null;
      perform public.supersede_journey_inventory_reservations(p_journey_id);
    end if;
    return;
  end if;

  update public.sleep_journeys
  set current_state = v_new_state,
      inventory_ready_notified_at = case
        when v_new_state = 'Quoted'::public.journey_state then null
        else inventory_ready_notified_at
      end,
      updated_at = now()
  where id = p_journey_id;

  if v_new_state = 'Sold' then
    insert into public.journey_events (journey_id, event_type, event_data, triggered_by)
    values (
      p_journey_id, 'journey_updated_to_sold',
      jsonb_build_object('total_paid', v_paid, 'price', v_price, 'balance_due', v_price - v_paid),
      coalesce(v_emp_id, 'system')
    );
  else
    insert into public.journey_events (journey_id, event_type, event_data, triggered_by)
    values (
      p_journey_id, 'line_items_changed_balance_due',
      jsonb_build_object('total_paid', v_paid, 'price', v_price, 'balance_due', v_price - v_paid),
      coalesce(v_emp_id, 'system')
    );
    perform public.supersede_journey_inventory_reservations(p_journey_id);
  end if;
end;
$$;
