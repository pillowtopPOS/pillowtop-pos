-- Phase 1, part B: employee role default and backfill
-- Run 007a_phase1_roles_enum.sql first.

-- Update the default so new employees are regular employees.
alter table public.employees
  alter column role set default 'employee';

-- Backfill existing rows: manager -> admin, sales -> employee, Zach -> owner.
update public.employees
set role = 'admin'
where role = 'manager';

update public.employees
set role = 'employee'
where role = 'sales';

update public.employees
set role = 'owner'
where name = 'Zach Roesch';
