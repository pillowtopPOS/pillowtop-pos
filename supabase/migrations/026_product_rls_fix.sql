-- PillowTop POS: restrict products table writes to privileged roles

-- Ensure authenticated can write products when the RLS policy allows it.
grant select, insert, update on public.products to authenticated;

-- Insert: only owner, admin, or manager

drop policy if exists "Products insertable by authenticated users" on public.products;
drop policy if exists "Products insertable by owner/admin/manager" on public.products;
create policy "Products insertable by owner/admin/manager"
  on public.products for insert
  to authenticated
  with check (public.current_employee_role()::text in ('owner', 'admin', 'manager'));

-- Update: only owner, admin, or manager

drop policy if exists "Products updatable by authenticated users" on public.products;
drop policy if exists "Products updatable by owner/admin/manager" on public.products;
create policy "Products updatable by owner/admin/manager"
  on public.products for update
  to authenticated
  using (public.current_employee_role()::text in ('owner', 'admin', 'manager'))
  with check (public.current_employee_role()::text in ('owner', 'admin', 'manager'));

-- Direct products SELECT is also restricted to privileged roles.
-- (products_public view remains the read path for sales/others.)

drop policy if exists "Products viewable by authenticated users" on public.products;
drop policy if exists "Products viewable by owner/admin/manager" on public.products;
create policy "Products viewable by owner/admin/manager"
  on public.products for select
  to authenticated
  using (public.current_employee_role()::text in ('owner', 'admin', 'manager'));
