-- m125 verify: delivery grants seed for NEW companies.
-- Run in the Supabase SQL editor after installing
-- supabase/migrations/125_delivery_permission_seed.sql.

\set QUIET on
\pset footer off

-- 1. Trigger exists -------------------------------------------------------
do $$
begin
  if exists (
    select 1 from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = 'companies'
      and t.tgname = 'trg_companies_seed_delivery_permissions'
      and not t.tgisinternal
  ) then
    raise notice 'OK: companies insert trigger exists';
  else
    raise notice 'FAIL: trg_companies_seed_delivery_permissions missing';
  end if;
end $$;

-- 2. Seed function not client-executable ---------------------------------
do $$
begin
  if has_function_privilege(
       'authenticated',
       'public.trg_seed_delivery_permissions()',
       'execute'
     ) then
    raise notice 'FAIL: trg_seed_delivery_permissions executable by authenticated';
  else
    raise notice 'OK: seed function not client-executable';
  end if;
end $$;

-- 3. Behavioral check — run in a transaction you ROLL BACK:
--    begin;
--    insert into public.companies (name) values ('m125 test co');
--    -- expect 6 role_permission_grants rows for the new company id
--    select permission_key, role from public.role_permission_grants
--      where company_id = (select id from public.companies where name = 'm125 test co');
--    rollback;
--    Expect: delivery.manage_trucks + delivery.manage_calendar for
--    owner, admin, manager (6 rows).
