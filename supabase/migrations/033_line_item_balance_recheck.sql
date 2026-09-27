-- PillowTop POS: recheck price, balance, and inventory after every line-item change

-- Release active requirements without re-evaluating. This is used when a
-- Journey becomes underpaid; a Quoted Journey must hold zero reservations.
create or replace function public.supersede_journey_inventory_reservations(p_journey_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare r record;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_journey_id::text, 7137));
  for r in
    select * from public.journey_inventory_requirements
    where journey_id = p_journey_id and status in ('pending', 'ready')
    order by variant_id, location_id
    for update
  loop
    if r.quantity_reserved > 0 then
      perform pg_advisory_xact_lock(hashtextextended(r.variant_id::text || ':' || r.location_id::text || ':Prime', 7137));
      update public.inventory_positions
      set committed_quantity = committed_quantity - r.quantity_reserved,
          updated_at = now()
      where variant_id = r.variant_id
        and location_id = r.location_id
        and disposition = 'Prime'
        and sublocation_id is null;
    end if;
    update public.journey_inventory_requirements
    set status = 'superseded'
    where id = r.id;
  end loop;
end;
$$;
revoke execute on function public.supersede_journey_inventory_reservations(uuid) from authenticated, anon;

-- Balance reevaluation now handles downstream inventory states as well as
-- Quoted/Sold. The existing Sold = fully-paid rule is unchanged.
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
  select current_state, price
  into v_current, v_price
  from public.sleep_journeys
  where id = p_journey_id;

  if v_price is null
    or v_current not in (
      'Quoted'::public.journey_state,
      'Sold'::public.journey_state,
      'Waiting for Inventory'::public.journey_state,
      'Ready to Schedule'::public.journey_state
    ) then
    return;
  end if;

  select id::text into v_emp_id
  from public.employees
  where auth_user_id = auth.uid();

  v_paid := public.total_paid(p_journey_id);

  -- Inventory-relevant states remain unchanged when the Journey is fully paid.
  -- Do not regress them to Sold or emit a redundant event.
  if v_current in (
    'Waiting for Inventory'::public.journey_state,
    'Ready to Schedule'::public.journey_state
  ) and v_paid >= v_price then
    return;
  end if;

  if v_paid >= v_price then
    v_new_state := 'Sold'::public.journey_state;
  else
    v_new_state := 'Quoted'::public.journey_state;
  end if;

  if v_new_state = v_current then
    return;
  end if;

  update public.sleep_journeys
  set current_state = v_new_state,
      updated_at = now()
  where id = p_journey_id;

  if v_new_state = 'Sold' then
    insert into public.journey_events (journey_id, event_type, event_data, triggered_by)
    values (
      p_journey_id,
      'journey_updated_to_sold',
      jsonb_build_object(
        'total_paid', v_paid,
        'price', v_price,
        'balance_due', v_price - v_paid
      ),
      coalesce(v_emp_id, 'system')
    );
  else
    -- Deliberate limitation: this balance reversion does not create a new
    -- follow-up reminder. Existing payment/deposit follow-up behavior remains
    -- unchanged; a dedicated order-edit balance follow-up is a later phase.
    insert into public.journey_events (journey_id, event_type, event_data, triggered_by)
    values (
      p_journey_id,
      'line_items_changed_balance_due',
      jsonb_build_object(
        'total_paid', v_paid,
        'price', v_price,
        'balance_due', v_price - v_paid
      ),
      coalesce(v_emp_id, 'system')
    );

    -- Supersede both pending and ready requirements. Pending rows are included
    -- so a Quoted Journey cannot retain orphaned active requirements.
    perform public.supersede_journey_inventory_reservations(p_journey_id);
  end if;
end;
$$;

-- One comprehensive line-item trigger. It synchronizes price for INSERT,
-- UPDATE, and DELETE, then rechecks balance and inventory every time.
create or replace function public.sync_journey_price()
returns trigger language plpgsql security definer set search_path = public
as $$
declare
  v_journey_id uuid;
  v_total numeric;
  v_first_item_name text;
  v_item_count integer;
  v_summary text;
  v_event_type public.journey_event_type;
  v_event_data jsonb;
  v_emp_id text;
  v_current_state public.journey_state;
  v_override_changed boolean := false;
begin
  v_journey_id := coalesce(new.journey_id, old.journey_id);

  select id::text into v_emp_id
  from public.employees
  where auth_user_id = auth.uid();

  select coalesce(sum(quantity * unit_price), 0)
  into v_total
  from public.journey_line_items
  where journey_id = v_journey_id;

  select count(*) into v_item_count
  from public.journey_line_items
  where journey_id = v_journey_id;

  select item_name into v_first_item_name
  from public.journey_line_items
  where journey_id = v_journey_id
  order by created_at
  limit 1;

  if v_item_count > 0 then
    v_summary := v_first_item_name;
    if v_item_count > 1 then
      v_summary := v_summary || ' + ' || (v_item_count - 1) || ' more';
    end if;
  end if;

  update public.sleep_journeys
  set price = v_total,
      product_summary = coalesce(v_summary, product_summary),
      updated_at = now()
  where id = v_journey_id;

  v_event_type := case tg_op
    when 'INSERT' then 'line_item_added'
    when 'UPDATE' then 'line_item_updated'
    when 'DELETE' then 'line_item_removed'
  end;

  if tg_op = 'DELETE' then
    v_event_data := jsonb_build_object(
      'product_id', old.product_id,
      'item_name', old.item_name,
      'quantity', old.quantity,
      'unit_price', old.unit_price
    );
  else
    v_event_data := jsonb_build_object(
      'product_id', new.product_id,
      'item_name', new.item_name,
      'quantity', new.quantity,
      'unit_price', new.unit_price
    );
  end if;

  insert into public.journey_events (journey_id, event_type, event_data, triggered_by)
  values (v_journey_id, v_event_type, v_event_data, coalesce(v_emp_id, 'system'));

  -- This handles every price-affecting change, including a downstream
  -- Ready-to-Schedule/Sold Journey becoming underpaid.
  perform public.reevaluate_journey_balance(v_journey_id);

  -- Fulfillment-field changes require a fresh sourcing snapshot. This also
  -- deliberately rebuilds requirements whose effective location is unchanged;
  -- release-then-re-reserve is safe in this transaction and simplifies code.
  if tg_op = 'UPDATE' then
    v_override_changed :=
      new.fulfillment_type_override is distinct from old.fulfillment_type_override
      or new.pickup_location_id is distinct from old.pickup_location_id;
  end if;

  if v_override_changed then
    select current_state into v_current_state
    from public.sleep_journeys
    where id = v_journey_id;

    if v_current_state in (
      'Sold'::public.journey_state,
      'Waiting for Inventory'::public.journey_state,
      'Ready to Schedule'::public.journey_state
    ) then
      perform public.supersede_journey_inventory_reservations(v_journey_id);
    end if;
  end if;

  -- Unconditional: evaluate_journey_inventory() owns the reservation-policy
  -- decision, including order_creation reservations before full payment.
  perform public.evaluate_journey_inventory(v_journey_id);

  return coalesce(new, old);
end;
$$;

drop trigger if exists sync_journey_price on public.journey_line_items;
drop trigger if exists journey_inventory_line_item_hook on public.journey_line_items;
drop trigger if exists trg_line_item_fulfillment_rebuild on public.journey_line_items;
create trigger sync_journey_price
after insert or update or delete on public.journey_line_items
for each row execute function public.sync_journey_price();
