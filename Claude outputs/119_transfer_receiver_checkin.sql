-- ============================================================================
-- S4b-2: receiver permission follows the destination type
--
-- verify_transfer_receiver (117) allowed owner/admin, warehouse-based staff,
-- or home_store_id = destination for EVERY destination. The new rule:
--
--   * STORE destination: owner/admin, OR an employee checked in at that store
--     today. "Today" is the company's local business day (stores.timezone,
--     falling back to companies.business_timezone), not the UTC day.
--   * WAREHOUSE / WAREHOUSE_QUARANTINE destination: unchanged — owner/admin
--     or warehouse-based staff.
--
-- home_store_id = destination no longer qualifies for store destinations.
--
-- Callers: finalize_transfer and mark_transfer_unit_missing only.
-- confirm_transfer_receipt (045) does its own inline check and is NOT
-- touched here (it still uses the UTC-day test — see report).
-- ============================================================================

create or replace function public.verify_transfer_receiver(
  p_employee_id uuid,
  p_destination_location_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_emp public.employees%rowtype;
  v_dest_name text;
  v_dest_type text;
  v_tz text;
  v_active_store uuid;
  v_confirmed_at timestamptz;
begin
  if p_employee_id is null then
    raise exception 'Employee id is required';
  end if;

  select * into v_emp from public.employees where id = p_employee_id;
  if not found then
    raise exception 'Employee not found';
  end if;
  if not v_emp.is_active then
    raise exception 'Employee is not active';
  end if;
  if v_emp.auth_user_id is distinct from auth.uid() then
    raise exception 'Employee does not match the authenticated user';
  end if;

  select s.name, s.location_type::text,
         coalesce(s.timezone, c.business_timezone)
    into v_dest_name, v_dest_type, v_tz
  from public.stores s
  join public.companies c on c.id = s.company_id
  where s.id = p_destination_location_id;

  if v_dest_type = 'STORE' then
    -- Store destination: owner/admin anywhere; everyone else must be checked
    -- in at THIS store today, where today is the store's local business day.
    if v_emp.role::text not in ('owner', 'admin') then
      v_active_store := (auth.jwt() -> 'user_metadata' ->> 'active_store_id')::uuid;
      v_confirmed_at := nullif(auth.jwt() -> 'user_metadata' ->> 'active_store_confirmed_at', '')::timestamptz;
      if v_active_store is distinct from p_destination_location_id
         or v_confirmed_at is null
         or (v_confirmed_at at time zone v_tz)::date
            <> (now() at time zone v_tz)::date then
        raise exception
          'Check in at % first. Only an employee checked in at the destination store today, or an owner or admin, can receive this transfer.',
          v_dest_name;
      end if;
    end if;
  else
    -- Warehouse (and quarantine warehouse) destination: unchanged rule.
    if v_emp.role::text not in ('owner', 'admin')
       and v_emp.home_store_id is distinct from p_destination_location_id
       and not exists (
         select 1 from public.stores s
         where s.id = v_emp.home_store_id
           and s.location_type = 'WAREHOUSE'
       ) then
      raise exception
        'Only the destination store''s staff, a manager, or warehouse staff can receive a transfer';
    end if;
  end if;

  return v_emp.id;
end;
$$;

grant execute on function public.verify_transfer_receiver(uuid, uuid) to authenticated;
