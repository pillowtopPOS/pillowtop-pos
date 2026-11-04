-- ============================================================================
-- Unit ID S3b Stage 1: customer label info for received-and-assigned units
--
-- Units are created inside receive_purchase_order_line BEFORE the evaluator
-- reserves stock for waiting orders; the S3a observer then assigns them in
-- the same transaction. The receive screen needs to know which orders those
-- units now belong to, so the rpc returns an `assignments` array alongside
-- the existing unit_ids/unit_numbers (which the UI already reads).
-- get_unit_customer_labels reprints the same info later; get_journey_units
-- lets an order list its assigned units. Read-only additions: no table,
-- trigger or observer changes. One transaction, no extra round trips.
-- ============================================================================

drop function if exists public.receive_purchase_order_line(uuid, integer);

create function public.receive_purchase_order_line(p_line_item_id uuid, p_quantity integer)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  v_line public.purchase_order_line_items%rowtype;
  v_po public.purchase_orders%rowtype;
  v_role text;
  v_remaining integer;
  v_position_id uuid;
  v_old_on_hand integer;
  v_actor uuid;
  v_company_id uuid;
  v_new_received integer;
  v_new_status text;
  v_unit_ids uuid[] := '{}';
  v_unit_numbers bigint[] := '{}';
  v_assignments jsonb := '[]'::jsonb;
  v_new_unit uuid;
  i integer;
begin
  if p_quantity <= 0 then raise exception 'Receipt quantity must be greater than zero'; end if;
  select * into v_line from public.purchase_order_line_items where id = p_line_item_id for update;
  if not found then raise exception 'Purchase order line not found'; end if;
  select * into v_po from public.purchase_orders where id = v_line.purchase_order_id for update;
  if v_po.status not in ('submitted','partially_received') then raise exception 'Only submitted purchase orders can be received'; end if;
  if v_po.fulfillment_type <> 'stock' then raise exception 'Drop-ship purchase orders do not receive into inventory'; end if;
  if not exists (select 1 from public.stores where id = v_po.destination_location_id and location_type in ('STORE','WAREHOUSE')) then raise exception 'Invalid purchase order destination'; end if;
  select e.role::text, e.id, ds.company_id into v_role, v_actor, v_company_id from public.employees e join public.stores hs on hs.id = e.home_store_id join public.stores ds on ds.id = v_po.destination_location_id where e.auth_user_id = auth.uid() and hs.company_id = ds.company_id;
  if v_actor is null or not public.has_permission('inventory.receive_po') then raise exception 'You do not have permission to receive purchase orders.'; end if;
  if public.is_unit_tracked(v_line.variant_id) and p_quantity > 500 then
    raise exception 'Cannot create % units at once. That many labels is almost certainly a typo; receive in smaller batches or check the quantity.', p_quantity;
  end if;
  v_remaining := v_line.quantity_ordered - v_line.quantity_received;
  if p_quantity > v_remaining then raise exception 'Receipt exceeds remaining quantity'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_line.variant_id::text || ':' || v_po.destination_location_id::text || ':Prime', 7137));
  select id, on_hand_quantity into v_position_id, v_old_on_hand from public.inventory_positions where variant_id = v_line.variant_id and location_id = v_po.destination_location_id and disposition = 'Prime' and sublocation_id is null for update;
  if not found then
    insert into public.inventory_positions (variant_id, location_id, disposition, on_hand_quantity, committed_quantity) values (v_line.variant_id, v_po.destination_location_id, 'Prime', p_quantity, 0) returning id into v_position_id;
    v_old_on_hand := 0;
  else
    update public.inventory_positions set on_hand_quantity = on_hand_quantity + p_quantity, updated_at = now() where id = v_position_id;
  end if;
  insert into public.stock_ledger_entries (variant_id, location_id, disposition, quantity_delta, reason, reference_type, actor_id) values (v_line.variant_id, v_po.destination_location_id, 'Prime', p_quantity, 'purchase_order_receipt', 'purchase_order_line_item', v_actor::text);
  -- One unit per received piece for tracked products. create_unit writes
  -- the units row and its UNIT_CREATED event only; it never touches stock,
  -- so the position and ledger writes above stay the sole stock change.
  if public.is_unit_tracked(v_line.variant_id) then
    for i in 1..p_quantity loop
      v_new_unit := public.create_unit(
        v_company_id, v_line.variant_id, v_po.destination_location_id,
        'Prime', p_line_item_id, v_actor);
      v_unit_ids := v_unit_ids || v_new_unit;
      v_unit_numbers := v_unit_numbers || (
        select unit_number from public.units where id = v_new_unit);
    end loop;
  end if;
  -- Transaction-local flag authorizes the quantity_received update through
  -- trg_guard_po_line_received. Dies with this transaction.
  perform set_config('app.po_line_receiving', 'true', true);
  v_new_received := v_line.quantity_received + p_quantity;
  update public.purchase_order_line_items set quantity_received = v_new_received, updated_at = now() where id = v_line.id;
  select case when exists (select 1 from public.purchase_order_line_items where purchase_order_id = v_po.id and quantity_received < quantity_ordered) then 'partially_received' else 'received' end into v_new_status;
  update public.purchase_orders set status = v_new_status, received_at = case when v_new_status = 'received' then now() else received_at end where id = v_po.id;
  insert into public.purchase_order_events (purchase_order_id, event_type, event_data, actor_id) values (v_po.id, case when v_new_status = 'received' then 'received' else 'partially_received' end, jsonb_build_object('line_item_id', v_line.id, 'quantity', p_quantity, 'destination_location_id', v_po.destination_location_id), v_actor);
  -- Stock just arrived at this location; wake any Journey waiting on it.
  -- Runs inside this transaction under the advisory lock taken above.
  perform public.evaluate_pending_inventory_for_variant(v_line.variant_id, v_po.destination_location_id);
  -- The S3a observer has run by now: units created above may be assigned to
  -- waiting orders. Report which ones, so the UI can offer customer labels.
  if v_unit_ids <> '{}' then
    select coalesce(jsonb_agg(jsonb_build_object(
        'unit_id', u.id,
        'unit_number', u.unit_number,
        'journey_id', jir.journey_id,
        'journey_number', sj.journey_number,
        'customer_name', trim(c.first_name || ' ' || c.last_name),
        'requirement_id', jir.id
      ) order by u.unit_number), '[]'::jsonb)
    into v_assignments
    from public.units u
    join public.journey_inventory_requirements jir
      on jir.id = u.assigned_requirement_id
    join public.sleep_journeys sj on sj.id = jir.journey_id
    join public.customers c on c.id = sj.customer_id
    where u.id = any(v_unit_ids);
  end if;
  return jsonb_build_object(
    'unit_ids', v_unit_ids,
    'unit_numbers', v_unit_numbers,
    'assignments', v_assignments);
end;
$$;

comment on function public.receive_purchase_order_line(uuid, integer) is
  'Receives a purchase-order line into stock. For unit-tracked products it
   also creates one unit per piece in the same transaction and returns
   their ids, numbers, and any order assignments made by the observer.
   Untracked products return empty arrays.';

grant execute on function public.receive_purchase_order_line(uuid, integer) to authenticated;
revoke execute on function public.receive_purchase_order_line(uuid, integer) from public, anon;

-- ----------------------------------------------------------------------------
-- Reprint path: the same label info for any already-assigned units the
-- caller's company owns. Unknown or foreign ids are skipped, never raised.
-- ----------------------------------------------------------------------------

create or replace function public.get_unit_customer_labels(p_unit_ids uuid[])
returns table (
  unit_id uuid,
  unit_number bigint,
  journey_id uuid,
  journey_number text,
  customer_name text,
  requirement_id uuid
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company uuid;
begin
  select s.company_id into v_company
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid() and e.is_active;
  if v_company is null then
    raise exception 'You do not have permission to print unit labels.';
  end if;

  return query
  select u.id, u.unit_number, jir.journey_id, sj.journey_number,
    trim(c.first_name || ' ' || c.last_name), jir.id
  from public.units u
  join public.journey_inventory_requirements jir
    on jir.id = u.assigned_requirement_id
  join public.sleep_journeys sj on sj.id = jir.journey_id
  join public.customers c on c.id = sj.customer_id
  where u.id = any(p_unit_ids)
    and u.company_id = v_company
  order by u.unit_number;
end;
$$;

grant execute on function public.get_unit_customer_labels(uuid[]) to authenticated;
revoke execute on function public.get_unit_customer_labels(uuid[]) from public, anon;

-- ----------------------------------------------------------------------------
-- An order listing its assigned units: one row per (requirement, unit).
-- Caller must pass the normal journey visibility rule.
-- ----------------------------------------------------------------------------

create or replace function public.get_journey_units(p_journey_id uuid)
returns table (
  requirement_id uuid,
  variant_id uuid,
  unit_id uuid,
  unit_number bigint,
  status text
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_journey_visible(p_journey_id) then
    raise exception 'Journey not found.';
  end if;

  return query
  select jir.id, jir.variant_id, u.id, u.unit_number, u.status::text
  from public.journey_inventory_requirements jir
  join public.units u on u.assigned_requirement_id = jir.id
  where jir.journey_id = p_journey_id
  order by jir.id, u.unit_number;
end;
$$;

grant execute on function public.get_journey_units(uuid) to authenticated;
revoke execute on function public.get_journey_units(uuid) from public, anon;

-- Install confirmation: the functions exist and grants are right.
select
  has_function_privilege('authenticated', 'public.receive_purchase_order_line(uuid,integer)', 'execute') as receive_auth,
  has_function_privilege('authenticated', 'public.get_unit_customer_labels(uuid[])', 'execute') as labels_auth,
  has_function_privilege('authenticated', 'public.get_journey_units(uuid)', 'execute') as journey_auth,
  has_function_privilege('anon', 'public.get_unit_customer_labels(uuid[])', 'execute') as labels_anon,
  has_function_privilege('anon', 'public.get_journey_units(uuid)', 'execute') as journey_anon;
