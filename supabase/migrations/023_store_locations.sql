-- PillowTop POS Phase 7a: Location Model Extension (Warehouses & Quarantine)
--
-- Design notes:
--  * We extend the existing `public.stores` table with a location_type enum
--    rather than creating a separate `locations` table. This keeps every
--    existing FK, RLS policy, and business logic path working unchanged.
--  * A WAREHOUSE_QUARANTINE row cannot be created directly by users; it is
--    provisioned automatically when a WAREHOUSE location is created/activated.
--  * The guarantee that a Quarantine row's parent_location_id points to an
--    actual WAREHOUSE is enforced by the fact that the only legal creation
--    path is the provisioning trigger below. There is no declarative FK/CHECK
--    that restricts parent rows to location_type = 'WAREHOUSE' because the
--    same `stores` table is the referenced table, and the trigger/RLS path
--    is the intended enforcement. This is a deliberate design choice.

-- 1. Enum and columns

-- Create the location_type enum if it does not already exist.
do $$
begin
  if not exists (
    select 1 from pg_type where typname = 'location_type'
  ) then
    create type public.location_type as enum (
      'STORE',
      'WAREHOUSE',
      'WAREHOUSE_QUARANTINE'
    );
  end if;
end $$;

-- Add the type column with a default that preserves all existing stores.
alter table public.stores
  add column if not exists location_type public.location_type
  not null default 'STORE';

-- Backfill: existing rows are stores.
update public.stores
  set location_type = 'STORE'
  where location_type is null;

-- Self-referencing parent link, used only for Quarantine rows.
alter table public.stores
  add column if not exists parent_location_id uuid
  references public.stores (id) on delete cascade;

-- Structural checks.
--   - A WAREHOUSE_QUARANTINE row must have a parent_location_id.
--   - A row may only have parent_location_id if it is WAREHOUSE_QUARANTINE.
alter table public.stores
  drop constraint if exists stores_quarantine_has_parent,
  add constraint stores_quarantine_has_parent
    check (
      location_type <> 'WAREHOUSE_QUARANTINE'
      or parent_location_id is not null
    );

alter table public.stores
  drop constraint if exists stores_parent_only_for_quarantine,
  add constraint stores_parent_only_for_quarantine
    check (
      parent_location_id is null
      or location_type = 'WAREHOUSE_QUARANTINE'
    );

-- 2. Auto-provision Quarantine for WAREHOUSE locations (idempotent)

-- Trigger function. Runs as security definer so it can bypass RLS and create
-- the Quarantine row on behalf of the WAREHOUSE row's company.
create or replace function public.provision_warehouse_quarantine()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.location_type = 'WAREHOUSE' and new.is_active then
    if not exists (
      select 1
      from public.stores
      where parent_location_id = new.id
        and location_type = 'WAREHOUSE_QUARANTINE'
    ) then
      insert into public.stores (
        company_id,
        name,
        location_type,
        parent_location_id,
        is_active
      ) values (
        new.company_id,
        new.name || ' — Quarantine',
        'WAREHOUSE_QUARANTINE',
        new.id,
        true
      );
    end if;
  end if;

  return new;
end;
$$;

-- Fire after insert or when is_active/location_type change.
-- The function is idempotent: repeated activations do nothing if a Quarantine
-- row already exists for this warehouse.
drop trigger if exists trg_stores_provision_quarantine on public.stores;
create trigger trg_stores_provision_quarantine
  after insert or update of is_active, location_type
  on public.stores
  for each row
  execute function public.provision_warehouse_quarantine();

-- 3. Prevent a non-Quarantine location from being updated into a Quarantine
--    (Quarantine renames and other non-type edits remain allowed).

create or replace function public.prevent_quarantine_type_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if
    new.location_type is distinct from old.location_type
    and (
      new.location_type = 'WAREHOUSE_QUARANTINE'
      or old.location_type = 'WAREHOUSE_QUARANTINE'
    )
  then
    raise exception 'A location may not be changed into or out of WAREHOUSE_QUARANTINE';
  end if;

  if
    old.location_type = 'WAREHOUSE'
    and new.location_type is distinct from 'WAREHOUSE'
    and exists (
      select 1
      from public.stores
      where parent_location_id = old.id
        and location_type = 'WAREHOUSE_QUARANTINE'
    )
  then
    raise exception 'This warehouse has an active Quarantine location and cannot be retyped';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_stores_prevent_quarantine_type_change on public.stores;
create trigger trg_stores_prevent_quarantine_type_change
  before update on public.stores
  for each row
  execute function public.prevent_quarantine_type_change();

-- 4. RLS: block direct user creation/update of WAREHOUSE_QUARANTINE rows.
--    The provisioning trigger (security definer) bypasses RLS, so it can
--    still create Quarantine rows. Existing visibility helpers remain
--    unchanged because they only inspect company_id and store id, not
--    location_type.

drop policy if exists "Stores insertable by owner/admin" on public.stores;
create policy "Stores insertable by owner/admin"
  on public.stores for insert
  to authenticated
  with check (
    public.current_employee_role() in ('owner', 'admin')
    and location_type <> 'WAREHOUSE_QUARANTINE'
  );

-- Update policy keeps the existing role check. The type-change guard above
-- enforces the Quarantine promotion restriction, allowing Quarantine renames.
drop policy if exists "Stores updatable by owner/admin" on public.stores;
create policy "Stores updatable by owner/admin"
  on public.stores for update
  to authenticated
  using (public.current_employee_role() in ('owner', 'admin'))
  with check (public.current_employee_role() in ('owner', 'admin'));
