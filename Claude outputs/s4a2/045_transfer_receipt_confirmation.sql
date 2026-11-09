-- PillowTop POS: transfer receipt confirmation (store-side report)
--
-- When a store receives a transfer, any employee checked in at that store
-- today (or owner/admin) can report, per line item, what actually arrived.
-- The report is informational only — it writes reported_* columns on
-- transfer_line_items and never touches inventory_positions or
-- stock_ledger_entries. The existing finalize_transfer step remains the only
-- point that moves inventory; it now has the store's report as reference.
--
-- Warehouse destinations are excluded: when a warehouse receives (e.g. a
-- store returning stock), the warehouse employee finalizes directly with no
-- separate confirm step.

-- 1. Report reason enum + line-item columns

do $$
begin
  if not exists (select 1 from pg_type where typname = 'transfer_receipt_report_reason') then
    create type public.transfer_receipt_report_reason as enum (
      'missing', 'damaged', 'wrong_item', 'other'
    );
  end if;
end $$;

grant usage on type public.transfer_receipt_report_reason to authenticated;

alter table public.transfer_line_items
  add column if not exists reported_quantity_received integer,
  add column if not exists reported_reason public.transfer_receipt_report_reason,
  add column if not exists reported_note text,
  add column if not exists reported_by uuid references public.employees(id),
  add column if not exists reported_at timestamptz;

-- 2. confirm_transfer_receipt: store-side receipt report.
--
--    Authorization: the employee must match the authenticated user, and be
--    owner/admin OR have today's daily store check-in (the same
--    user_metadata.active_store_id + active_store_confirmed_at pair the
--    store-select page writes and the Sidebar enforces) pointing at the
--    transfer's destination store. home_store_id is deliberately not used —
--    whoever is actually working that store today can check in a transfer.

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

  -- owner/admin may confirm from anywhere; everyone else must be checked in
  -- at the destination store today (daily store check-in, same as new-sale
  -- attribution).
  if v_emp.role::text not in ('owner', 'admin') then
    v_active_store := (auth.jwt() -> 'user_metadata' ->> 'active_store_id')::uuid;
    v_confirmed_at := nullif(auth.jwt() -> 'user_metadata' ->> 'active_store_confirmed_at', '')::timestamptz;
    if v_active_store is distinct from v_t.destination_location_id
       or v_confirmed_at is null
       or v_confirmed_at::date <> current_date then
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
