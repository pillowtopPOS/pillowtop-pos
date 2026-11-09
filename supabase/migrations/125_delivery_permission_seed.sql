-- PillowTop POS m125: seed delivery.manage_trucks and
-- delivery.manage_calendar for owner/admin/manager on NEW companies.
--
-- Migration 124 backfilled existing companies only. Every other feature
-- seeds its grants through an AFTER INSERT trigger on companies (see
-- 101_unit_foundations.sql, 105_receive_po_permission.sql); this adds the
-- same for delivery so companies created later get the defaults.
--
-- Safe to run twice: drop trigger if exists + on conflict do nothing.

create or replace function public.trg_seed_delivery_permissions()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.role_permission_grants (company_id, role, permission_key)
  values
    (new.id, 'owner',   'delivery.manage_trucks'),
    (new.id, 'admin',   'delivery.manage_trucks'),
    (new.id, 'manager', 'delivery.manage_trucks'),
    (new.id, 'owner',   'delivery.manage_calendar'),
    (new.id, 'admin',   'delivery.manage_calendar'),
    (new.id, 'manager', 'delivery.manage_calendar')
  on conflict do nothing;
  return new;
end;
$$;

revoke execute on function public.trg_seed_delivery_permissions()
  from authenticated, anon, public;

drop trigger if exists trg_companies_seed_delivery_permissions on public.companies;
create trigger trg_companies_seed_delivery_permissions
after insert on public.companies
for each row execute function public.trg_seed_delivery_permissions();
