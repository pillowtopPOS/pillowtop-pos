-- m126 verify: delivery grants are owner/admin only.
-- Run in the Supabase SQL editor after installing
-- supabase/migrations/126_delivery_permissions_owner_admin.sql.

\set QUIET on
\pset footer off

-- 1. No manager role grants remain for delivery keys ---------------------
do $$
declare v_count integer;
begin
  select count(*) into v_count
  from public.role_permission_grants
  where permission_key in ('delivery.manage_trucks', 'delivery.manage_calendar')
    and role = 'manager';
  if v_count = 0 then
    raise notice 'OK: no manager delivery grants remain';
  else
    raise notice 'FAIL: % manager delivery grant rows still exist', v_count;
  end if;
end $$;

-- 2. Owner and admin grants still present for every company ---------------
do $$
declare v_missing integer;
begin
  select count(*) into v_missing
  from public.companies c
  where not exists (
    select 1 from public.role_permission_grants g
    where g.company_id = c.id and g.role = 'owner'
      and g.permission_key = 'delivery.manage_trucks'
  ) or not exists (
    select 1 from public.role_permission_grants g
    where g.company_id = c.id and g.role = 'admin'
      and g.permission_key = 'delivery.manage_calendar'
  );
  if v_missing = 0 then
    raise notice 'OK: owner/admin delivery grants intact';
  else
    raise notice 'FAIL: % companies missing owner/admin delivery grants', v_missing;
  end if;
end $$;

-- 3. Seed function body no longer grants manager --------------------------
do $$
declare v_src text;
begin
  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'trg_seed_delivery_permissions';
  if v_src like '%''manager''%' then
    raise notice 'FAIL: seed function still grants manager';
  else
    raise notice 'OK: seed function grants owner/admin only';
  end if;
end $$;

-- 4. Behavioral check (rollback):
--    begin;
--    insert into public.companies (name) values ('m126 test co');
--    select role, permission_key from public.role_permission_grants
--      where company_id = (select id from public.companies where name = 'm126 test co')
--        and permission_key like 'delivery.%';
--    rollback;
--    Expect: 4 rows — owner/admin x manage_trucks/manage_calendar. No manager.
