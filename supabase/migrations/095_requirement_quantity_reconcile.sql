-- ============================================================================
-- INV-QTY — reconcile inventory requirements when line quantities change
--
-- THE BUG (081 body): the requirement INSERT skips any (variant_id,
-- location_id) that already has a pending or ready requirement, and the
-- reserve loop only visits status = 'pending'. A requirement therefore
-- keeps the quantity_required it was first created with — editing a line's
-- quantity never changes it:
--   qty UP   -> under-reserved (oversell) whenever the reservation trigger
--               stays true (deposit_received, order_creation,
--               order_confirmed, and exchange children whose credit absorbs
--               the add-on so price does not change; under paid_in_full a
--               price increase releases and self-heals at next payment)
--   qty DOWN -> over-reserved: stock held for units no longer on the order
--
-- THE FIX (in-place reconcile): one new block after the existing supersede
-- block and before the empty-order guard. For every active requirement
-- still matching an effective (variant, location) group:
--   a) effective > required : raise quantity_required; a ready row demotes
--      to pending so the existing pending loop reserves only the delta.
--      Units already held stay held while waiting.
--   b) effective < required : lower quantity_required; if more is reserved
--      than now needed, release the excess committed stock and clamp
--      quantity_reserved. The pending loop's needed <= 0 branch then marks
--      the row ready.
--   c) equal                : no change.
-- created_at is never touched, so the row keeps its FIFO place in
-- evaluate_pending_inventory_for_variant (078 orders by min(created_at)).
--
-- Lock order preserved: journey advisory lock (already held above), then
-- requirement rows FOR UPDATE ordered by variant/location, then the
-- variant:location advisory lock, then the position row.
--
-- Everything else in the function is the 081_sale_fulfillment_deduction.sql
-- body verbatim.
-- ============================================================================

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
  if v_journey.delivered_at is not null then return; end if;

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

  -- INV-QTY: reconcile surviving active requirements against the current
  -- effective line quantities. The supersede block above already removed
  -- rows whose (variant, location) no longer matches, so every active row
  -- joined here has an effective group. Same effective-location expression
  -- as the insert and supersede blocks; same lock order (journey advisory
  -- held -> requirement rows FOR UPDATE ordered by variant/location ->
  -- variant:location advisory -> position row). created_at is untouched so
  -- the row keeps its FIFO place in evaluate_pending_inventory_for_variant.
  for v_req in
    select jir.*, eff.effective_qty
    from public.journey_inventory_requirements jir
    join (
      select
        jli.product_id as variant_id,
        case
          when coalesce(jli.fulfillment_type_override, v_journey.fulfillment_type) = 'pickup'
            then coalesce(jli.pickup_location_id, v_journey.store_id)
          else coalesce((select assigned_warehouse_id from public.stores where id = v_journey.store_id), v_journey.store_id)
        end as location_id,
        sum(jli.quantity) as effective_qty
      from public.journey_line_items jli
      where jli.journey_id = p_journey_id and jli.product_id is not null
      group by 1, 2
    ) eff
      on eff.variant_id is not distinct from jir.variant_id
      and eff.location_id = jir.location_id
    where jir.journey_id = p_journey_id
      and jir.status in ('pending', 'ready')
    order by jir.variant_id, jir.location_id
    for update of jir
  loop
    if v_req.effective_qty > v_req.quantity_required then
      -- Case (a): quantity grew. Raise the requirement; a ready row drops
      -- to pending so the reserve loop below tops up only the delta —
      -- the units already held are never released.
      update public.journey_inventory_requirements
      set quantity_required = v_req.effective_qty,
          status = case when status = 'ready' then 'pending' else status end
      where id = v_req.id;
    elsif v_req.effective_qty < v_req.quantity_required then
      -- Case (b): quantity shrank. Lower the requirement and release any
      -- reservation held for units no longer on the order.
      update public.journey_inventory_requirements
      set quantity_required = v_req.effective_qty
      where id = v_req.id;
      if v_req.quantity_reserved > v_req.effective_qty then
        perform pg_advisory_xact_lock(hashtextextended(v_req.variant_id::text || ':' || v_req.location_id::text || ':Prime', 7137));
        update public.inventory_positions
        set committed_quantity = greatest(0, committed_quantity - (v_req.quantity_reserved - v_req.effective_qty)),
            updated_at = now()
        where variant_id = v_req.variant_id
          and location_id = v_req.location_id
          and disposition = 'Prime'
          and sublocation_id is null;
        update public.journey_inventory_requirements
        set quantity_reserved = v_req.effective_qty
        where id = v_req.id;
      end if;
    end if;
    -- Case (c): equal — no change.
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

revoke execute on function public.evaluate_journey_inventory(uuid) from authenticated, anon;
