-- PillowTop POS: prevent inventory reductions below committed quantity

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
  v_committed integer;
begin
  v_role := public.current_employee_role();

  select s.company_id
  into v_caller_company
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid();

  select company_id
  into v_location_company
  from public.stores
  where id = p_location_id;

  if v_caller_company is null then
    raise exception 'Could not determine employee company';
  end if;

  if v_caller_company is distinct from v_location_company then
    raise exception 'Location does not belong to employee company';
  end if;

  if v_role::text in ('owner', 'admin') then
    v_allowed := true;
  elsif v_role::text = 'manager' then
    select coalesce(managers_can_adjust_inventory, false)
    into v_allowed
    from public.companies
    where id = v_caller_company;
  end if;

  if not v_allowed then
    raise exception 'Employee is not authorized to adjust inventory';
  end if;

  if p_new_quantity < 0 then
    raise exception 'Quantity cannot be negative';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      p_variant_id::text || ':' || p_location_id::text || ':' || p_disposition::text,
      7137
    )
  );

  select id, on_hand_quantity, committed_quantity
  into v_position_id, v_old, v_committed
  from public.inventory_positions
  where variant_id = p_variant_id
    and location_id = p_location_id
    and sublocation_id is not distinct from p_sublocation_id
    and disposition = p_disposition
  for update;

  if not found then
    insert into public.inventory_positions (
      variant_id,
      location_id,
      sublocation_id,
      disposition,
      on_hand_quantity,
      committed_quantity
    ) values (
      p_variant_id,
      p_location_id,
      p_sublocation_id,
      p_disposition,
      p_new_quantity,
      0
    )
    returning id into v_position_id;

    v_old := 0;
    v_committed := 0;
  else
    if p_new_quantity < v_committed then
      raise exception
        'Cannot set on-hand to % — % units are already committed to open orders at this location. Resolve or cancel those orders before reducing stock below that level.',
        p_new_quantity,
        v_committed;
    end if;

    update public.inventory_positions
    set on_hand_quantity = p_new_quantity,
        updated_at = now()
    where id = v_position_id;
  end if;

  if p_new_quantity <> v_old then
    insert into public.stock_ledger_entries (
      variant_id,
      location_id,
      disposition,
      quantity_delta,
      reason,
      reference_type,
      actor_id
    ) values (
      p_variant_id,
      p_location_id,
      p_disposition,
      p_new_quantity - v_old,
      p_reason,
      p_reference_type,
      p_actor_id
    );
  end if;

  if p_new_quantity > v_old and p_disposition = 'Prime' then
    perform public.evaluate_pending_inventory_for_variant(
      p_variant_id,
      p_location_id
    );
  end if;

  return v_position_id;
end;
$$;

grant execute on function public.adjust_inventory_position(
  uuid,
  uuid,
  text,
  public.disposition,
  integer,
  text,
  text,
  text
) to authenticated;
