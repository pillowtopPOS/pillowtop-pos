-- Return the set of employee roles the UI should offer when creating or editing an employee.
-- 'employee' is intentionally excluded: it was an early generic value and has been consolidated into 'sales'.
-- It remains a legal enum value (Postgres does not support dropping enum values cleanly), but it is no longer assignable.
create or replace function public.get_employee_roles()
returns setof public.employee_role
language sql
stable
security invoker
set search_path = public
as $$
  select v
  from unnest(enum_range(null::public.employee_role)) as v
  where v <> 'employee';
$$;
