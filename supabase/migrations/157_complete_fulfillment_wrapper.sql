-- 157_complete_fulfillment_wrapper.sql
-- Slice 2 (per-item fulfillment): route the existing completion entry point
-- through record_journey_fulfillment so a single "mark fulfilled" call hands
-- over all remaining units of the order's own fulfillment method and closes
-- the order exactly as before.
--
-- The prior body is preserved as complete_journey_fulfillment_legacy
-- (defined in supabase/migrations/149_completion_rules.sql:150-343) and kept
-- only as the fallback for journeys with no line items, where there is
-- nothing to allocate per unit. Direct calls to the legacy function are
-- revoked; the wrapper reaches it under security definer.
--
-- Rollback: drop function complete_journey_fulfillment(uuid, date, text);
--   alter function public.complete_journey_fulfillment_legacy(uuid, date,
--   text) rename to complete_journey_fulfillment;
--   grant execute on function public.complete_journey_fulfillment(uuid,
--   date, text) to authenticated;

alter function public.complete_journey_fulfillment(uuid, date, text)
  rename to complete_journey_fulfillment_legacy;

revoke execute on function public.complete_journey_fulfillment_legacy(uuid, date, text)
  from public, anon, authenticated;

create or replace function public.complete_journey_fulfillment(
  p_journey_id   uuid,
  p_completed_on date default null,
  p_reason       text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_j        public.sleep_journeys%rowtype;
  v_method   text;
  v_lines    jsonb;
  v_result   jsonb;
  v_backdated boolean;
begin
  if auth.uid() is null then
    raise exception 'Not signed in.';
  end if;

  if not public.is_journey_visible(p_journey_id) then
    raise exception 'Order not found.';
  end if;

  if not exists (
    select 1 from public.journey_line_items li
    where li.journey_id = p_journey_id
  ) then
    return public.complete_journey_fulfillment_legacy(
      p_journey_id, p_completed_on, p_reason);
  end if;

  select * into v_j
  from public.sleep_journeys
  where id = p_journey_id;

  v_method := case when v_j.fulfillment_type = 'pickup' then 'pickup' else 'delivery' end;

  select coalesce(jsonb_agg(jsonb_build_object(
           'line_item_id', li.id,
           'quantity', li.quantity - (
             select count(*) from public.journey_fulfillment_units jfu
             where jfu.line_item_id = li.id
           )
         )), '[]'::jsonb)
    into v_lines
  from public.journey_line_items li
  where li.journey_id = p_journey_id
    and (case
           when coalesce(li.fulfillment_type_override::text, v_j.fulfillment_type::text) = 'pickup'
             then 'pickup' else 'delivery'
         end) = v_method
    and li.quantity - (
      select count(*) from public.journey_fulfillment_units jfu
      where jfu.line_item_id = li.id
    ) > 0;

  if v_lines = '[]'::jsonb then
    if v_j.delivered_at is not null or exists (
      select 1 from public.journey_events e
      where e.journey_id = p_journey_id and e.event_type = 'delivery_completed'
    ) then
      return public.complete_journey_fulfillment_legacy(
        p_journey_id, p_completed_on, p_reason);
    end if;
    raise exception 'Nothing is left to hand over on this order.';
  end if;

  v_result := public.record_journey_fulfillment(
    p_journey_id, v_lines, p_completed_on, p_reason);

  select backdated into v_backdated
  from public.journey_fulfillments
  where id = (v_result ->> 'fulfillment_id')::uuid;

  return jsonb_build_object(
    'journey_id',   p_journey_id,
    'delivered_at', v_result ->> 'completed_on',
    'method',       v_result ->> 'method',
    'backdated',    v_backdated,
    'state',        v_result ->> 'state',
    'is_closing',   (v_result ->> 'is_closing')::boolean,
    'units',        (v_result ->> 'units')::int
  );
end;
$$;

revoke all on function public.complete_journey_fulfillment(uuid, date, text) from public, anon;
grant execute on function public.complete_journey_fulfillment(uuid, date, text) to authenticated;

-- ---------------------------------------------------------------------------
-- record_journey_fulfillment: verbatim copy of the body created in
-- supabase/migrations/156_record_journey_fulfillment.sql:39-542 with exactly
-- one change in the per-line stock gate: the requirement lookup now accepts
-- live rows in status 'ready' or 'pending', and a line with NO live
-- requirement row is no longer rejected. That matches the pre-existing
-- behavior where a line with no reservation could still be handed over; its
-- units are written with requirement_id null and no stock movement or ledger
-- entry occurs for that line. A 'pending' row or a 'ready' row with too
-- little outstanding still raises the m148 message.
-- ---------------------------------------------------------------------------

create or replace function public.record_journey_fulfillment(
  p_journey_id   uuid,
  p_lines        jsonb,
  p_completed_on date default null,
  p_reason       text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_emp        public.employees%rowtype;
  v_j          public.sleep_journeys%rowtype;
  v_company    uuid;
  v_tz         text;
  v_today      date;
  v_date       date;
  v_created    date;
  v_method     text;
  v_backdated  boolean;
  v_reason     text := nullif(btrim(coalesce(p_reason, '')), '');
  v_prev_date  date;
  v_state      public.journey_state;
  v_active     uuid;
  v_locs       uuid[];
  v_loc_names  text;
  v_fulfillment_id uuid;
  v_is_closing boolean;
  v_location   uuid;
  v_sel        record;
  v_line       record;
  v_unit       int;
  v_sti        uuid;
  v_req        record;
  v_units_json jsonb := '[]'::jsonb;
  v_units_taken int := 0;
  v_existing_units int;
  v_total_qty  int;
  v_stop_id    uuid;
  v_stop_company uuid;
  v_stop_date  date;
  v_emp_name   text;
  v_remaining  int;
begin
  if auth.uid() is null then
    raise exception 'Not signed in.';
  end if;

  select * into v_emp
  from public.employees e
  where e.auth_user_id = auth.uid() and e.is_active;
  if not found then
    raise exception 'Not signed in as an active employee.';
  end if;

  if not public.is_journey_visible(p_journey_id) then
    raise exception 'Order not found.';
  end if;

  -- Lock the order so two people clicking at once cannot double-fulfill.
  select * into v_j
  from public.sleep_journeys
  where id = p_journey_id
  for update;
  if not found then
    raise exception 'Order not found.';
  end if;

  if v_j.cancelled_at is not null then
    raise exception 'This order is cancelled.';
  end if;

  if v_j.delivered_at is not null or exists (
    select 1 from public.journey_events e
    where e.journey_id = p_journey_id and e.event_type = 'delivery_completed'
  ) then
    v_prev_date := v_j.delivered_at;
    raise exception 'This order is already marked % on %.',
      case when v_j.fulfillment_type = 'pickup' then 'picked up' else 'delivered' end,
      coalesce(to_char(v_prev_date, 'Mon DD, YYYY'), 'an earlier date');
  end if;

  -- ---------------- selection validation ----------------
  if p_lines is null
     or jsonb_typeof(p_lines) <> 'array'
     or jsonb_array_length(p_lines) = 0 then
    raise exception 'Choose at least one item.';
  end if;

  create temporary table if not exists tmp_fulfill_sel (
    line_item_id uuid primary key,
    quantity int not null
  ) on commit drop;
  delete from tmp_fulfill_sel;

  insert into tmp_fulfill_sel (line_item_id, quantity)
  select (x->>'line_item_id')::uuid,
         (x->>'quantity')::int
  from jsonb_array_elements(p_lines) x;

  if (select count(*) from tmp_fulfill_sel)
     <> jsonb_array_length(p_lines) then
    raise exception 'Each item can be selected only once.';
  end if;

  if exists (select 1 from tmp_fulfill_sel where quantity < 1) then
    raise exception 'Choose at least one item.';
  end if;

  if exists (
    select 1 from tmp_fulfill_sel s
    where not exists (
      select 1 from public.journey_line_items li
      where li.id = s.line_item_id and li.journey_id = p_journey_id
    )
  ) then
    raise exception 'That item is not on this order.';
  end if;

  -- Remaining units per selected line.
  for v_sel in
    select s.line_item_id, s.quantity, li.quantity as line_qty
    from tmp_fulfill_sel s
    join public.journey_line_items li on li.id = s.line_item_id
  loop
    select count(*) into v_remaining
    from public.journey_fulfillment_units jfu
    where jfu.line_item_id = v_sel.line_item_id;
    v_remaining := v_sel.line_qty - v_remaining;
    if v_sel.quantity > v_remaining then
      raise exception 'More units were chosen than remain on this item.';
    end if;
  end loop;

  -- One method per call.
  select case
           when coalesce(li.fulfillment_type_override::text, v_j.fulfillment_type::text) = 'pickup'
             then 'pickup' else 'delivery'
         end
    into v_method
  from public.journey_line_items li
  where li.id = (select line_item_id from tmp_fulfill_sel limit 1);

  if exists (
    select 1
    from tmp_fulfill_sel s
    join public.journey_line_items li on li.id = s.line_item_id
    where (case
             when coalesce(li.fulfillment_type_override::text, v_j.fulfillment_type::text) = 'pickup'
               then 'pickup' else 'delivery'
           end) <> v_method
  ) then
    raise exception 'Pickup items and delivery items are handled separately.';
  end if;

  -- ---------------- permission and state rules ----------------
  if v_method = 'pickup' then
    if not public.has_permission('orders.mark_fulfilled') then
      raise exception 'You do not have permission to mark orders picked up.';
    end if;
  else
    if not public.can_finalize_delivery() then
      raise exception 'Deliveries are finalized by the warehouse team, an admin or an owner. You do not have permission to mark this delivered.';
    end if;
  end if;

  if v_method = 'pickup' then
    if v_j.current_state not in ('Sold', 'Ready to Schedule', 'Scheduled', 'Waiting for Inventory') then
      raise exception 'This order is not ready for pickup yet (it is %).', v_j.current_state;
    end if;

    -- Location rule, scoped to the lines being taken: the selected items
    -- must be leaving the location the person is working in today.
    if not public.has_permission('orders.pickup_any_location') then
      begin
        v_active := nullif(auth.jwt() -> 'user_metadata' ->> 'active_store_id', '')::uuid;
      exception when others then
        v_active := null;
      end;
      v_active := coalesce(v_active, v_emp.home_store_id);

      select array_agg(distinct loc) into v_locs
      from (
        select coalesce(li.pickup_location_id, v_j.store_id) as loc
        from tmp_fulfill_sel s
        join public.journey_line_items li on li.id = s.line_item_id
      ) q;

      if v_locs is null or exists (
        select 1 from unnest(v_locs) l where l is distinct from v_active
      ) then
        select string_agg(s.name, ' and ' order by s.name) into v_loc_names
        from public.stores s where s.id = any (coalesce(v_locs, array[v_j.store_id]));
        raise exception 'This order is picked up at %. Log in to that location to mark it picked up.',
          coalesce(v_loc_names, 'another location');
      end if;
    end if;
  else
    if v_j.current_state <> 'Scheduled' then
      raise exception 'Book a delivery before marking this order delivered (it is %).', v_j.current_state;
    end if;

    -- A delivery hands over all remaining delivery items together.
    if exists (
      select 1
      from public.journey_line_items li
      where li.journey_id = p_journey_id
        and coalesce(li.fulfillment_type_override::text, v_j.fulfillment_type::text) <> 'pickup'
        and li.quantity > (
          select count(*) from public.journey_fulfillment_units jfu
          where jfu.line_item_id = li.id
        )
        and not exists (
          select 1 from tmp_fulfill_sel s
          where s.line_item_id = li.id
            and s.quantity = li.quantity - (
              select count(*) from public.journey_fulfillment_units jfu2
              where jfu2.line_item_id = li.id
            )
        )
    ) then
      raise exception 'A delivery hands over all remaining delivery items together.';
    end if;
  end if;

  -- ---------------- date rules ----------------
  select coalesce(nullif(s.timezone, ''), 'America/Phoenix') into v_tz
  from public.stores s where s.id = v_j.store_id;

  v_today := (now() at time zone v_tz)::date;
  v_date  := coalesce(p_completed_on, v_today);

  if v_date > v_today then
    raise exception 'The date cannot be in the future.';
  end if;

  v_created := v_j.created_at::date;
  if v_date < v_created - 1 then
    raise exception 'The date cannot be before this order was created.';
  end if;

  v_backdated := v_date < v_today;
  if v_backdated then
    if not public.has_permission('orders.backdate_fulfillment') then
      raise exception 'Only an owner, admin or manager can record an earlier date. Use today''s date.';
    end if;
    if v_reason is null or length(v_reason) < 3 then
      raise exception 'Enter a reason for the earlier date.';
    end if;
  end if;

  -- ---------------- stock gate, per selected line ----------------
  create temporary table if not exists tmp_fulfill_req (
    line_item_id uuid primary key,
    requirement_id uuid,
    variant_id uuid,
    location_id uuid,
    units int not null
  ) on commit drop;
  delete from tmp_fulfill_req;

  for v_line in
    select li.id as line_item_id, li.product_id, li.quantity, li.pickup_location_id,
           li.fulfillment_type_override
    from tmp_fulfill_sel s
    join public.journey_line_items li on li.id = s.line_item_id
  loop
    v_req := null;
    if v_line.product_id is not null then
      select r.* into v_req
      from public.journey_inventory_requirements r
      where r.journey_id = p_journey_id
        and r.variant_id = v_line.product_id
        and r.location_id = case
          when coalesce(v_line.fulfillment_type_override, v_j.fulfillment_type) = 'pickup'
            then coalesce(v_line.pickup_location_id, v_j.store_id)
          else coalesce((select assigned_warehouse_id from public.stores where id = v_j.store_id), v_j.store_id)
        end
        and r.status in ('ready', 'pending')
      limit 1;

      -- A line with no live requirement row can still be handed over; its
      -- units are recorded with requirement_id null and no stock movement,
      -- matching pre-existing behavior for unreserved lines.
      if v_req.id is not null
         and (v_req.status = 'pending'
              or (v_req.quantity_reserved - v_req.quantity_fulfilled)
                 < (select quantity from tmp_fulfill_sel where line_item_id = v_line.line_item_id)) then
        raise exception 'Some items on this order are not in stock yet. Receive or transfer the stock before marking it %.',
          case when v_method = 'pickup' then 'picked up' else 'delivered' end;
      end if;
    end if;

    insert into tmp_fulfill_req (line_item_id, requirement_id, variant_id, location_id, units)
    values (
      v_line.line_item_id,
      v_req.id,
      v_line.product_id,
      case when v_req.id is not null then v_req.location_id else null end,
      (select quantity from tmp_fulfill_sel where line_item_id = v_line.line_item_id)
    );
  end loop;

  -- ---------------- closing decision, before any writes ----------------
  select count(*) into v_existing_units
  from public.journey_fulfillment_units jfu
  where jfu.journey_id = p_journey_id;

  select coalesce(sum(quantity), 0) into v_units_taken
  from tmp_fulfill_sel;

  select coalesce(sum(li.quantity), 0) into v_total_qty
  from public.journey_line_items li
  where li.journey_id = p_journey_id;

  v_is_closing := (v_existing_units + v_units_taken) = v_total_qty;

  select company_id into v_company from public.stores where id = v_j.store_id;

  -- Header location: for pickup, the single effective pickup location of
  -- the selected lines (the location rule already forces one location
  -- unless the caller has orders.pickup_any_location); for delivery, the
  -- order's store.
  if v_method = 'pickup' then
    select coalesce(li.pickup_location_id, v_j.store_id) into v_location
    from tmp_fulfill_sel s
    join public.journey_line_items li on li.id = s.line_item_id
    order by coalesce(li.pickup_location_id, v_j.store_id)
    limit 1;
    v_location := coalesce(v_location, v_active, v_j.store_id);
  else
    v_location := v_j.store_id;
  end if;

  v_emp_name := coalesce(
    nullif(btrim(coalesce(v_emp.first_name, '') || ' ' || coalesce(v_emp.last_name, '')), ''),
    v_emp.name);

  insert into public.journey_fulfillments (
    journey_id, company_id, method, location_id, completed_on,
    recorded_by, recorded_by_name, backdated, backdate_reason, is_closing
  ) values (
    p_journey_id, v_company, v_method, v_location, v_date,
    v_emp.id, v_emp_name, v_backdated,
    case when v_backdated then v_reason end,
    v_is_closing
  ) returning id into v_fulfillment_id;

  -- ---------------- units, stock, trials ----------------
  perform pg_advisory_xact_lock(hashtextextended(p_journey_id::text, 7137));

  for v_line in
    select s.line_item_id, s.quantity, li.quantity as line_qty,
           r.requirement_id, r.variant_id, r.location_id
    from tmp_fulfill_sel s
    join public.journey_line_items li on li.id = s.line_item_id
    left join tmp_fulfill_req r on r.line_item_id = s.line_item_id
    order by s.line_item_id
  loop
    for v_unit in
      select g.i
      from generate_series(1, v_line.line_qty) g(i)
      where not exists (
        select 1 from public.journey_fulfillment_units jfu
        where jfu.line_item_id = v_line.line_item_id
          and jfu.unit_index = g.i
      )
      order by g.i
      limit v_line.quantity
    loop
      select sti.id into v_sti
      from public.sleep_trial_items sti
      where sti.line_item_id = v_line.line_item_id
        and sti.unit_index = v_unit
        and sti.status = 'PENDING_FULFILLMENT'
      limit 1;

      insert into public.journey_fulfillment_units (
        fulfillment_id, journey_id, line_item_id, unit_index,
        requirement_id, sleep_trial_item_id
      ) values (
        v_fulfillment_id, p_journey_id, v_line.line_item_id, v_unit,
        v_line.requirement_id, v_sti
      );

      if v_sti is not null then
        perform public.stv_start_trial_item(
          v_sti, v_date,
          case when v_method = 'pickup' then 'PICKUP' else 'DELIVERY' end
        );
      end if;
    end loop;

    v_units_json := v_units_json || jsonb_build_object(
      'line_item_id', v_line.line_item_id,
      'quantity', v_line.quantity);
  end loop;

  -- Stock deduction per requirement row, aggregated over selected lines.
  for v_req in
    select requirement_id, variant_id, location_id, sum(units) as units
    from tmp_fulfill_req
    where requirement_id is not null
    group by requirement_id, variant_id, location_id
    order by variant_id, location_id
  loop
    perform pg_advisory_xact_lock(hashtextextended(v_req.variant_id::text || ':' || v_req.location_id::text || ':Prime', 7137));

    update public.inventory_positions
    set on_hand_quantity = greatest(0, on_hand_quantity - v_req.units),
        committed_quantity = greatest(0, committed_quantity - v_req.units),
        updated_at = now()
    where variant_id = v_req.variant_id and location_id = v_req.location_id
      and disposition = 'Prime' and sublocation_id is null;

    insert into public.stock_ledger_entries (
      variant_id, location_id, disposition, quantity_delta,
      reason, reference_type, actor_id, correlation_id
    ) values (
      v_req.variant_id, v_req.location_id, 'Prime', -v_req.units,
      'sale_delivery', 'sleep_journey', v_emp.id::text, p_journey_id
    );

    update public.journey_inventory_requirements
    set quantity_fulfilled = quantity_fulfilled + v_req.units
    where id = v_req.requirement_id;
  end loop;

  -- ---------------- event ----------------
  perform set_config('pillowtop.fulfillment_write', 'on', true);

  if v_is_closing then
    insert into public.journey_events (
      journey_id, event_type, event_data, triggered_by
    ) values (
      p_journey_id,
      'delivery_completed',
      jsonb_strip_nulls(jsonb_build_object(
        'delivered_at',    to_char(v_date, 'YYYY-MM-DD'),
        'method',          v_method,
        'recorded_by',     v_emp.id,
        'recorded_by_name', v_emp_name,
        'recorded_at',     now(),
        'backdated',       v_backdated,
        'backdate_reason', case when v_backdated then v_reason end
      )),
      auth.uid()::text
    );
  else
    insert into public.journey_events (
      journey_id, event_type, event_data, triggered_by
    ) values (
      p_journey_id,
      'journey_fulfillment_recorded',
      jsonb_strip_nulls(jsonb_build_object(
        'fulfillment_id',  v_fulfillment_id,
        'method',          v_method,
        'completed_on',    to_char(v_date, 'YYYY-MM-DD'),
        'backdated',       v_backdated,
        'backdate_reason', case when v_backdated then v_reason end,
        'recorded_by',     v_emp.id,
        'recorded_by_name', v_emp_name,
        'units',           v_units_json
      )),
      auth.uid()::text
    );

    -- A delivery hands over every remaining delivery line, so the order's
    -- BOOKED stop is done even though the order stays open for other
    -- items. Same write derive_journey_state performs at m129:505-527.
    if v_method = 'delivery' then
      update public.delivery_stops
      set status = 'COMPLETED',
          updated_at = now()
      where journey_id = p_journey_id
        and status = 'BOOKED'
      returning id, company_id, delivery_date into v_stop_id, v_stop_company, v_stop_date;

      if v_stop_id is not null then
        insert into public.delivery_stop_events (
          company_id, stop_id, journey_id, action, to_date, actor_id
        ) values (
          v_stop_company, v_stop_id, p_journey_id, 'COMPLETED',
          v_stop_date, v_emp.id
        );
      end if;
    end if;
  end if;

  perform set_config('pillowtop.fulfillment_write', 'off', true);

  select current_state into v_state
  from public.sleep_journeys where id = p_journey_id;

  return jsonb_build_object(
    'fulfillment_id', v_fulfillment_id,
    'units',          v_units_taken,
    'is_closing',     v_is_closing,
    'method',         v_method,
    'completed_on',   v_date,
    'state',          v_state
  );
end;
$$;

revoke all on function public.record_journey_fulfillment(uuid, jsonb, date, text) from public, anon;
grant execute on function public.record_journey_fulfillment(uuid, jsonb, date, text) to authenticated;
