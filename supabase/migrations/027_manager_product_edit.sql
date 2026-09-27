-- PillowTop POS: separate manager toggle for product catalog editing

-- 1. New company-level setting (default off for all, including existing rows)

alter table public.companies
  add column if not exists managers_can_edit_products boolean not null default false;

-- 2. Re-create products INSERT/UPDATE RLS so manager writes are gated by the
--    new setting. Owner and admin are always allowed.

drop policy if exists "Products insertable by owner/admin/manager" on public.products;

create policy "Products insertable by owner/admin/manager"
  on public.products for insert
  to authenticated
  with check (
    public.current_employee_role()::text in ('owner', 'admin')
    or (
      public.current_employee_role()::text = 'manager'
      and public.is_product_visible_by_company(company_id)
      and (select coalesce(managers_can_edit_products, false)
           from public.companies
           where id = company_id)
    )
  );

drop policy if exists "Products updatable by owner/admin/manager" on public.products;

create policy "Products updatable by owner/admin/manager"
  on public.products for update
  to authenticated
  using (
    public.current_employee_role()::text in ('owner', 'admin')
    or (
      public.current_employee_role()::text = 'manager'
      and public.is_product_visible_by_company(company_id)
      and (select coalesce(managers_can_edit_products, false)
           from public.companies
           where id = company_id)
    )
  )
  with check (
    public.current_employee_role()::text in ('owner', 'admin')
    or (
      public.current_employee_role()::text = 'manager'
      and public.is_product_visible_by_company(company_id)
      and (select coalesce(managers_can_edit_products, false)
           from public.companies
           where id = company_id)
    )
  );
