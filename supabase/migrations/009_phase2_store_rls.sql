-- Phase 2 follow-up: allow only owner/admin employees to create or update stores.

-- 1. Insert policy for stores (owner/admin only)

drop policy if exists "Stores insertable by owner/admin" on public.stores;
create policy "Stores insertable by owner/admin"
  on public.stores for insert
  to authenticated
  with check (public.current_employee_role() in ('owner', 'admin'));

-- 2. Update policy for stores (owner/admin only)

drop policy if exists "Stores updatable by owner/admin" on public.stores;
create policy "Stores updatable by owner/admin"
  on public.stores for update
  to authenticated
  using (public.current_employee_role() in ('owner', 'admin'))
  with check (public.current_employee_role() in ('owner', 'admin'));
