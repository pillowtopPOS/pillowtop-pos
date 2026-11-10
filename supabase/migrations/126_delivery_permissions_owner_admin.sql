-- PillowTop POS m126: delivery calendar permissions are owner/admin only
-- by default. Store managers and other roles get them only via an
-- explicit grant (role grid or per-employee override).
--
-- 1. Remove the manager role grants seeded by 124/125 for every company.
--    Per-employee overrides are untouched; owner/admin grants stay.
-- 2. Replace trg_seed_delivery_permissions so NEW companies get only
--    owner and admin.
-- Safe to run twice.

delete from public.role_permission_grants
where permission_key in ('delivery.manage_trucks', 'delivery.manage_calendar')
  and role = 'manager';

create or replace function public.trg_seed_delivery_permissions()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.role_permission_grants (company_id, role, permission_key)
  values
    (new.id, 'owner', 'delivery.manage_trucks'),
    (new.id, 'admin', 'delivery.manage_trucks'),
    (new.id, 'owner', 'delivery.manage_calendar'),
    (new.id, 'admin', 'delivery.manage_calendar')
  on conflict do nothing;
  return new;
end;
$$;

revoke execute on function public.trg_seed_delivery_permissions()
  from authenticated, anon, public;
