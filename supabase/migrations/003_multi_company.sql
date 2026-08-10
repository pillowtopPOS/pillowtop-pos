-- Multi-company support: companies table, store company_id, and RLS scoping by company

-- 1. Companies table

create table if not exists public.companies (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_at timestamptz not null default now()
);

comment on table public.companies is 'Top-level tenants for multi-company support';

alter table public.companies enable row level security;

drop policy if exists "Companies viewable by authenticated users" on public.companies;
create policy "Companies viewable by authenticated users"
  on public.companies for select
  to authenticated
  using (true);

-- 2. Add company_id to stores and backfill existing data

alter table public.stores
  add column if not exists company_id uuid references public.companies (id);

-- Create a default company for existing data and backfill all stores
insert into public.companies (name) values ('PillowTop Demo')
  on conflict do nothing;

update public.stores
  set company_id = (select id from public.companies where name = 'PillowTop Demo')
  where company_id is null;

alter table public.stores
  alter column company_id set not null;

create index if not exists idx_stores_company_id on public.stores (company_id);

-- 3. Replace visibility helpers to scope by company

create or replace function public.is_store_visible(check_store_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  my_role text;
  my_company_id uuid;
  active_store_id uuid;
begin
  select
    e.role,
    s.company_id,
    (auth.jwt() -> 'user_metadata' ->> 'active_store_id')::uuid
  into my_role, my_company_id, active_store_id
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid();

  if not found then
    return false;
  end if;

  if my_role in ('owner','manager') then
    return exists (
      select 1 from public.stores
      where id = check_store_id
        and company_id = my_company_id
    );
  end if;

  return active_store_id = check_store_id
    and exists (
      select 1 from public.stores
      where id = check_store_id
        and company_id = my_company_id
    );
end;
$$;

create or replace function public.is_journey_visible(check_journey_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  return exists (
    select 1 from public.sleep_journeys
    where id = check_journey_id
      and public.is_store_visible(store_id)
  );
end;
$$;

create or replace function public.is_customer_visible(check_customer_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  return exists (
    select 1 from public.sleep_journeys
    where customer_id = check_customer_id
      and public.is_journey_visible(id)
  );
end;
$$;

create or replace function public.is_employee_visible(check_employee_id uuid)
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
    select 1 from public.employees e
    join public.stores s on s.id = e.home_store_id
    where e.id = check_employee_id
      and s.company_id = my_company_id
  );
end;
$$;

-- 4. Update employees policy to scope by company

drop policy if exists "Employees viewable by authenticated users" on public.employees;
create policy "Employees viewable by authenticated users"
  on public.employees for select
  to authenticated
  using (
    auth_user_id = auth.uid()
    or public.is_employee_visible(id)
  );

-- 5. Make sure journey_events inserts are scoped to visible journeys

drop policy if exists "Journey events insertable by authenticated users" on public.journey_events;
create policy "Journey events insertable by authenticated users"
  on public.journey_events for insert
  to authenticated
  with check (
    public.is_journey_visible(journey_id)
  );
