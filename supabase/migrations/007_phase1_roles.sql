-- Phase 1: Employee roles + Settings access

-- 1. Make sure the employee_role enum has owner, admin, and employee values.
-- The original scaffolding used owner/manager/sales, so we adapt it in place.

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

-- 2. Update the default so new employees are regular employees.

alter table public.employees
  alter column role set default 'employee';

-- 3. Backfill existing rows: manager -> admin, sales -> employee, Zach -> owner.

update public.employees
set role = 'admin'
where role = 'manager';

update public.employees
set role = 'employee'
where role = 'sales';

update public.employees
set role = 'owner'
where name = 'Zach Roesch';
