-- PillowTop POS: consume reserved stock when a Journey is delivered
--
-- delivery_completed (Mark Delivered, shared by delivery and pickup) stamped
-- sleep_journeys.delivered_at but never touched inventory: ready requirements
-- kept their committed_quantity forever and on_hand_quantity was never
-- decremented. This migration adds a terminal 'fulfilled' requirement status,
-- a consume function that converts each ready reservation into a sale
-- deduction (on_hand and committed both reduced by quantity_reserved, so ATS
-- is unchanged — the committed unit becomes the shipped unit), and an AFTER
-- INSERT trigger on journey_events gated on delivery_completed.
--
-- The evaluator also gains a delivered_at guard: a delivered Journey can no
-- longer gain fresh requirements, reserve stock, or have its current_state
-- rewritten by any evaluation path.

-- 1. Requirement status: 'fulfilled' is the terminal consumed state ---------

alter table public.journey_inventory_requirements
  drop constraint if exists journey_inventory_requirements_status_check;
alter table public.journey_inventory_requirements
  add constraint journey_inventory_requirements_status_check
  check (status in ('pending', 'ready', 'cancelled', 'superseded', 'fulfilled'));

-- 2. evaluate_journey_inventory: delivered journeys are inert ---------------
-- Body is the 080_empty_order_guard.sql definition verbatim plus the
-- delivered_at early return immediately after the cancelled_at check.
-- Nothing else changed: the 079 supersede block and the 080 empty-order
-- guard are preserved exactly.

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

-- 3. consume_journey_inventory_on_delivery ----------------------------------
-- Converts each ready reservation into a sale deduction. Lock order matches
-- the existing convention: journey advisory, then ready requirement rows
-- ordered by variant/location FOR UPDATE, then the per-row variant:location
-- advisory, then the position row. on_hand and committed are each decremented
-- by quantity_reserved and floored at 0; the ledger records the on-hand
-- amount actually deducted. Only 'ready' rows are consumed, so a second
-- delivery_completed event is a no-op; remaining 'pending' rows are
-- superseded so nothing on a delivered journey can grab stock later.

create or replace function public.consume_journey_inventory_on_delivery(p_journey_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare
  v_req record;
  v_on_hand integer;
  v_deducted integer;
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

    select on_hand_quantity into v_on_hand
    from public.inventory_positions
    where variant_id = v_req.variant_id and location_id = v_req.location_id
      and disposition = 'Prime' and sublocation_id is null
    for update;

    v_deducted := least(v_req.quantity_reserved, greatest(0, coalesce(v_on_hand, 0)));

    update public.inventory_positions
    set on_hand_quantity = greatest(0, on_hand_quantity - v_req.quantity_reserved),
        committed_quantity = greatest(0, committed_quantity - v_req.quantity_reserved),
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
    set status = 'fulfilled'
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

-- 4. delivery_completed trigger ---------------------------------------------
-- AFTER INSERT on journey_events, gated on delivery_completed — covers both
-- delivery and pickup fulfillment (they share the same completion event).
-- Named zz_sale_fulfillment_deduction so it fires last among the existing
-- same-timing triggers (journey_event_derive_state,
-- trg_set_journey_delivered_at, zz_inventory_event_hook), which run in
-- alphabetical order.

create or replace function public.consume_journey_inventory_delivery_hook()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if new.event_type = 'delivery_completed' then
    perform public.consume_journey_inventory_on_delivery(new.journey_id);
  end if;
  return new;
end;
$$;
revoke execute on function public.consume_journey_inventory_delivery_hook() from authenticated, anon;

drop trigger if exists zz_sale_fulfillment_deduction on public.journey_events;
create trigger zz_sale_fulfillment_deduction
after insert on public.journey_events for each row
execute function public.consume_journey_inventory_delivery_hook();
