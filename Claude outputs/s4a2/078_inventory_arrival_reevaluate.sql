-- PillowTop POS: wake waiting journeys when stock arrives
--
-- Purchase-order receipts, transfer receipts, and inventory-count approvals
-- wrote inventory_positions.on_hand_quantity directly and never called the
-- evaluator, so a Journey in "Waiting for Inventory" was not re-evaluated
-- when stock actually arrived (only adjust_inventory_position called it).
-- Each inbound path now calls evaluate_pending_inventory_for_variant after
-- the on-hand update, inside the same transaction and under the same
-- advisory lock already held for that variant/location.
--
-- evaluate_pending_inventory_for_variant also gains FIFO ordering: the
-- Journey with the oldest pending requirement is evaluated first. All other
-- reservation rules are unchanged: all-or-nothing per requirement,
-- pending->ready transitions, event emission, inventory_ready_notified_at.

-- 1. FIFO ordering: oldest pending requirement is evaluated first -----------

create or replace function public.evaluate_pending_inventory_for_variant(
  p_variant_id uuid, p_location_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare r record;
begin
  for r in
    select jir.journey_id, min(jir.created_at) as first_pending_at
    from public.journey_inventory_requirements jir
    join public.sleep_journeys sj on sj.id = jir.journey_id
    where jir.variant_id = p_variant_id
      and jir.location_id = p_location_id
      and jir.status = 'pending'
      and sj.cancelled_at is null
    group by jir.journey_id
    order by min(jir.created_at), jir.journey_id
  loop
    perform public.evaluate_journey_inventory(r.journey_id);
  end loop;
end;
$$;
revoke execute on function public.evaluate_pending_inventory_for_variant(uuid, uuid) from authenticated, anon;

-- 2. PO receipt wakes waiting journeys ----------------------------------------
-- Function body is the 054_po_drop_ship.sql definition verbatim plus the
-- evaluator call at the end.

create or replace function public.receive_purchase_order_line(p_line_item_id uuid, p_quantity integer)
returns void language plpgsql security definer set search_path = public
as $$
declare
  v_line public.purchase_order_line_items%rowtype;
  v_po public.purchase_orders%rowtype;
  v_role text;
  v_remaining integer;
  v_position_id uuid;
  v_old_on_hand integer;
  v_actor uuid;
  v_new_received integer;
  v_new_status text;
begin
  if p_quantity <= 0 then raise exception 'Receipt quantity must be greater than zero'; end if;
  select * into v_line from public.purchase_order_line_items where id = p_line_item_id for update;
  if not found then raise exception 'Purchase order line not found'; end if;
  select * into v_po from public.purchase_orders where id = v_line.purchase_order_id for update;
  if v_po.status not in ('submitted','partially_received') then raise exception 'Only submitted purchase orders can be received'; end if;
  if v_po.fulfillment_type <> 'stock' then raise exception 'Drop-ship purchase orders do not receive into inventory'; end if;
  if not exists (select 1 from public.stores where id = v_po.destination_location_id and location_type in ('STORE','WAREHOUSE')) then raise exception 'Invalid purchase order destination'; end if;
  select e.role::text, e.id into v_role, v_actor from public.employees e join public.stores hs on hs.id = e.home_store_id join public.stores ds on ds.id = v_po.destination_location_id where e.auth_user_id = auth.uid() and hs.company_id = ds.company_id;
  if v_role is null or v_role not in ('owner','admin','manager') then raise exception 'Only owner, admin, or manager may receive purchase orders'; end if;
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
end;
$$;

grant execute on function public.receive_purchase_order_line(uuid, integer) to authenticated;

-- 3. Transfer finalize wakes waiting journeys ---------------------------------
-- Function body is the 048_transfer_reservations_groups_warehouse.sql
-- definition verbatim plus the evaluator call inside the per-line loop.

create or replace function public.finalize_transfer(
  p_transfer_id uuid,
  p_received jsonb,
  p_employee_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid;
  v_t public.transfers%rowtype;
  v_line public.transfer_line_items%rowtype;
  v_recv integer;
  v_pos public.inventory_positions%rowtype;
  v_new_on_hand integer;
begin
  v_actor := public.verify_transfer_approver(p_employee_id);

  select * into v_t
  from public.transfers
  where id = p_transfer_id
  for update;

  if not found then raise exception 'Transfer not found'; end if;
  if v_t.status <> 'in_transit' then
    raise exception 'Only in_transit transfers can be finalized';
  end if;
  if not (public.is_store_visible(v_t.origin_location_id) or public.is_store_visible(v_t.destination_location_id)) then
    raise exception 'Transfer is not visible to this employee';
  end if;

  for v_line in
    select * from public.transfer_line_items where transfer_id = p_transfer_id for update
  loop
    if p_received is null or not (p_received ? v_line.id::text) then
      v_recv := v_line.quantity_shipped;
    else
      v_recv := (p_received ->> v_line.id::text)::integer;
    end if;

    if v_recv is null or v_recv < 0 or v_recv > v_line.quantity_shipped then
      raise exception 'Invalid received quantity for line %', v_line.id;
    end if;

    perform pg_advisory_xact_lock(
      hashtextextended(v_line.variant_id::text || ':' || v_t.destination_location_id::text || ':Prime', 7137)
    );

    select * into v_pos
    from public.inventory_positions
    where variant_id = v_line.variant_id
      and location_id = v_t.destination_location_id
      and disposition = 'Prime'
      and sublocation_id is null
    for update;

    if not found then
      insert into public.inventory_positions (
        variant_id, location_id, sublocation_id, disposition,
        on_hand_quantity, committed_quantity
      ) values (
        v_line.variant_id, v_t.destination_location_id, null, 'Prime',
        v_recv, 0
      ) returning * into v_pos;
    else
      v_new_on_hand := v_pos.on_hand_quantity + v_recv;
      update public.inventory_positions
        set on_hand_quantity = v_new_on_hand,
            updated_at = now()
      where id = v_pos.id;
    end if;

    insert into public.stock_ledger_entries (
      variant_id, location_id, disposition, quantity_delta,
      reason, reference_type, actor_id
    ) values (
      v_line.variant_id, v_t.destination_location_id, 'Prime', v_recv,
      'transfer_receive', 'transfer_line_item', v_actor::text
    );

    -- Release the approval-time reservation at the origin, by the amount
    -- originally committed (quantity_requested) regardless of what arrived.
    perform pg_advisory_xact_lock(
      hashtextextended(v_line.variant_id::text || ':' || v_t.origin_location_id::text || ':Prime', 7137)
    );
    update public.inventory_positions
      set committed_quantity = greatest(0, committed_quantity - v_line.quantity_requested),
          updated_at = now()
    where variant_id = v_line.variant_id
      and location_id = v_t.origin_location_id
      and disposition = 'Prime'
      and sublocation_id is null;

    update public.transfer_line_items
      set quantity_received = v_recv
    where id = v_line.id;

    -- Stock just arrived at the destination; wake any Journey waiting on it.
    -- Runs inside this transaction under the destination advisory lock taken
    -- above (transaction-scoped advisory locks are re-entrant).
    perform public.evaluate_pending_inventory_for_variant(
      v_line.variant_id, v_t.destination_location_id
    );
  end loop;

  update public.transfers
    set status = 'finalized',
        finalized_at = now(),
        finalized_by = v_actor
  where id = p_transfer_id;
end;
$$;

grant execute on function public.finalize_transfer(uuid, jsonb, uuid) to authenticated;

-- 4. Inventory-count approval wakes waiting journeys --------------------------
-- Function body is the 050_inventory_counts.sql definition verbatim plus the
-- evaluator call when a counted position's on-hand increased.

create or replace function public.finalize_inventory_count(
  p_count_id uuid,
  p_employee_id uuid,
  p_counts jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_emp public.employees%rowtype;
  v_count public.inventory_counts%rowtype;
  v_item public.inventory_count_items%rowtype;
  v_qty integer;
  v_pos public.inventory_positions%rowtype;
  v_old_on_hand integer;
  v_item_total integer;
begin
  v_emp := public.verify_count_employee(p_employee_id);

  select * into v_count
  from public.inventory_counts
  where id = p_count_id
  for update;

  if not found then raise exception 'Count not found'; end if;
  if v_count.status <> 'submitted' then
    raise exception 'Only submitted counts can be finalized';
  end if;
  if not public.can_finalize_count(v_emp, v_count) then
    raise exception 'Only a manager of this store or an owner/admin can finalize a count';
  end if;

  select count(*) into v_item_total
  from public.inventory_count_items
  where count_id = p_count_id;

  for v_item in
    select * from public.inventory_count_items
    where count_id = p_count_id
    order by id
    for update
  loop
    if p_counts is null or not (p_counts ? v_item.id::text) then
      raise exception 'A counted quantity is required for every item';
    end if;

    v_qty := (p_counts ->> v_item.id::text)::integer;
    if v_qty is null or v_qty < 0 then
      raise exception 'Invalid counted quantity';
    end if;

    perform pg_advisory_xact_lock(
      hashtextextended(v_item.variant_id::text || ':' || v_count.store_id::text || ':Prime', 7137)
    );

    select * into v_pos
    from public.inventory_positions
    where variant_id = v_item.variant_id
      and location_id = v_count.store_id
      and disposition = 'Prime'
      and sublocation_id is null
    for update;

    if not found then
      insert into public.inventory_positions (
        variant_id, location_id, sublocation_id, disposition,
        on_hand_quantity, committed_quantity
      ) values (
        v_item.variant_id, v_count.store_id, null, 'Prime', v_qty, 0
      );
      v_old_on_hand := 0;
    else
      v_old_on_hand := v_pos.on_hand_quantity;
      update public.inventory_positions
        set on_hand_quantity = v_qty,
            updated_at = now()
      where id = v_pos.id;
    end if;

    if v_qty <> v_old_on_hand then
      insert into public.stock_ledger_entries (
        variant_id, location_id, disposition, quantity_delta,
        reason, reference_type, actor_id
      ) values (
        v_item.variant_id, v_count.store_id, 'Prime',
        v_qty - v_old_on_hand,
        'inventory_count', 'inventory_count_item', v_emp.id::text
      );
    end if;

    update public.inventory_count_items
      set counted_quantity = v_qty,
          entered_by = v_emp.id,
          entered_at = now()
    where id = v_item.id;

    -- Only an upward correction can satisfy a waiting Journey; a downward
    -- count does not add stock, so it does not re-evaluate.
    if v_qty > v_old_on_hand then
      perform public.evaluate_pending_inventory_for_variant(
        v_item.variant_id, v_count.store_id
      );
    end if;
  end loop;

  update public.inventory_counts
    set status = 'approved',
        approved_by = v_emp.id,
        approved_at = now(),
        updated_at = now()
  where id = p_count_id;
end;
$$;

grant execute on function public.finalize_inventory_count(uuid, uuid, jsonb) to authenticated;
