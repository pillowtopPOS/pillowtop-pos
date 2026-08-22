-- Phase 6b: company-wide store visibility and attribution decoupling.
-- Visibility is no longer role-based or active-store-based.
-- Any employee can view/act on any store in the same company.
-- Multi-tenant isolation (company boundary) remains in place.

create or replace function public.is_store_visible(check_store_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  my_company_id uuid;
begin
  select s.company_id into my_company_id
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid();

  if not found then
    return false;
  end if;

  return exists (
    select 1 from public.stores
    where id = check_store_id
      and company_id = my_company_id
  );
end;
$$;

-- is_journey_visible wraps is_store_visible and inherits the new rule automatically.
create or replace function public.is_journey_visible(check_journey_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  return exists (
    select 1 from public.sleep_journeys
    where id = check_journey_id
      and public.is_store_visible(store_id)
  );
end;
$$;
