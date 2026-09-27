-- PillowTop POS Phase 7b: Core Inventory Item Model

-- 1. Disposition enum (exactly the six canonical dispositions)

do $$
begin
  if not exists (select 1 from pg_type where typname = 'disposition') then
    create type public.disposition as enum (
      'Prime',
      'Floor',
      'Display',
      'Clearance',
      'Damaged',
      'Returned'
    );
  end if;
end $$;

grant usage on type public.disposition to authenticated;

-- 2. New tables

create table if not exists public.inventory_positions (
  id uuid primary key default gen_random_uuid(),
  variant_id uuid not null references public.products (id) on delete cascade,
  location_id uuid not null references public.stores (id) on delete cascade,
  sublocation_id text,
  disposition public.disposition not null,
  on_hand_quantity integer not null default 0 check (on_hand_quantity >= 0),
  committed_quantity integer not null default 0 check (committed_quantity >= 0),
  updated_at timestamptz not null default now(),
  unique nulls not distinct (variant_id, location_id, sublocation_id, disposition)
);

comment on table public.inventory_positions is 'Per-location disposition-aware stock';

create index if not exists idx_inventory_positions_variant
  on public.inventory_positions (variant_id);
create index if not exists idx_inventory_positions_location
  on public.inventory_positions (location_id);

create table if not exists public.stock_ledger_entries (
  id uuid primary key default gen_random_uuid(),
  variant_id uuid not null references public.products (id),
  location_id uuid not null references public.stores (id),
  disposition public.disposition not null,
  quantity_delta integer not null,
  reason text not null,
  reference_type text,
  actor_id text,
  created_at timestamptz not null default now(),
  correlation_id uuid not null default gen_random_uuid()
);

comment on table public.stock_ledger_entries is 'Append-only inventory change log';

create index if not exists idx_stock_ledger_variant
  on public.stock_ledger_entries (variant_id);
create index if not exists idx_stock_ledger_location
  on public.stock_ledger_entries (location_id);
create index if not exists idx_stock_ledger_created
  on public.stock_ledger_entries (created_at);

-- 3. Migrate product_stock → inventory_positions + stock_ledger_entries

insert into public.inventory_positions (
  variant_id, location_id, sublocation_id, disposition, on_hand_quantity, committed_quantity
)
select
  product_id, store_id, null, 'Prime', quantity, 0
from public.product_stock;

insert into public.stock_ledger_entries (
  variant_id, location_id, disposition, quantity_delta, reason, reference_type, actor_id, correlation_id
)
select
  product_id,
  store_id,
  'Prime',
  quantity,
  'migration_from_product_stock',
  'migration',
  'system',
  gen_random_uuid()
from public.product_stock;

-- 4. Cost-protected products_public view
--    Owned by postgres (BYPASSRLS), default security_invoker=false, so it
--    reads the base table with the view owner''s privileges. It does its
--    own row- and column-level enforcement using auth.uid() and the
--    employee''s role.

create or replace view public.products_public as
select
  p.id,
  p.company_id,
  p.sku,
  p.item_name,
  p.brand,
  case
    when public.current_employee_role()::text in ('owner', 'admin', 'manager')
    then p.cost
    else null
  end as cost,
  p.price,
  p.sale_price,
  p.search_text,
  p.created_at,
  p.updated_at
from public.products p
where public.is_product_visible_by_company(p.company_id);

-- Confirm the view is owned by a BYPASSRLS role (postgres) so it can read
-- the base products table while products_public enforces its own row- and
-- column-level checks for the caller.
alter view public.products_public owner to postgres;

grant select on public.products_public to authenticated;

-- 5. Update search_products() to return the masked view instead of raw products

drop function if exists public.search_products(text);

create or replace function public.search_products(p_query text)
returns setof public.products_public
language sql
stable
security invoker
set search_path = public
as $$
  select *
  from public.products_public p
  where word_similarity(p.search_text, lower(p_query)) > 0.05
  order by word_similarity(p.search_text, lower(p_query)) desc
  limit 20;
$$;

-- 6. Restrict direct products SELECT to privileged roles
--    The products_public view is the canonical path for sales/others.
--    Owner/admin/manager can still direct-select for admin flows like
--    upsert .select('id') and the inventory management page.

drop policy if exists "Products viewable by authenticated users" on public.products;
create policy "Products viewable by owner/admin/manager"
  on public.products for select
  to authenticated
  using (public.current_employee_role()::text in ('owner', 'admin', 'manager'));

-- 7. Atomic manual-adjustment function

create or replace function public.adjust_inventory_position(
  p_variant_id uuid,
  p_location_id uuid,
  p_sublocation_id text,
  p_disposition public.disposition,
  p_new_quantity integer,
  p_reason text,
  p_reference_type text,
  p_actor_id text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_position_id uuid;
  v_old integer;
begin
  if p_new_quantity < 0 then
    raise exception 'Quantity cannot be negative';
  end if;

  select id, on_hand_quantity
  into v_position_id, v_old
  from public.inventory_positions
  where variant_id = p_variant_id
    and location_id = p_location_id
    and sublocation_id is not distinct from p_sublocation_id
    and disposition = p_disposition
  for update;

  if not found then
    insert into public.inventory_positions (
      variant_id, location_id, sublocation_id, disposition, on_hand_quantity, committed_quantity
    ) values (
      p_variant_id, p_location_id, p_sublocation_id, p_disposition, p_new_quantity, 0
    ) returning id into v_position_id;
    v_old := 0;
  else
    update public.inventory_positions
    set on_hand_quantity = p_new_quantity,
        updated_at = now()
    where id = v_position_id;
  end if;

  if p_new_quantity <> v_old then
    insert into public.stock_ledger_entries (
      variant_id, location_id, disposition, quantity_delta, reason, reference_type, actor_id
    ) values (
      p_variant_id, p_location_id, p_disposition,
      p_new_quantity - v_old,
      p_reason,
      p_reference_type,
      p_actor_id
    );
  end if;

  return v_position_id;
end;
$$;

grant execute on function public.adjust_inventory_position(uuid, uuid, text, public.disposition, integer, text, text, text) to authenticated;

-- 8. Prohibit Returned → Prime disposition change

create or replace function public.prevent_returned_to_prime()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.disposition = 'Returned' and new.disposition = 'Prime' then
    raise exception 'A Returned position may not be changed directly to Prime';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_inventory_positions_no_returned_to_prime on public.inventory_positions;
create trigger trg_inventory_positions_no_returned_to_prime
  before update on public.inventory_positions
  for each row
  execute function public.prevent_returned_to_prime();

-- 9. RLS on new tables (company-scoped via location visibility)

alter table public.inventory_positions enable row level security;
alter table public.stock_ledger_entries enable row level security;

drop policy if exists "Inventory positions viewable by authenticated users" on public.inventory_positions;
create policy "Inventory positions viewable by authenticated users"
  on public.inventory_positions for select
  to authenticated
  using (public.is_store_visible(location_id));

-- SELECT only. All writes must go through public.adjust_inventory_position(),
-- which is SECURITY DEFINER and bypasses RLS to enforce the ledger.

drop policy if exists "Stock ledger viewable by authenticated users" on public.stock_ledger_entries;
create policy "Stock ledger viewable by authenticated users"
  on public.stock_ledger_entries for select
  to authenticated
  using (public.is_store_visible(location_id));

-- 10. Grants for authenticated client reads

grant select on public.products_public to authenticated;
grant select on public.inventory_positions to authenticated;
grant select on public.stock_ledger_entries to authenticated;
grant usage on type public.disposition to authenticated;
