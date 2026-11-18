-- 152_inventory_fulfilled_units.sql
-- Slice 2 (per-item fulfillment) step 3: teach the inventory functions about
-- journey_inventory_requirements.quantity_fulfilled (units already handed over
-- by record_journey_fulfillment, activated in a later migration).
--
-- Behavior while every row has quantity_fulfilled = 0 (true today):
--   identical to current behavior, with ONE intentional exception in
--   release_journey_inventory: a 'ready' row whose units were partly consumed
--   before cancel now releases only the unconsumed remainder and can no longer
--   drive committed_quantity negative. With quantity_fulfilled = 0 everywhere
--   the arithmetic reduces to today's values and the floor is a no-op.
--
-- Function changes and sources (latest definitions, verified by grep over all
-- migrations):
--
--   A. evaluate_journey_inventory
--      Based on supabase/migrations/095_requirement_quantity_reconcile.sql:38-268.
--      - Supersede loop: releases quantity_reserved - quantity_fulfilled
--        (floored at 0) instead of the full quantity_reserved. Fulfilled units
--        already surrendered their committed stock at handover.
--      - Reconcile loop: compares against outstanding quantities. Shrink case
--        releases only (quantity_reserved - quantity_fulfilled) -
--        outstanding_target, floored at 0, and never drops quantity_reserved
--        below quantity_fulfilled. If effective_qty <= quantity_fulfilled the
--        row is fully handed over: outstanding committed is released and
--        quantity_reserved is set to quantity_fulfilled, but the row STAYS
--        LIVE (status unchanged) so the next evaluation does not insert a
--        fresh full-quantity requirement and re-reserve handed-over units.
--        Status 'fulfilled' is written only by
--        consume_journey_inventory_on_delivery at the closing delivery.
--      - Reserve loop: unchanged and verified safe. v_needed =
--        quantity_required - quantity_reserved; because both counters include
--        fulfilled units, needed equals outstanding_required -
--        outstanding_reserved, so no path re-reserves an already-fulfilled
--        unit.
--      - Insert block: unchanged; fulfilled rows are not live so a re-added
--        (variant, location) gets a fresh requirement row.
--
--   B. consume_journey_inventory_on_delivery
--      Based on supabase/migrations/081_sale_fulfillment_deduction.sql:213-283.
--      - At close, deducts only outstanding = quantity_reserved -
--        quantity_fulfilled (floored at 0) per 'ready' row, then marks the
--        row 'fulfilled' with quantity_fulfilled = quantity_reserved. Ledger
--        entries record only what was actually deducted, same as today.
--      - Pending-row supersede is unchanged and still runs only at the
--        closing delivery_completed event.
--      - The zz_sale_fulfillment_deduction trigger is untouched.
--
--   C. release_journey_inventory
--      Based on supabase/migrations/035_clear_stale_inventory_ready_flag.sql:198-221.
--      - Releases quantity_reserved - quantity_fulfilled floored at 0
--        (greatest(0, ...) applied to the committed decrement). The status
--        filter already limits to 'pending'/'ready', so fulfilled, superseded
--        and cancelled rows are skipped exactly as today.
--
-- Rollback: recreate evaluate_journey_inventory from m095:38-268,
-- consume_journey_inventory_on_delivery from m081:213-283, and
-- release_journey_inventory from m035:198-221.

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
  v_outstanding integer;
  v_release integer;
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
  -- Journey waiting. Slice 2: release only the unfulfilled remainder;
  -- fulfilled units already surrendered committed stock at handover.
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
    v_release := greatest(v_req.quantity_reserved - v_req.quantity_fulfilled, 0);
    if v_release > 0 then
      perform pg_advisory_xact_lock(hashtextextended(v_req.variant_id::text || ':' || v_req.location_id::text || ':Prime', 7137));
      update public.inventory_positions
      set committed_quantity = greatest(0, committed_quantity - v_release),
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
  -- Slice 2: reconcile on outstanding units — effective minus fulfilled —
  -- so handed-over units are never re-reserved or re-released.
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
    if v_req.effective_qty <= v_req.quantity_fulfilled then
      -- Everything required is already handed over. Release only the
      -- committed stock still held for unfulfilled units, but keep the row
      -- live: marking it fulfilled here would free the (variant, location)
      -- slot and the next evaluation would insert a fresh full-quantity
      -- requirement and re-reserve units already handed over. Status
      -- 'fulfilled' is written only by consume_journey_inventory_on_delivery
      -- at the closing delivery.
      v_release := greatest(v_req.quantity_reserved - v_req.quantity_fulfilled, 0);
      if v_release > 0 then
        perform pg_advisory_xact_lock(hashtextextended(v_req.variant_id::text || ':' || v_req.location_id::text || ':Prime', 7137));
        update public.inventory_positions
        set committed_quantity = greatest(0, committed_quantity - v_release),
            updated_at = now()
        where variant_id = v_req.variant_id
          and location_id = v_req.location_id
          and disposition = 'Prime'
          and sublocation_id is null;
      end if;
      update public.journey_inventory_requirements
      set quantity_required = greatest(v_req.effective_qty, v_req.quantity_fulfilled),
          quantity_reserved = v_req.quantity_fulfilled
      where id = v_req.id;
    elsif v_req.effective_qty > v_req.quantity_required then
      -- Case (a): quantity grew. Raise the requirement; a ready row drops
      -- to pending so the reserve loop below tops up only the delta —
      -- the units already held are never released.
      update public.journey_inventory_requirements
      set quantity_required = v_req.effective_qty,
          status = case when status = 'ready' then 'pending' else status end
      where id = v_req.id;
    elsif v_req.effective_qty < v_req.quantity_required then
      -- Case (b): quantity shrank. Lower the requirement and release any
      -- reservation held for units no longer on the order. Slice 2: the
      -- release is measured against outstanding reserved units only, and
      -- quantity_reserved never drops below quantity_fulfilled.
      update public.journey_inventory_requirements
      set quantity_required = v_req.effective_qty
      where id = v_req.id;
      v_outstanding := greatest(v_req.effective_qty - v_req.quantity_fulfilled, 0);
      v_release := greatest(
        (v_req.quantity_reserved - v_req.quantity_fulfilled) - v_outstanding,
        0);
      if v_release > 0 then
        perform pg_advisory_xact_lock(hashtextextended(v_req.variant_id::text || ':' || v_req.location_id::text || ':Prime', 7137));
        update public.inventory_positions
        set committed_quantity = greatest(0, committed_quantity - v_release),
            updated_at = now()
        where variant_id = v_req.variant_id
          and location_id = v_req.location_id
          and disposition = 'Prime'
          and sublocation_id is null;
        update public.journey_inventory_requirements
        set quantity_reserved = v_req.quantity_fulfilled + v_outstanding
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

create or replace function public.consume_journey_inventory_on_delivery(p_journey_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare
  v_req record;
  v_on_hand integer;
  v_deducted integer;
  v_outstanding integer;
  v_emp_id text;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_journey_id::text, 7137));

  select id::text into v_emp_id from public.employees where auth_user_id = auth.uid();

  for v_req in
    select * from public.journey_inventory_requirements
    where journey_id = p_journey_id and status = 'ready'
    order by variant_id, location_id
    for update
  loop
    perform pg_advisory_xact_lock(hashtextextended(v_req.variant_id::text || ':' || v_req.location_id::text || ':Prime', 7137));

    -- Slice 2: units already handed over deducted their stock at
    -- fulfillment time; the closing event consumes only the remainder.
    v_outstanding := greatest(v_req.quantity_reserved - v_req.quantity_fulfilled, 0);

    select on_hand_quantity into v_on_hand
    from public.inventory_positions
    where variant_id = v_req.variant_id and location_id = v_req.location_id
      and disposition = 'Prime' and sublocation_id is null
    for update;

    v_deducted := least(v_outstanding, greatest(0, coalesce(v_on_hand, 0)));

    update public.inventory_positions
    set on_hand_quantity = greatest(0, on_hand_quantity - v_outstanding),
        committed_quantity = greatest(0, committed_quantity - v_outstanding),
        updated_at = now()
    where variant_id = v_req.variant_id and location_id = v_req.location_id
      and disposition = 'Prime' and sublocation_id is null;

    if v_deducted <> 0 then
      insert into public.stock_ledger_entries (
        variant_id, location_id, disposition, quantity_delta,
        reason, reference_type, actor_id, correlation_id
      ) values (
        v_req.variant_id, v_req.location_id, 'Prime', -v_deducted,
        'sale_delivery', 'sleep_journey', v_emp_id, p_journey_id
      );
    end if;

    update public.journey_inventory_requirements
    set status = 'fulfilled',
        quantity_fulfilled = quantity_reserved
    where id = v_req.id;
  end loop;

  -- Pending rows hold no reservation under the all-or-nothing rule, but
  -- release any reserved quantity defensively before superseding so no
  -- committed stock can leak on a delivered journey.
  for v_req in
    select * from public.journey_inventory_requirements
    where journey_id = p_journey_id and status = 'pending'
    order by variant_id, location_id
    for update
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
end;
$$;
revoke execute on function public.consume_journey_inventory_on_delivery(uuid) from authenticated, anon;

create or replace function public.release_journey_inventory(p_journey_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare
  r record;
  v_release integer;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_journey_id::text, 7137));
  for r in
    select * from public.journey_inventory_requirements
    where journey_id = p_journey_id and status in ('pending', 'ready')
    order by variant_id, location_id for update
  loop
    -- Slice 2: release only units still reserved and not yet handed over.
    -- Fulfilled units consumed their committed stock at handover, so
    -- releasing them again here would double-count.
    v_release := greatest(r.quantity_reserved - r.quantity_fulfilled, 0);
    if v_release > 0 then
      perform pg_advisory_xact_lock(hashtextextended(r.variant_id::text || ':' || r.location_id::text || ':Prime', 7137));
      update public.inventory_positions
      set committed_quantity = greatest(0, committed_quantity - v_release), updated_at = now()
      where variant_id = r.variant_id and location_id = r.location_id
        and disposition = 'Prime' and sublocation_id is null;
    end if;
    update public.journey_inventory_requirements set status = 'cancelled' where id = r.id;
  end loop;
  update public.sleep_journeys
  set inventory_ready_notified_at = null
  where id = p_journey_id;
end;
$$;
revoke execute on function public.release_journey_inventory(uuid) from authenticated, anon;
