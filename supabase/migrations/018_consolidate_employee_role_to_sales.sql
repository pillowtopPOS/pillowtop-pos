-- Consolidate the old generic 'employee' role into 'sales' so the UI has one clear non-privileged option.
-- 'employee' remains a legal enum value (Postgres does not support dropping enum values cleanly),
-- but it is no longer assigned to new or updated employees.

update public.employees
set role = 'sales'
where role = 'employee';
