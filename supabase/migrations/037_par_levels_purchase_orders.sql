-- PillowTop POS Phase 7d-i: par levels and purchase orders/receiving

create table if not exists public.par_levels (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null references public.stores(id) on delete cascade,
  variant_id uuid not null references public.products(id) on delete cascade,
  minimum_quantity integer not null check (minimum_quantity >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (store_id, variant_id)
);

create table if not exists public.purchase_orders (
  id uuid primary key default gen_random_uuid(),
  vendor_name text not null,
  destination_location_id uuid not null references public.stores(id) on delete restrict,
  status text not null default 'draft' check (status in ('draft','submitted','partially_received','received','cancelled')),
  created_by uuid not null references public.employees(id),
  created_at timestamptz not null default now(),
  submitted_at timestamptz,
  received_at timestamptz,
  cancelled_at timestamptz
);

create table if not exists public.purchase_order_line_items (
  id uuid primary key default gen_random_uuid(),
  purchase_order_id uuid not null references public.purchase_orders(id) on delete cascade,
  variant_id uuid not null references public.products(id),
  quantity_ordered integer not null check (quantity_ordered > 0),
  quantity_received integer not null default 0 check (quantity_received >= 0),
  unit_cost numeric not null check (unit_cost >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (purchase_order_id, variant_id),
  check (quantity_received <= quantity_ordered)
);

create table if not exists public.purchase_order_events (
  id uuid primary key default gen_random_uuid(),
  purchase_order_id uuid not null references public.purchase_orders(id) on delete cascade,
  event_type text not null,
  event_data jsonb not null default '{}',
  actor_id uuid references public.employees(id),
  created_at timestamptz not null default now(),
  correlation_id uuid not null default gen_random_uuid()
);

create or replace function public.validate_purchase_order_destination()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if tg_op = 'UPDATE' and new.destination_location_id is distinct from old.destination_location_id then
    raise exception 'Purchase order destination cannot be changed after creation';
  end if;
  if not exists (select 1 from public.stores where id = new.destination_location_id and location_type in ('STORE','WAREHOUSE')) then
    raise exception 'Purchase order destination must be a STORE or WAREHOUSE';
  end if;
  return new;
end;
$$;
drop trigger if exists trg_validate_purchase_order_destination on public.purchase_orders;
create trigger trg_validate_purchase_order_destination before insert or update on public.purchase_orders for each row execute function public.validate_purchase_order_destination();

create or replace function public.validate_purchase_order_line_item()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if new.quantity_received > new.quantity_ordered then raise exception 'Received quantity cannot exceed ordered quantity'; end if;
  -- Draft-only client editing is enforced by RLS. Do not check PO status here:
  -- receive_purchase_order_line() updates quantity_received on submitted POs.
  return new;
end;
$$;
drop trigger if exists trg_validate_purchase_order_line_item on public.purchase_order_line_items;
create trigger trg_validate_purchase_order_line_item before insert or update on public.purchase_order_line_items for each row execute function public.validate_purchase_order_line_item();

-- Atomic receipt: PO/line locks, Prime position update, ledger entry, line/status/event updates.
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
  v_new_received := v_line.quantity_received + p_quantity;
  update public.purchase_order_line_items set quantity_received = v_new_received, updated_at = now() where id = v_line.id;
  select case when exists (select 1 from public.purchase_order_line_items where purchase_order_id = v_po.id and quantity_received < quantity_ordered) then 'partially_received' else 'received' end into v_new_status;
  update public.purchase_orders set status = v_new_status, received_at = case when v_new_status = 'received' then now() else received_at end where id = v_po.id;
  insert into public.purchase_order_events (purchase_order_id, event_type, event_data, actor_id) values (v_po.id, case when v_new_status = 'received' then 'received' else 'partially_received' end, jsonb_build_object('line_item_id', v_line.id, 'quantity', p_quantity, 'destination_location_id', v_po.destination_location_id), v_actor);
end;
$$;
grant execute on function public.receive_purchase_order_line(uuid, integer) to authenticated;

alter table public.par_levels enable row level security;
alter table public.purchase_orders enable row level security;
alter table public.purchase_order_line_items enable row level security;
alter table public.purchase_order_events enable row level security;

create policy "Par levels viewable by visible location" on public.par_levels for select to authenticated using (public.is_store_visible(store_id));
create policy "Par levels insertable by owner admin manager" on public.par_levels for insert to authenticated with check (public.current_employee_role()::text in ('owner','admin','manager') and public.is_store_visible(store_id));
create policy "Par levels updatable by owner admin manager" on public.par_levels for update to authenticated using (public.current_employee_role()::text in ('owner','admin','manager') and public.is_store_visible(store_id)) with check (public.current_employee_role()::text in ('owner','admin','manager') and public.is_store_visible(store_id));
create policy "Par levels deletable by owner admin manager" on public.par_levels for delete to authenticated using (public.current_employee_role()::text in ('owner','admin','manager') and public.is_store_visible(store_id));

create policy "Purchase orders viewable by location" on public.purchase_orders for select to authenticated using (public.is_store_visible(destination_location_id));
create policy "Purchase orders insertable by owner admin manager" on public.purchase_orders for insert to authenticated with check (public.current_employee_role()::text in ('owner','admin','manager') and public.is_store_visible(destination_location_id));
create policy "Purchase orders updatable by owner admin manager" on public.purchase_orders for update to authenticated using (public.current_employee_role()::text in ('owner','admin','manager') and public.is_store_visible(destination_location_id)) with check (public.current_employee_role()::text in ('owner','admin','manager') and public.is_store_visible(destination_location_id));

create policy "PO lines viewable by visible PO" on public.purchase_order_line_items for select to authenticated using (exists (select 1 from public.purchase_orders po where po.id = purchase_order_id and public.is_store_visible(po.destination_location_id)));
create policy "PO lines insertable by owner admin manager" on public.purchase_order_line_items for insert to authenticated with check (exists (select 1 from public.purchase_orders po where po.id = purchase_order_id and po.status = 'draft' and public.current_employee_role()::text in ('owner','admin','manager') and public.is_store_visible(po.destination_location_id)));
create policy "PO lines updatable by owner admin manager" on public.purchase_order_line_items for update to authenticated using (exists (select 1 from public.purchase_orders po where po.id = purchase_order_id and po.status = 'draft' and public.current_employee_role()::text in ('owner','admin','manager') and public.is_store_visible(po.destination_location_id))) with check (true);
create policy "PO lines deletable by owner admin manager" on public.purchase_order_line_items for delete to authenticated using (exists (select 1 from public.purchase_orders po where po.id = purchase_order_id and po.status = 'draft' and public.current_employee_role()::text in ('owner','admin','manager') and public.is_store_visible(po.destination_location_id)));

create policy "PO events viewable by visible PO" on public.purchase_order_events for select to authenticated using (exists (select 1 from public.purchase_orders po where po.id = purchase_order_id and public.is_store_visible(po.destination_location_id)));
