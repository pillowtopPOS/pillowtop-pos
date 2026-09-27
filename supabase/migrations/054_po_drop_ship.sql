-- PillowTop POS: PO fulfillment types — stock (default, existing behavior)
-- vs drop_ship (vendor ships direct to customer, never touches inventory).
--
--   stock:     draft -> submitted -> partially_received -> received
--   drop_ship: draft -> submitted -> shipped
--
-- A drop-ship order's destination_location_id still names the store the sale
-- is attributed to; goods never land there, so receive_purchase_order_line
-- rejects them outright and 'shipped' carries no inventory side effects.

-- 1. Columns ----------------------------------------------------------------

alter table public.purchase_orders
  add column if not exists fulfillment_type text not null default 'stock';

alter table public.purchase_orders
  add column if not exists customer_journey_id uuid
    references public.sleep_journeys(id) on delete set null;

-- Ship-to for drop_ship orders. For stock orders these stay null and the
-- destination location's own address is used instead.
alter table public.purchase_orders
  add column if not exists ship_street_address text;
alter table public.purchase_orders
  add column if not exists ship_street_address_line_2 text;
alter table public.purchase_orders
  add column if not exists ship_city text;
alter table public.purchase_orders
  add column if not exists ship_state text;
alter table public.purchase_orders
  add column if not exists ship_zip_code text;

alter table public.purchase_orders
  add column if not exists shipped_at timestamptz;
alter table public.purchase_orders
  add column if not exists tracking_number text;

alter table public.purchase_orders
  drop constraint if exists purchase_orders_fulfillment_type_check;
alter table public.purchase_orders
  add constraint purchase_orders_fulfillment_type_check
    check (fulfillment_type in ('stock', 'drop_ship'));

-- 'shipped' joins the status set (drop-ship terminal state).
alter table public.purchase_orders
  drop constraint if exists purchase_orders_status_check;
alter table public.purchase_orders
  add constraint purchase_orders_status_check
    check (status in ('draft','submitted','partially_received','received','cancelled','shipped'));

create index if not exists idx_purchase_orders_journey
  on public.purchase_orders (customer_journey_id)
  where customer_journey_id is not null;

-- 2. Lifecycle validation ----------------------------------------------------
-- fulfillment_type is fixed at creation (like destination). Terminal states
-- are type-specific: drop_ship can only reach 'shipped', never received
-- states; stock can never be 'shipped'.

create or replace function public.validate_purchase_order_fulfillment()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'UPDATE' and new.fulfillment_type is distinct from old.fulfillment_type then
    raise exception 'Purchase order fulfillment type cannot be changed';
  end if;

  if new.fulfillment_type = 'drop_ship' then
    if new.status in ('partially_received', 'received') then
      raise exception 'Drop-ship purchase orders cannot be received';
    end if;
    if new.status = 'shipped' then
      -- draft -> shipped, cancelled -> shipped, and INSERT-as-shipped are all
      -- invalid: a drop-ship order must go through 'submitted' first.
      if tg_op = 'INSERT' then
        raise exception 'Drop-ship purchase orders must be submitted before they can be shipped';
      elsif old.status is distinct from 'submitted' then
        raise exception 'Drop-ship purchase orders must be submitted before they can be shipped';
      end if;
      if new.shipped_at is null then
        new.shipped_at := now();
      end if;
    end if;
  elsif new.fulfillment_type = 'stock' then
    if new.status = 'shipped' then
      raise exception 'Stock purchase orders are received, not shipped';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_validate_purchase_order_fulfillment on public.purchase_orders;
create trigger trg_validate_purchase_order_fulfillment
  before insert or update of status, fulfillment_type, shipped_at
  on public.purchase_orders
  for each row execute function public.validate_purchase_order_fulfillment();

-- Trigger-only; no caller should invoke it directly.
revoke execute on function public.validate_purchase_order_fulfillment() from public, anon, authenticated;

-- 2b. Audit trail: 'shipped' event -------------------------------------------
-- purchase_order_events has no client INSERT policy, so this has to happen
-- server-side. Same rationale as trg_log_po_line_edit: an AFTER trigger means
-- the trail can't be skipped by a raw status update outside markShipped().

create or replace function public.log_po_shipped()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid;
begin
  if new.status = 'shipped' and old.status is distinct from 'shipped' then
    select id into v_actor from public.employees where auth_user_id = auth.uid();
    insert into public.purchase_order_events (purchase_order_id, event_type, event_data, actor_id)
    values (new.id, 'shipped', jsonb_strip_nulls(jsonb_build_object(
      'tracking_number', new.tracking_number)), v_actor);
  end if;
  return new;
end;
$$;

drop trigger if exists trg_log_po_shipped on public.purchase_orders;
create trigger trg_log_po_shipped
  after update of status on public.purchase_orders
  for each row execute function public.log_po_shipped();

revoke execute on function public.log_po_shipped() from public, anon, authenticated;

-- 3. Receiving RPC: hard-block drop_ship -------------------------------------
-- The UI never offers Receive on drop-ship orders, but the RPC must enforce
-- it too: a submitted drop-ship PO would otherwise pass the status check and
-- write inventory_positions/stock_ledger_entries for goods that never touch
-- company stock. Everything else in the function is unchanged.

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
end;
$$;

grant execute on function public.receive_purchase_order_line(uuid, integer) to authenticated;
