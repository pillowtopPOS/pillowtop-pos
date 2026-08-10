-- PillowTop POS Phase 3: Inventory (products, stock, fuzzy search)

-- 1. Enable trigram-based fuzzy search

create extension if not exists pg_trgm;

-- 2. Shared company-scoped catalog

create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete restrict,
  sku text not null,
  item_name text not null,
  brand text,
  cost numeric,
  price numeric,
  sale_price numeric,
  search_text text generated always as (
    lower(coalesce(item_name, '') || ' ' || coalesce(brand, '') || ' ' || coalesce(sku, ''))
  ) stored,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (company_id, sku)
);

comment on table public.products is 'Shared company-wide product catalog';

create index if not exists idx_products_company on public.products (company_id);
create index if not exists idx_products_sku on public.products (sku);
create index if not exists idx_products_search_trgm
  on public.products using gin (search_text gin_trgm_ops);

-- 3. Per-store stock levels

create table if not exists public.product_stock (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products (id) on delete cascade,
  store_id uuid not null references public.stores (id) on delete cascade,
  quantity integer not null default 0,
  updated_at timestamptz not null default now(),
  unique (product_id, store_id)
);

comment on table public.product_stock is 'Per-store product quantity on hand';

create index if not exists idx_product_stock_product on public.product_stock (product_id);
create index if not exists idx_product_stock_store on public.product_stock (store_id);

-- 4. Optional product link on sleep journeys (product_summary stays for custom items)

alter table public.sleep_journeys
  add column if not exists product_id uuid references public.products (id) on delete set null;

-- 5. Helper: is a company visible to the current user?

create or replace function public.is_product_visible_by_company(product_company_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  return exists (
    select 1
    from public.stores s
    where s.company_id = product_company_id
      and public.is_store_visible(s.id)
  );
end;
$$;

-- 6. RLS

alter table public.products enable row level security;

drop policy if exists "Products viewable by authenticated users" on public.products;
create policy "Products viewable by authenticated users"
  on public.products for select
  to authenticated
  using (public.is_product_visible_by_company(company_id));

drop policy if exists "Products insertable by authenticated users" on public.products;
create policy "Products insertable by authenticated users"
  on public.products for insert
  to authenticated
  with check (public.is_product_visible_by_company(company_id));

drop policy if exists "Products updatable by authenticated users" on public.products;
create policy "Products updatable by authenticated users"
  on public.products for update
  to authenticated
  using (public.is_product_visible_by_company(company_id))
  with check (public.is_product_visible_by_company(company_id));

alter table public.product_stock enable row level security;

drop policy if exists "Product stock viewable by authenticated users" on public.product_stock;
create policy "Product stock viewable by authenticated users"
  on public.product_stock for select
  to authenticated
  using (public.is_store_visible(store_id));

drop policy if exists "Product stock insertable by authenticated users" on public.product_stock;
create policy "Product stock insertable by authenticated users"
  on public.product_stock for insert
  to authenticated
  with check (public.is_store_visible(store_id));

drop policy if exists "Product stock updatable by authenticated users" on public.product_stock;
create policy "Product stock updatable by authenticated users"
  on public.product_stock for update
  to authenticated
  using (public.is_store_visible(store_id))
  with check (public.is_store_visible(store_id));

-- 7. Fuzzy catalog search

create or replace function public.search_products(p_query text)
returns setof public.products
language sql
stable
security invoker
set search_path = public
as $$
  select p.*
  from public.products p
  where p.company_id = (
    select s.company_id
    from public.employees e
    join public.stores s on s.id = e.home_store_id
    where e.auth_user_id = auth.uid()
  )
    and word_similarity(p.search_text, lower(p_query)) > 0.15
  order by word_similarity(p.search_text, lower(p_query)) desc
  limit 20;
$$;
