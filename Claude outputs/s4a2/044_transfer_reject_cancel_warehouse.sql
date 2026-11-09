-- PillowTop POS: extend warehouse-gated transfer review to reject + cancel
--
-- Follow-up to 043: store-based managers should not be able to reject or
-- cancel transfer requests either — if an incoming transfer needs to be
-- changed or stopped, a warehouse employee or owner/admin handles it.
-- Both functions are identical to their 040 definitions except the actor
-- check now uses verify_transfer_approver.
--
-- verify_transfer_actor remains the gate for mark_transfer_in_transit and
-- finalize_transfer: store managers still need to receive inbound transfers
-- at their own store.

create or replace function public.reject_transfer_request(
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
begin
  v_actor := public.verify_transfer_approver(p_employee_id);

  select * into v_req
  from public.transfer_requests
  where id = p_request_id
  for update;

  if not found then raise exception 'Transfer request not found'; end if;
  if v_req.status <> 'pending_approval' then
    raise exception 'Only pending_approval requests can be rejected';
  end if;
  if not (public.is_store_visible(v_req.origin_location_id) or public.is_store_visible(v_req.destination_location_id)) then
    raise exception 'Transfer request is not visible to this employee';
  end if;

  update public.transfer_requests
    set status = 'rejected'
  where id = p_request_id;
end;
$$;

grant execute on function public.reject_transfer_request(uuid, uuid) to authenticated;

create or replace function public.cancel_transfer_request(
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
begin
  v_actor := public.verify_transfer_approver(p_employee_id);

  select * into v_req
  from public.transfer_requests
  where id = p_request_id
  for update;

  if not found then raise exception 'Transfer request not found'; end if;
  if v_req.status in ('consolidated', 'cancelled', 'rejected') then
    raise exception 'Transfer request cannot be cancelled in status %', v_req.status;
  end if;
  if not (public.is_store_visible(v_req.origin_location_id) or public.is_store_visible(v_req.destination_location_id)) then
    raise exception 'Transfer request is not visible to this employee';
  end if;

  update public.transfer_requests
    set status = 'cancelled'
  where id = p_request_id;
end;
$$;

grant execute on function public.cancel_transfer_request(uuid, uuid) to authenticated;
