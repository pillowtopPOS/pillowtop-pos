-- PillowTop POS m120: transfer dates use the business timezone, not UTC
--
-- After ~5-6 PM Mountain the UTC date is already tomorrow, so
--   * expedite_transfer_request / _group rejected "today" as "in the past"
--   * confirm_transfer_receipt compared the check-in timestamp's UTC date
--     to UTC current_date (double bug: timestamptz::date is session-TZ)
--   * run_transfer_consolidation_now scheduled off the UTC date
--
-- "Today" is now business_today(store): stores.timezone falling back to
-- companies.business_timezone (same rule as m119's receiver check and the
-- sleep-trial evaluator). For expedite the relevant store is the request's
-- destination — the store whose schedule day the transfer serves. For the
-- manual consolidation run it is the acting employee's home store, falling
-- back to current_date when that store is unknown.

-- 1. expedite_transfer_request: same body as 047, business-date check.

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
  v_today date;
begin
  if p_scheduled_date is null then
    raise exception 'A scheduled date is required';
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

  v_today := coalesce(
    public.business_today(v_req.destination_location_id),
    current_date
  );
  if p_scheduled_date < v_today then
    raise exception 'Scheduled date cannot be in the past';
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

-- 2. expedite_transfer_request_group: same body as 048, business-date check.

create or replace function public.expedite_transfer_request_group(
  p_group_id uuid,
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
  v_count integer := 0;
  v_new_transfer_id uuid;
  v_today date;
begin
  if p_scheduled_date is null then
    raise exception 'A scheduled date is required';
  end if;

  v_actor := public.verify_transfer_approver(p_employee_id);

  -- Lock and validate every member before creating anything: all-or-nothing.
  for v_req in
    select * from public.transfer_requests
    where request_group_id = p_group_id
    order by created_at
    for update
  loop
    v_count := v_count + 1;
    if v_req.status <> 'approved' or v_req.transfer_id is not null then
      raise exception 'Every request in the group must be approved and unconsolidated to expedite';
    end if;
    if not (public.is_store_visible(v_req.origin_location_id) or public.is_store_visible(v_req.destination_location_id)) then
      raise exception 'Transfer request is not visible to this employee';
    end if;
  end loop;

  if v_count = 0 then
    raise exception 'Request group not found';
  end if;

  -- Members of a group share one origin/destination by construction.
  select * into v_req
  from public.transfer_requests
  where request_group_id = p_group_id
  order by created_at
  limit 1;

  v_today := coalesce(
    public.business_today(v_req.destination_location_id),
    current_date
  );
  if p_scheduled_date < v_today then
    raise exception 'Scheduled date cannot be in the past';
  end if;

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
  )
  select
    v_new_transfer_id,
    r.variant_id,
    sum(r.quantity)
  from public.transfer_requests r
  where r.request_group_id = p_group_id
  group by r.variant_id;

  update public.transfer_requests
    set status = 'consolidated',
        transfer_id = v_new_transfer_id
  where request_group_id = p_group_id;
end;
$$;

grant execute on function public.expedite_transfer_request_group(uuid, uuid, date) to authenticated;

-- 3. run_transfer_consolidation_now: schedule off the employee's business
--    day instead of the UTC date.

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
  v_today date;
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

  v_today := coalesce(
    public.business_today(v_emp.home_store_id),
    current_date
  );

  perform public.run_transfer_cron_for_date(v_today);

  insert into public.cron_state (task_name, last_run_date, updated_at)
  values ('transfers', v_today, now())
  on conflict (task_name)
  do update set last_run_date = excluded.last_run_date,
                updated_at = excluded.updated_at;
end;
$$;

grant execute on function public.run_transfer_consolidation_now(uuid) to authenticated;

-- 4. confirm_transfer_receipt: 045 body verbatim except the check-in
--    "today" comparison, which now uses the destination store's business
--    day in both directions (check-in timestamp AND current day).

create or replace function public.confirm_transfer_receipt(
  p_transfer_id uuid,
  p_employee_id uuid,
  p_line_reports jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_emp public.employees%rowtype;
  v_t public.transfers%rowtype;
  v_report jsonb;
  v_line_id uuid;
  v_shipped integer;
  v_qty integer;
  v_reason public.transfer_receipt_report_reason;
  v_note text;
  v_active_store uuid;
  v_confirmed_at timestamptz;
  v_tz text;
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

  select * into v_t
  from public.transfers
  where id = p_transfer_id
  for update;

  if not found then raise exception 'Transfer not found'; end if;

  if v_t.status <> 'in_transit' then
    raise exception 'Receipt can only be confirmed while the transfer is in transit';
  end if;

  if not exists (
    select 1 from public.stores s
    where s.id = v_t.destination_location_id
      and s.location_type = 'STORE'
  ) then
    raise exception 'Receipt confirmation only applies to transfers bound for a store';
  end if;

  if not (public.is_store_visible(v_t.origin_location_id) or public.is_store_visible(v_t.destination_location_id)) then
    raise exception 'Transfer is not visible to this employee';
  end if;

  -- "Today" for the check-in comparison is the destination store's local
  -- business day (stores.timezone, falling back to companies.
  -- business_timezone) — never the UTC date (m120).
  select coalesce(s.timezone, c.business_timezone)
    into v_tz
  from public.stores s
  join public.companies c on c.id = s.company_id
  where s.id = v_t.destination_location_id;

  -- owner/admin may confirm from anywhere; everyone else must be checked in
  -- at the destination store today (daily store check-in, same as new-sale
  -- attribution).
  if v_emp.role::text not in ('owner', 'admin') then
    v_active_store := (auth.jwt() -> 'user_metadata' ->> 'active_store_id')::uuid;
    v_confirmed_at := nullif(auth.jwt() -> 'user_metadata' ->> 'active_store_confirmed_at', '')::timestamptz;
    if v_active_store is distinct from v_t.destination_location_id
       or v_confirmed_at is null
       or (v_confirmed_at at time zone v_tz)::date
          <> public.business_today(v_t.destination_location_id) then
      raise exception 'Only an employee checked in at the destination store today, or an owner/admin, can confirm receipt';
    end if;
  end if;

  for v_report in select * from jsonb_array_elements(coalesce(p_line_reports, '[]'::jsonb)) loop
    v_line_id := (v_report ->> 'line_item_id')::uuid;

    select quantity_shipped into v_shipped
    from public.transfer_line_items
    where id = v_line_id
      and transfer_id = p_transfer_id;

    if not found then
      raise exception 'Line item % does not belong to this transfer', v_line_id;
    end if;

    v_qty := (v_report ->> 'quantity_received')::integer;
    if v_qty is null or v_qty < 0 then
      raise exception 'Invalid received quantity for line %', v_line_id;
    end if;

    v_reason := null;
    if nullif(v_report ->> 'reason', '') is not null then
      v_reason := (v_report ->> 'reason')::public.transfer_receipt_report_reason;
    end if;
    v_note := nullif(v_report ->> 'note', '');

    -- A shortfall must carry a reason so the paper trail explains the gap.
    if v_qty < v_shipped and v_reason is null then
      raise exception 'A reason is required when the reported received quantity is less than shipped (line %)', v_line_id;
    end if;

    update public.transfer_line_items
      set reported_quantity_received = v_qty,
          reported_reason = v_reason,
          reported_note = v_note,
          reported_by = v_emp.id,
          reported_at = now()
    where id = v_line_id
      and reported_at is null; -- first submission stands

    if not found then
      raise exception 'Receipt has already been reported for line %', v_line_id;
    end if;
  end loop;
end;
$$;

grant execute on function public.confirm_transfer_receipt(uuid, uuid, jsonb) to authenticated;
