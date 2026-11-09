-- PillowTop POS: expedite with a chosen scheduled date
--
-- Follow-up to 046: Expedite still goes around the normal weekly schedule,
-- but the caller now picks the transfer's scheduled_date instead of it being
-- hardcoded to today. A date in the past is rejected.
--
-- The two-parameter version from 046 is dropped so there is no stale
-- overload with a different meaning.

drop function if exists public.expedite_transfer_request(uuid, uuid);

create or replace function public.expedite_transfer_request(
  p_request_id uuid,
  p_employee_id uuid,
  p_scheduled_date date
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid;
  v_req public.transfer_requests%rowtype;
  v_new_transfer_id uuid;
begin
  if p_scheduled_date is null then
    raise exception 'A scheduled date is required';
  end if;
  if p_scheduled_date < current_date then
    raise exception 'Scheduled date cannot be in the past';
  end if;

  v_actor := public.verify_transfer_approver(p_employee_id);

  select * into v_req
  from public.transfer_requests
  where id = p_request_id
  for update;

  if not found then raise exception 'Transfer request not found'; end if;
  if v_req.status <> 'approved' or v_req.transfer_id is not null then
    raise exception 'Only an approved, unconsolidated request can be expedited';
  end if;
  if not (public.is_store_visible(v_req.origin_location_id) or public.is_store_visible(v_req.destination_location_id)) then
    raise exception 'Transfer request is not visible to this employee';
  end if;

  -- Deliberately ignores the destination store's transfer_schedule_day: this
  -- is the emergency path around the normal schedule, for a date the caller
  -- chooses.
  insert into public.transfers (
    origin_location_id,
    destination_location_id,
    status,
    scheduled_date
  ) values (
    v_req.origin_location_id,
    v_req.destination_location_id,
    'pending',
    p_scheduled_date
  ) returning id into v_new_transfer_id;

  insert into public.transfer_line_items (
    transfer_id,
    variant_id,
    quantity_requested
  ) values (
    v_new_transfer_id,
    v_req.variant_id,
    v_req.quantity
  );

  update public.transfer_requests
    set status = 'consolidated',
        transfer_id = v_new_transfer_id
  where id = p_request_id;
end;
$$;

grant execute on function public.expedite_transfer_request(uuid, uuid, date) to authenticated;
