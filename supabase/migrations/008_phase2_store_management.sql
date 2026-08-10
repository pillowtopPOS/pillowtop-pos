-- Phase 2: Store Management (structured address/phone + soft delete)

-- 1. Add structured address and soft-delete columns to stores.

do $$
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'stores' and column_name = 'street_address'
  ) then
    alter table public.stores add column street_address text;
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'stores' and column_name = 'city'
  ) then
    alter table public.stores add column city text;
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'stores' and column_name = 'state'
  ) then
    alter table public.stores add column state text;
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'stores' and column_name = 'zip_code'
  ) then
    alter table public.stores add column zip_code text;
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'stores' and column_name = 'phone'
  ) then
    alter table public.stores add column phone text;
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'stores' and column_name = 'is_active'
  ) then
    alter table public.stores add column is_active boolean not null default true;
  end if;
end $$;

-- 2. Ensure existing stores are active.

update public.stores set is_active = true where is_active is null;
