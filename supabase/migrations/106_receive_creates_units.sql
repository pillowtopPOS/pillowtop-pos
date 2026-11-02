-- ============================================================================
-- Unit ID S2: receiving a unit-tracked product creates one unit per piece
--
-- receive_purchase_order_line now returns jsonb (was void): the new unit
-- ids and unit numbers so the app can print labels right after receiving.
-- For untracked products nothing changes; the arrays come back empty.
-- Stock bookkeeping is untouched: the existing position and ledger writes
-- stay here, and create_unit only registers identity (it writes no stock
-- numbers), so nothing double counts.
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
  return jsonb_build_object('unit_ids', v_unit_ids, 'unit_numbers', v_unit_numbers);
end;
$$;

comment on function public.receive_purchase_order_line(uuid, integer) is
  'Receives a purchase-order line into stock. For unit-tracked products it
   also creates one unit per piece in the same transaction and returns
   their ids and numbers for label printing. Untracked products return
   empty arrays.';

grant execute on function public.receive_purchase_order_line(uuid, integer) to authenticated;
revoke execute on function public.receive_purchase_order_line(uuid, integer) from public, anon;
