-- PillowTop POS: inventory authorization fix + manager-adjustment setting

-- 1. Company-level setting: managers can adjust inventory (default off for all)

alter table public.companies
  add column if not exists managers_can_adjust_inventory boolean not null default false;

-- 2. Allow authenticated users to update companies (owner/admin via RLS below)

grant select, update on public.companies to authenticated;

drop policy if exists "Companies updatable by owner/admin" on public.companies;
create policy "Companies updatable by owner/admin"
  on public.companies for update
  to authenticated
  using (public.current_employee_role()::text in ('owner', 'admin'))
  with check (public.current_employee_role()::text in ('owner', 'admin'));

-- 3. Replace adjust_inventory_position() with strict authorization
--    (signature is unchanged, so CREATE OR REPLACE is safe)

create or replace function public.adjust_inventory_position(
  p_variant_id uuid,
  p_location_id uuid,
  p_sublocation_id text,
  p_disposition public.disposition,
  p_new_quantity integer,
  p_reason text,
  p_reference_type text,
  p_actor_id text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role public.employee_role;
  v_caller_company uuid;
  v_location_company uuid;
  v_allowed boolean := false;
  v_position_id uuid;
  v_old integer;
begin
  -- Identify caller role
  v_role := public.current_employee_role();

  if v_role is null then
    raise exception 'Not authenticated as an employee';
  end if;

  -- Identify caller's company through their home store
  select s.company_id into v_caller_company
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid();

  if v_caller_company is null then
    raise exception 'Could not determine employee company';
  end if;

  -- Identify the company that owns the requested location
  select s.company_id into v_location_company
  from public.stores s
  where s.id = p_location_id;

  if v_caller_company is distinct from v_location_company then
    raise exception 'Location does not belong to employee company';
  end if;

  -- Authorization decision
  if v_role::text in ('owner', 'admin') then
    v_allowed := true;
  elsif v_role::text = 'manager' then
    select coalesce(managers_can_adjust_inventory, false) into v_allowed
    from public.companies
    where id = v_caller_company;
  end if;

  if not v_allowed then
    raise exception 'Employee is not authorized to adjust inventory';
  end if;

  if p_new_quantity < 0 then
    raise exception 'Quantity cannot be negative';
  end if;

  -- Find and lock existing position
  select id, on_hand_quantity
  into v_position_id, v_old
  from public.inventory_positions
  where variant_id = p_variant_id
    and location_id = p_location_id
    and sublocation_id is not distinct from p_sublocation_id
    and disposition = p_disposition
  for update;

  if not found then
    insert into public.inventory_positions (
      variant_id, location_id, sublocation_id, disposition, on_hand_quantity, committed_quantity
    ) values (
      p_variant_id, p_location_id, p_sublocation_id, p_disposition, p_new_quantity, 0
    ) returning id into v_position_id;
    v_old := 0;
  else
    update public.inventory_positions
    set on_hand_quantity = p_new_quantity,
        updated_at = now()
    where id = v_position_id;
  end if;

  if p_new_quantity <> v_old then
    insert into public.stock_ledger_entries (
      variant_id, location_id, disposition, quantity_delta, reason, reference_type, actor_id
    ) values (
      p_variant_id, p_location_id, p_disposition,
      p_new_quantity - v_old,
      p_reason,
      p_reference_type,
      p_actor_id
    );
  end if;

  return v_position_id;
end;
$$;
