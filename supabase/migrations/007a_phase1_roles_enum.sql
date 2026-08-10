-- Phase 1, part A: employee_role enum values
-- Run this first, separately, because Postgres does not allow a newly-added enum value
-- to be used in the same transaction in which it was created.

do $$
begin
  if not exists (select 1 from pg_type where typname = 'employee_role' and typtype = 'e') then
    create type public.employee_role as enum ('owner', 'admin', 'employee');
  end if;

  if not exists (
    select 1
    from pg_enum e
    join pg_type t on e.enumtypid = t.oid
    where t.typname = 'employee_role'
      and e.enumlabel = 'admin'
  ) then
    alter type public.employee_role add value 'admin';
  end if;

  if not exists (
    select 1
    from pg_enum e
    join pg_type t on e.enumtypid = t.oid
    where t.typname = 'employee_role'
      and e.enumlabel = 'employee'
  ) then
    alter type public.employee_role add value 'employee';
  end if;
end $$;
