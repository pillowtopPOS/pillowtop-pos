-- PillowTop POS: transfer consolidation failsafe + off-schedule expedite
--
-- Two additions, both reusing the existing consolidation logic:
--
-- 1. run_transfer_consolidation_now: a deliberate, on-demand manual trigger
--    for owner/admin. It calls the exact same run_transfer_cron_for_date the
--    daily job uses (so it still respects each store's Transfer Schedule Day)
--    but bypasses the once-per-day cron_state guard, which exists only to
--    keep the 60-second automatic poll from redundantly reprocessing. After
--    a successful run it stamps cron_state so the "last run" display reflects
--    the manual run and the automatic poll knows today is already covered.
--
-- 2. expedite_transfer_request: converts a single approved-but-unconsolidated
--    transfer request into a real, shippable transfer immediately, ignoring
--    the destination store's Transfer Schedule Day entirely. Authorization
--    matches the existing review group (owner/admin or warehouse-based) via
--    verify_transfer_approver. The resulting transfer gets scheduled_date =
--    today, which is what marks it as having gone through this path.

-- 1. Manual consolidation trigger (owner/admin only)

create or replace function public.run_transfer_consolidation_now(
  p_employee_id uuid
)
returns void
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

  if v_emp.role::text not in ('owner', 'admin') then
    raise exception 'Only owner or admin can run consolidation manually';
  end if;

  perform public.run_transfer_cron_for_date(current_date);

  insert into public.cron_state (task_name, last_run_date, updated_at)
  values ('transfers', current_date, now())
  on conflict (task_name)
  do update set last_run_date = excluded.last_run_date,
                updated_at = excluded.updated_at;
end;
$$;

grant execute on function public.run_transfer_consolidation_now(uuid) to authenticated;

-- 2. Expedite a single approved request off-schedule

create or replace function public.expedite_transfer_request(
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
  v_new_transfer_id uuid;
begin
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
  -- is the emergency path around the normal schedule.
  insert into public.transfers (
    origin_location_id,
    destination_location_id,
    status,
    scheduled_date
  ) values (
    v_req.origin_location_id,
    v_req.destination_location_id,
    'pending',
    current_date
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

grant execute on function public.expedite_transfer_request(uuid, uuid) to authenticated;
