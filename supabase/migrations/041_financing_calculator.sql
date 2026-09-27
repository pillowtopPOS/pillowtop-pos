-- 041 Financing Calculator & Accessory Suggestion Tool
-- Tables: product_categories, financing_tiers, accessory_categories,
--         accessory_pins, accessory_bundles, accessory_bundle_components
-- Also adds category_id to products and updates products_public.

-- ============================================================
-- 0. is_own_company() helper
--    Direct company-id check: employee → home_store → company_id.
--    More efficient than is_product_visible_by_company() for tables
--    that carry company_id directly (no need to enumerate stores).
-- ============================================================

create or replace function public.is_own_company(check_company_id uuid)
returns boolean
language plpgsql
security definer
stable
set search_path = public
as $$
begin
  return exists (
    select 1
    from public.employees e
    join public.stores s on s.id = e.home_store_id
    where e.auth_user_id = auth.uid()
      and s.company_id = check_company_id
  );
end;
$$;

-- ============================================================
-- 1. product_categories
-- ============================================================

create table if not exists public.product_categories (
  id         uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  name       text not null,
  created_at timestamptz not null default now()
);

alter table public.product_categories enable row level security;

create policy "Product categories viewable by company"
  on public.product_categories for select
  to authenticated
  using (public.is_own_company(company_id));

create policy "Product categories insertable by owner/admin"
  on public.product_categories for insert
  to authenticated
  with check (
    public.current_employee_role()::text in ('owner', 'admin')
    and public.is_own_company(company_id)
  );

create policy "Product categories updatable by owner/admin"
  on public.product_categories for update
  to authenticated
  using (
    public.current_employee_role()::text in ('owner', 'admin')
    and public.is_own_company(company_id)
  )
  with check (
    public.current_employee_role()::text in ('owner', 'admin')
    and public.is_own_company(company_id)
  );

create policy "Product categories deletable by owner/admin"
  on public.product_categories for delete
  to authenticated
  using (
    public.current_employee_role()::text in ('owner', 'admin')
    and public.is_own_company(company_id)
  );

grant select, insert, update, delete on public.product_categories to authenticated;

-- ============================================================
-- 2. Add category_id to products
-- ============================================================

alter table public.products
  add column if not exists category_id uuid references public.product_categories (id)
  on delete set null;

-- Update products_public view to expose category_id.
-- This is a CREATE OR REPLACE on the existing view from 024_inventory_positions.sql.
-- The only change is the addition of p.category_id.
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
  p.updated_at,
  p.category_id
from public.products p
where public.is_product_visible_by_company(p.company_id);

alter view public.products_public owner to postgres;

-- search_products() returns setof products_public, so it must be recreated
-- after the view is replaced (its return type now includes category_id).
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

-- ============================================================
-- 3. financing_tiers
-- ============================================================

create table if not exists public.financing_tiers (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references public.companies (id) on delete cascade,
  min_price    numeric not null,
  max_price    numeric,            -- null = unbounded upper end (∞)
  term_lengths integer[] not null, -- e.g. {6,12,18,24}
  sort_order   integer not null default 0,
  created_at   timestamptz not null default now()
);

alter table public.financing_tiers enable row level security;

create policy "Financing tiers viewable by company"
  on public.financing_tiers for select
  to authenticated
  using (public.is_own_company(company_id));

create policy "Financing tiers insertable by owner/admin"
  on public.financing_tiers for insert
  to authenticated
  with check (
    public.current_employee_role()::text in ('owner', 'admin')
    and public.is_own_company(company_id)
  );

create policy "Financing tiers updatable by owner/admin"
  on public.financing_tiers for update
  to authenticated
  using (
    public.current_employee_role()::text in ('owner', 'admin')
    and public.is_own_company(company_id)
  )
  with check (
    public.current_employee_role()::text in ('owner', 'admin')
    and public.is_own_company(company_id)
  );

create policy "Financing tiers deletable by owner/admin"
  on public.financing_tiers for delete
  to authenticated
  using (
    public.current_employee_role()::text in ('owner', 'admin')
    and public.is_own_company(company_id)
  );

grant select, insert, update, delete on public.financing_tiers to authenticated;

-- ============================================================
-- 3a. Financing-tier validation trigger
--
-- Enforces two invariants for every company:
--   (a) Tiers are contiguous and non-overlapping from $0 → ∞.
--       Specifically: sort tiers by sort_order; the first tier must
--       start at 0, the last must have max_price IS NULL (∞), and
--       each interior boundary must match exactly (prev.max_price =
--       next.min_price).
--   (b) Each tier's term_lengths is a superset of every lower tier's
--       term_lengths for that company. (Cumulative / "unlocked-terms"
--       guarantee.)
--
-- The trigger fires AFTER INSERT, UPDATE, or DELETE on financing_tiers
-- as a CONSTRAINT TRIGGER deferred to statement end, so bulk saves in
-- a single transaction are validated as a whole.
-- ============================================================

create or replace function public.validate_financing_tiers()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_id  uuid;
  v_tier        record;
  v_prev_max    numeric;
  v_prev_terms  integer[];
  v_count       integer;
  v_i           integer;
  v_is_first    boolean;
begin
  -- Determine the company affected.  For DELETE the row is in OLD.
  if tg_op = 'DELETE' then
    v_company_id := old.company_id;
  else
    v_company_id := new.company_id;
  end if;

  -- Count tiers.  Zero is valid (company hasn't configured financing).
  select count(*) into v_count
  from public.financing_tiers
  where company_id = v_company_id;

  if v_count = 0 then
    return null;
  end if;

  -- Single pass: contiguity, non-overlap, cumulative-terms.
  -- FOR ... IN SELECT gives us proper named-field access on v_tier.
  v_i        := 0;
  v_prev_max := null;
  v_prev_terms := null;
  v_is_first := true;

  for v_tier in
    select id, min_price, max_price, term_lengths, sort_order
    from public.financing_tiers
    where company_id = v_company_id
    order by sort_order
  loop
    v_i := v_i + 1;

    -- (a-1) First tier must start at 0
    if v_is_first then
      if v_tier.min_price <> 0 then
        raise exception 'Financing tiers: the lowest tier must start at $0 (found min_price = %)',
          v_tier.min_price;
      end if;
      v_is_first := false;
    else
      -- (a-2) Previous tier must have a bounded upper end
      if v_prev_max is null then
        raise exception 'Financing tiers: only the last tier may have an unlimited upper bound';
      end if;
      -- (a-3) Contiguity: this tier's min must equal previous tier's max
      if v_tier.min_price <> v_prev_max then
        raise exception 'Financing tiers: gap or overlap between tiers — tier ending at % followed by tier starting at %',
          v_prev_max, v_tier.min_price;
      end if;
    end if;

    -- (b) Cumulative term_lengths: each tier must contain all terms
    --     from every lower tier.
    if v_prev_terms is not null then
      if not v_prev_terms <@ v_tier.term_lengths then
        raise exception 'Financing tiers: tier at sort_order % must include all term lengths from lower tiers (missing terms from previous tier)',
          v_tier.sort_order;
      end if;
    end if;

    v_prev_max   := v_tier.max_price;
    v_prev_terms := v_tier.term_lengths;
  end loop;

  -- (a-4) Last tier must be unbounded
  if v_prev_max is not null then
    raise exception 'Financing tiers: the highest tier must have no upper limit (max_price should be null)';
  end if;

  return null; -- AFTER trigger, return value is ignored
end;
$$;

drop trigger if exists trg_validate_financing_tiers on public.financing_tiers;
create constraint trigger trg_validate_financing_tiers
  after insert or update or delete
  on public.financing_tiers
  deferrable initially deferred
  for each row
  execute function public.validate_financing_tiers();

-- ============================================================
-- 4. accessory_match_mode enum
-- ============================================================

do $$
begin
  if not exists (select 1 from pg_type where typname = 'accessory_match_mode' and typtype = 'e') then
    create type public.accessory_match_mode as enum ('auto_rank', 'manual_pin', 'show_all');
  end if;
end $$;

grant usage on type public.accessory_match_mode to authenticated;

-- ============================================================
-- 5. accessory_categories
-- ============================================================

create table if not exists public.accessory_categories (
  id                       uuid primary key default gen_random_uuid(),
  company_id               uuid not null references public.companies (id) on delete cascade,
  category_id              uuid not null references public.product_categories (id) on delete cascade,
  enabled_for_suggestions  boolean not null default true,
  default_qty              integer not null default 1,
  sort_order               integer not null default 0,
  match_mode               public.accessory_match_mode not null default 'auto_rank',
  created_at               timestamptz not null default now()
);

alter table public.accessory_categories enable row level security;

create policy "Accessory categories viewable by company"
  on public.accessory_categories for select
  to authenticated
  using (public.is_own_company(company_id));

create policy "Accessory categories insertable by owner/admin"
  on public.accessory_categories for insert
  to authenticated
  with check (
    public.current_employee_role()::text in ('owner', 'admin')
    and public.is_own_company(company_id)
  );

create policy "Accessory categories updatable by owner/admin"
  on public.accessory_categories for update
  to authenticated
  using (
    public.current_employee_role()::text in ('owner', 'admin')
    and public.is_own_company(company_id)
  )
  with check (
    public.current_employee_role()::text in ('owner', 'admin')
    and public.is_own_company(company_id)
  );

create policy "Accessory categories deletable by owner/admin"
  on public.accessory_categories for delete
  to authenticated
  using (
    public.current_employee_role()::text in ('owner', 'admin')
    and public.is_own_company(company_id)
  );

grant select, insert, update, delete on public.accessory_categories to authenticated;

-- ============================================================
-- 6. accessory_pins
-- ============================================================

create table if not exists public.accessory_pins (
  id                     uuid primary key default gen_random_uuid(),
  company_id             uuid not null references public.companies (id) on delete cascade,
  accessory_category_id  uuid not null references public.accessory_categories (id) on delete cascade,
  financing_tier_id      uuid not null references public.financing_tiers (id) on delete cascade,
  product_id             uuid not null references public.products (id) on delete cascade,
  created_at             timestamptz not null default now(),
  unique (accessory_category_id, financing_tier_id)
);

alter table public.accessory_pins enable row level security;

create policy "Accessory pins viewable by company"
  on public.accessory_pins for select
  to authenticated
  using (public.is_own_company(company_id));

create policy "Accessory pins insertable by owner/admin"
  on public.accessory_pins for insert
  to authenticated
  with check (
    public.current_employee_role()::text in ('owner', 'admin')
    and public.is_own_company(company_id)
  );

create policy "Accessory pins updatable by owner/admin"
  on public.accessory_pins for update
  to authenticated
  using (
    public.current_employee_role()::text in ('owner', 'admin')
    and public.is_own_company(company_id)
  )
  with check (
    public.current_employee_role()::text in ('owner', 'admin')
    and public.is_own_company(company_id)
  );

create policy "Accessory pins deletable by owner/admin"
  on public.accessory_pins for delete
  to authenticated
  using (
    public.current_employee_role()::text in ('owner', 'admin')
    and public.is_own_company(company_id)
  );

grant select, insert, update, delete on public.accessory_pins to authenticated;

-- ============================================================
-- 7. accessory_bundles
-- ============================================================

create table if not exists public.accessory_bundles (
  id         uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  name       text not null,
  created_at timestamptz not null default now()
);

alter table public.accessory_bundles enable row level security;

create policy "Accessory bundles viewable by company"
  on public.accessory_bundles for select
  to authenticated
  using (public.is_own_company(company_id));

create policy "Accessory bundles insertable by owner/admin"
  on public.accessory_bundles for insert
  to authenticated
  with check (
    public.current_employee_role()::text in ('owner', 'admin')
    and public.is_own_company(company_id)
  );

create policy "Accessory bundles updatable by owner/admin"
  on public.accessory_bundles for update
  to authenticated
  using (
    public.current_employee_role()::text in ('owner', 'admin')
    and public.is_own_company(company_id)
  )
  with check (
    public.current_employee_role()::text in ('owner', 'admin')
    and public.is_own_company(company_id)
  );

create policy "Accessory bundles deletable by owner/admin"
  on public.accessory_bundles for delete
  to authenticated
  using (
    public.current_employee_role()::text in ('owner', 'admin')
    and public.is_own_company(company_id)
  );

grant select, insert, update, delete on public.accessory_bundles to authenticated;

-- ============================================================
-- 8. accessory_bundle_components
-- ============================================================

create table if not exists public.accessory_bundle_components (
  id                    uuid primary key default gen_random_uuid(),
  bundle_id             uuid not null references public.accessory_bundles (id) on delete cascade,
  accessory_category_id uuid not null references public.accessory_categories (id) on delete cascade,
  unique (bundle_id, accessory_category_id)
);

alter table public.accessory_bundle_components enable row level security;

-- For bundle_components we scope via the parent bundle's company_id.
create policy "Bundle components viewable by company"
  on public.accessory_bundle_components for select
  to authenticated
  using (
    exists (
      select 1 from public.accessory_bundles b
      where b.id = bundle_id
        and public.is_own_company(b.company_id)
    )
  );

create policy "Bundle components insertable by owner/admin"
  on public.accessory_bundle_components for insert
  to authenticated
  with check (
    public.current_employee_role()::text in ('owner', 'admin')
    and exists (
      select 1 from public.accessory_bundles b
      where b.id = bundle_id
        and public.is_own_company(b.company_id)
    )
  );

create policy "Bundle components updatable by owner/admin"
  on public.accessory_bundle_components for update
  to authenticated
  using (
    public.current_employee_role()::text in ('owner', 'admin')
    and exists (
      select 1 from public.accessory_bundles b
      where b.id = bundle_id
        and public.is_own_company(b.company_id)
    )
  )
  with check (
    public.current_employee_role()::text in ('owner', 'admin')
    and exists (
      select 1 from public.accessory_bundles b
      where b.id = bundle_id
        and public.is_own_company(b.company_id)
    )
  );

create policy "Bundle components deletable by owner/admin"
  on public.accessory_bundle_components for delete
  to authenticated
  using (
    public.current_employee_role()::text in ('owner', 'admin')
    and exists (
      select 1 from public.accessory_bundles b
      where b.id = bundle_id
        and public.is_own_company(b.company_id)
    )
  );

grant select, insert, update, delete on public.accessory_bundle_components to authenticated;
