-- PillowTop POS: PO line editing after submission, with guardrails
--
-- Lines become editable while a PO is draft / submitted / partially_received
-- (still locked on received / cancelled). Three invariants enforced at the DB:
--
--   1. quantity_received can ONLY change via receive_purchase_order_line.
--      The RPC sets a transaction-local flag; a BEFORE UPDATE trigger rejects
--      any quantity_received change without it. The flag is transaction-scoped
--      (is_local = true) and set_config isn't exposed over PostgREST, so a
--      client cannot forge it.
--
--   2. quantity_ordered can never drop below quantity_received. Already
--      covered by validate_purchase_order_line_item (BEFORE INSERT OR UPDATE
--      compares the NEW row's own values), confirmed unchanged here.
--
--   3. Lines with quantity_received > 0 cannot be deleted — enforced in the
--      delete policy's USING clause (sees the OLD row).
--
-- Plus an audit trail: post-submission line adds/removals/qty-cost changes
-- write purchase_order_events rows from a trigger, so the trail can't be
-- skipped by a raw client write. Draft-stage edits are not logged.

-- 1. RLS: widen editable statuses -------------------------------------------

drop policy if exists "PO lines insertable by owner admin manager"
  on public.purchase_order_line_items;
create policy "PO lines insertable by owner admin manager"
  on public.purchase_order_line_items
  for insert to authenticated
  with check (
    -- New lines always start at zero received — an INSERT carrying
    -- quantity_received > 0 would bypass the UPDATE guard below entirely.
    quantity_received = 0
    and exists (
      select 1 from public.purchase_orders po
      where po.id = purchase_order_id
        and po.status in ('draft','submitted','partially_received')
        and public.current_employee_role()::text in ('owner','admin','manager')
        and public.is_store_visible(po.destination_location_id)
    )
  );

drop policy if exists "PO lines updatable by owner admin manager"
  on public.purchase_order_line_items;
create policy "PO lines updatable by owner admin manager"
  on public.purchase_order_line_items
  for update to authenticated
  using (
    exists (
      select 1 from public.purchase_orders po
      where po.id = purchase_order_id
        and po.status in ('draft','submitted','partially_received')
        and public.current_employee_role()::text in ('owner','admin','manager')
        and public.is_store_visible(po.destination_location_id)
    )
  )
  with check (
    -- The resulting row must still belong to an editable PO — this also
    -- prevents re-pointing purchase_order_id at a received/cancelled PO.
    exists (
      select 1 from public.purchase_orders po
      where po.id = purchase_order_id
        and po.status in ('draft','submitted','partially_received')
        and public.current_employee_role()::text in ('owner','admin','manager')
        and public.is_store_visible(po.destination_location_id)
    )
  );

drop policy if exists "PO lines deletable by owner admin manager"
  on public.purchase_order_line_items;
create policy "PO lines deletable by owner admin manager"
  on public.purchase_order_line_items
  for delete to authenticated
  using (
    quantity_received = 0
    and exists (
      select 1 from public.purchase_orders po
      where po.id = purchase_order_id
        and po.status in ('draft','submitted','partially_received')
        and public.current_employee_role()::text in ('owner','admin','manager')
        and public.is_store_visible(po.destination_location_id)
    )
  );

-- 2. quantity_received immutability outside the receiving RPC ----------------

create or replace function public.guard_po_line_received()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.quantity_received is distinct from old.quantity_received
     and coalesce(current_setting('app.po_line_receiving', true), '') <> 'true' then
    raise exception 'quantity_received can only change through receive_purchase_order_line';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_guard_po_line_received on public.purchase_order_line_items;
create trigger trg_guard_po_line_received
  before update on public.purchase_order_line_items
  for each row execute function public.guard_po_line_received();

-- Trigger-only; no caller should invoke it directly.
revoke execute on function public.guard_po_line_received() from public, anon, authenticated;

-- Receiving RPC: unchanged except the transaction-local flag that authorizes
-- its own quantity_received update through the guard above.
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
end;
$$;

grant execute on function public.receive_purchase_order_line(uuid, integer) to authenticated;

-- 3. Post-submission edit audit trail ----------------------------------------
-- AFTER trigger so event rows land only when the edit itself succeeded.
-- quantity_received updates (receiving) are excluded: they have their own
-- events written by the RPC, and the update branch below only fires on
-- quantity_ordered / unit_cost changes.

create or replace function public.log_po_line_edit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_po_id uuid;
  v_status text;
  v_actor uuid;
begin
  v_po_id := coalesce(new.purchase_order_id, old.purchase_order_id);
  select status into v_status from public.purchase_orders where id = v_po_id;
  if not found or v_status = 'draft' then
    if tg_op = 'DELETE' then return old; end if;
    return new;
  end if;

  select id into v_actor from public.employees where auth_user_id = auth.uid();

  if tg_op = 'INSERT' then
    insert into public.purchase_order_events (purchase_order_id, event_type, event_data, actor_id)
    values (new.purchase_order_id, 'line_added', jsonb_build_object(
      'line_item_id', new.id, 'variant_id', new.variant_id,
      'quantity_ordered', new.quantity_ordered, 'unit_cost', new.unit_cost), v_actor);
    return new;
  elsif tg_op = 'DELETE' then
    insert into public.purchase_order_events (purchase_order_id, event_type, event_data, actor_id)
    values (old.purchase_order_id, 'line_removed', jsonb_build_object(
      'line_item_id', old.id, 'variant_id', old.variant_id,
      'quantity_ordered', old.quantity_ordered, 'unit_cost', old.unit_cost), v_actor);
    return old;
  elsif tg_op = 'UPDATE'
    and (new.quantity_ordered is distinct from old.quantity_ordered
      or new.unit_cost is distinct from old.unit_cost) then
    insert into public.purchase_order_events (purchase_order_id, event_type, event_data, actor_id)
    values (new.purchase_order_id, 'line_modified', jsonb_build_object(
      'line_item_id', new.id, 'variant_id', new.variant_id,
      'quantity_ordered', jsonb_build_object('from', old.quantity_ordered, 'to', new.quantity_ordered),
      'unit_cost', jsonb_build_object('from', old.unit_cost, 'to', new.unit_cost)), v_actor);
  end if;
  return new;
end;
$$;

drop trigger if exists trg_log_po_line_edit on public.purchase_order_line_items;
create trigger trg_log_po_line_edit
  after insert or update or delete on public.purchase_order_line_items
  for each row execute function public.log_po_line_edit();

-- Trigger-only; no caller should invoke it directly.
revoke execute on function public.log_po_line_edit() from public, anon, authenticated;
