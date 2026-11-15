-- PillowTop POS: warehouse-gated transfer approval
--
-- Approval of a transfer request is restricted to company-wide owner/admin or
-- employees whose home store is a WAREHOUSE location (any role at a warehouse
-- may approve). Store-based managers can no longer approve.
--
-- verify_transfer_actor is intentionally unchanged: it still gates reject,
-- cancel, ship, and finalize, which remain owner/admin/manager actions —
-- store managers must still be able to finalize inbound transfers at their
-- own store.

-- Approver check: self-match + (owner/admin) OR (home store is a warehouse).
create or replace function public.verify_transfer_approver(p_employee_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_emp public.employees%rowtype;
begin
  if p_employee_id is null then
    raise exception 'Employee id is required';
  end if;

  select * into v_emp from public.employees where id = p_employee_id;
  if not found then
    raise exception 'Employee not found';
  end if;

  if v_emp.auth_user_id is distinct from auth.uid() then
    raise exception 'Employee does not match the authenticated user';
  end if;

  if v_emp.role::text not in ('owner', 'admin')
     and not exists (
       select 1
       from public.stores s
       where s.id = v_emp.home_store_id
         and s.location_type = 'WAREHOUSE'
     ) then
    raise exception 'Only owner, admin, or warehouse-based employees can approve transfer requests';
  end if;

  return v_emp.id;
end;
$$;

grant execute on function public.verify_transfer_approver(uuid) to authenticated;

-- approve_transfer_request: identical to the 040 definition except the actor
-- check uses verify_transfer_approver instead of verify_transfer_actor.
create or replace function public.approve_transfer_request(
  p_request_id uuid,
  p_employee_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid;
  v_req public.transfer_requests%rowtype;
  v_available integer;
  v_origin_name text;
  v_product_name text;
begin
  v_actor := public.verify_transfer_approver(p_employee_id);

  select * into v_req
  from public.transfer_requests
  where id = p_request_id
  for update;

  if not found then
    raise exception 'Transfer request not found';
  end if;

  if v_req.status <> 'pending_approval' then
    raise exception 'Only pending_approval requests can be approved';
  end if;

  if not (public.is_store_visible(v_req.origin_location_id) or public.is_store_visible(v_req.destination_location_id)) then
    raise exception 'Transfer request is not visible to this employee';
  end if;

  -- Revalidate origin stock at approval time (covers all source types and
  -- catches stock changes since the request was created).
  select coalesce(ip.on_hand_quantity, 0) - coalesce(ip.committed_quantity, 0)
  into v_available
  from public.inventory_positions ip
  where ip.variant_id = v_req.variant_id
    and ip.location_id = v_req.origin_location_id
    and ip.disposition = 'Prime'
    and ip.sublocation_id is null;

  if v_available is null then
    v_available := 0;
  end if;

  if v_req.quantity > v_available then
    select coalesce(s.name, v_req.origin_location_id::text) into v_origin_name
    from public.stores s where s.id = v_req.origin_location_id;

    select coalesce(p.item_name, v_req.variant_id::text) into v_product_name
    from public.products p where p.id = v_req.variant_id;

    raise exception 'Origin "%" has only % units of "%" available; requested %',
      v_origin_name, v_available, v_product_name, v_req.quantity;
  end if;

  update public.transfer_requests
    set status = 'approved',
        approved_by = v_actor,
        approved_at = now()
  where id = p_request_id;
end;
$$;

grant execute on function public.approve_transfer_request(uuid, uuid) to authenticated;
