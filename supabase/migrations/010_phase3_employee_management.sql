-- Phase 3: Employee Management
-- Structured name columns, employment metadata, soft delete, and owner/admin write policies.

-- 1. Structured name columns.
--    `name` becomes a generated column so it always tracks first/last name.

do $$
declare
  has_name boolean;
  name_is_generated boolean;
begin
  select
    count(*) > 0,
    coalesce(bool_or(is_generated = 'ALWAYS'), false)
  into has_name, name_is_generated
  from information_schema.columns
  where table_schema = 'public'
    and table_name = 'employees'
    and column_name = 'name';

  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'employees' and column_name = 'first_name'
  ) then
    alter table public.employees add column first_name text;
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'employees' and column_name = 'last_name'
  ) then
    alter table public.employees add column last_name text;
  end if;

  -- Backfill first/last from the legacy free-text name before replacing it.
  if has_name and not name_is_generated then
    update public.employees
    set
      first_name = coalesce(first_name, nullif(split_part(name, ' ', 1), '')),
      last_name = coalesce(
        last_name,
        nullif(trim(substring(name from position(' ' in name) + 1)), '')
      )
    where name is not null
      and (first_name is null or last_name is null);
  end if;

  update public.employees
  set first_name = 'Unknown'
  where first_name is null or btrim(first_name) = '';

  alter table public.employees alter column first_name set not null;

  if has_name and not name_is_generated then
    alter table public.employees drop column name;
    has_name := false;
  end if;

  if not has_name then
    alter table public.employees
      add column name text
      generated always as (
        btrim(first_name || ' ' || coalesce(last_name, ''))
      ) stored;
  end if;
end $$;

-- 2. Employment metadata and soft delete.

alter table public.employees add column if not exists birthday date;
alter table public.employees add column if not exists hire_date date;
alter table public.employees add column if not exists is_active boolean not null default true;

update public.employees set is_active = true where is_active is null;

-- 3. Owner/admin may create and update employees within their own company.
--    Employees are scoped to a company through their home store.

create or replace function public.is_store_in_my_company(check_store_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  my_company_id uuid;
begin
  select s.company_id into my_company_id
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid();

  if not found then
    return false;
  end if;

  return exists (
    select 1 from public.stores
    where id = check_store_id
      and company_id = my_company_id
  );
end;
$$;

drop policy if exists "Employees insertable by owner/admin" on public.employees;
create policy "Employees insertable by owner/admin"
  on public.employees for insert
  to authenticated
  with check (
    public.current_employee_role() in ('owner', 'admin')
    and public.is_store_in_my_company(home_store_id)
  );

drop policy if exists "Employees updatable by owner/admin" on public.employees;
create policy "Employees updatable by owner/admin"
  on public.employees for update
  to authenticated
  using (
    public.current_employee_role() in ('owner', 'admin')
    and public.is_employee_visible(id)
  )
  with check (
    public.current_employee_role() in ('owner', 'admin')
    and public.is_store_in_my_company(home_store_id)
  );

create index if not exists idx_employees_is_active on public.employees (is_active);
