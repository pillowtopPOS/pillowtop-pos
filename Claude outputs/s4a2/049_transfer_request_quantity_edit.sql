-- PillowTop POS: editable quantity on pending transfer requests
--
-- Lets a warehouse-based employee or owner/admin correct a request's quantity
-- while it is still pending_approval. Once approved the quantity is locked —
-- approval now reserves real stock (048), so editing post-approval would have
-- to adjust a live reservation, which is deliberately out of scope.
--
-- Re-validates the new quantity against the origin's real availability using
-- the same row-locked read as approve_transfer_request, so an edit can't push
-- a request past what the origin can actually supply.

create or replace function public.update_transfer_request_quantity(
  p_request_id uuid,
  p_employee_id uuid,
  p_new_quantity integer
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid;
  v_req public.transfer_requests%rowtype;
  v_pos public.inventory_positions%rowtype;
  v_available integer;
  v_origin_name text;
  v_product_name text;
begin
  if p_new_quantity is null or p_new_quantity <= 0 then
    raise exception 'Quantity must be a positive number';
  end if;

  v_actor := public.verify_transfer_approver(p_employee_id);

  select * into v_req
  from public.transfer_requests
  where id = p_request_id
  for update;

  if not found then raise exception 'Transfer request not found'; end if;
  if v_req.status <> 'pending_approval' then
    raise exception 'Quantity can only be edited while the request is pending approval';
  end if;
  if not (public.is_store_visible(v_req.origin_location_id) or public.is_store_visible(v_req.destination_location_id)) then
    raise exception 'Transfer request is not visible to this employee';
  end if;

  -- Same availability re-validation as approve_transfer_request, against a
  -- row-locked read of the origin's Prime position.
  perform pg_advisory_xact_lock(
    hashtextextended(v_req.variant_id::text || ':' || v_req.origin_location_id::text || ':Prime', 7137)
  );

  select * into v_pos
  from public.inventory_positions
  where variant_id = v_req.variant_id
    and location_id = v_req.origin_location_id
    and disposition = 'Prime'
    and sublocation_id is null
  for update;

  v_available := coalesce(v_pos.on_hand_quantity, 0) - coalesce(v_pos.committed_quantity, 0);

  if p_new_quantity > v_available then
    select coalesce(s.name, v_req.origin_location_id::text) into v_origin_name
    from public.stores s where s.id = v_req.origin_location_id;

    select coalesce(p.item_name, v_req.variant_id::text) into v_product_name
    from public.products p where p.id = v_req.variant_id;

    raise exception 'Origin "%" has only % units of "%" available; requested %',
      v_origin_name, v_available, v_product_name, p_new_quantity;
  end if;

  update public.transfer_requests
    set quantity = p_new_quantity
  where id = p_request_id;
end;
$$;

grant execute on function public.update_transfer_request_quantity(uuid, uuid, integer) to authenticated;
