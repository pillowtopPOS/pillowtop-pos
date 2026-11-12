-- PillowTop POS m137: D1-c2b part 1a -- delivery day settings writer,
-- delivery.log_confirmation_calls permission, and per-stop window
-- writes for the day plan.
--
--   * set_delivery_day_settings: owner/admin only, writes the four
--     existing companies columns (delivery_day_start,
--     delivery_day_end, delivery_window_hours, delivery_day_mode).
--     The read side already returns all four via get_delivery_calendar.
--   * delivery.log_confirmation_calls: new permission, granted to
--     owner/admin/manager/sales by default. Logging confirmations must
--     not require delivery.manage_calendar.
--   * set_delivery_stop_windows: per-stop window_start/window_end
--     writes that work on OPEN and CLOSED days, never touch the day
--     plan version, and never interfere with
--     save_delivery_day_route (which only writes truck_id and
--     route_position). One WINDOW_SET row in delivery_route_events per
--     call carries the before/after summary in the new details column.
--
-- Window times are plain time values read as company-local, matching
-- delivery_company_today(). A window outside the company day hours is
-- allowed on purpose: the UI warns, the database does not block.
-- day_only mode does not block window writes either.

-- ============================================================================
-- 1. Permission key delivery.log_confirmation_calls
-- ============================================================================

create or replace function public.is_valid_permission_key(p_key text)
returns boolean
language sql
immutable
as $$
  select p_key in (
    'sleep_trial.manage_concerns',
    'sleep_trial.start_exchange',
    'sleep_trial.start_return',
    'sleep_trial.request_exceptions',
    'sleep_trial.approve_exceptions',
    'sleep_trial.approve_own_exceptions',
    'sleep_trial.override_protector',
    'sleep_trial.correct_dates',
    'sleep_trial.manage_policy',
    'sleep_trial.view_policy_details',
    'inventory.reduce_below_committed',
    'sleep_trial.complete_exchange',
    'inventory.inspect_returns',
    'inventory.manage_inspection_checklist',
    'sleep_trial.void_refund',
    'units.assign',
    'units.unassign',
    'units.override_set',
    'units.swap',
    'units.void',
    'units.manage_settings',
    'inventory.receive_po',
    'delivery.manage_trucks',
    'delivery.manage_calendar',
    'delivery.book_inside_cutoff',
    'delivery.log_confirmation_calls'
  );
$$;

revoke execute on function public.is_valid_permission_key(text) from anon;

-- Existing companies: every delivery-facing role gets the new key.
insert into public.role_permission_grants (company_id, role, permission_key)
select c.id, g.role, 'delivery.log_confirmation_calls'
from public.companies c
cross join (values
  ('owner'), ('admin'), ('manager'), ('sales')
) as g (role)
on conflict do nothing;

-- New companies: same grants, via the existing seed trigger.
create or replace function public.trg_seed_delivery_permissions()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.role_permission_grants (company_id, role, permission_key)
  values
    (new.id, 'owner', 'delivery.manage_trucks'),
    (new.id, 'admin', 'delivery.manage_trucks'),
    (new.id, 'owner', 'delivery.manage_calendar'),
    (new.id, 'admin', 'delivery.manage_calendar'),
    (new.id, 'owner', 'delivery.book_inside_cutoff'),
    (new.id, 'admin', 'delivery.book_inside_cutoff'),
    (new.id, 'owner', 'delivery.log_confirmation_calls'),
    (new.id, 'admin', 'delivery.log_confirmation_calls'),
    (new.id, 'manager', 'delivery.log_confirmation_calls'),
    (new.id, 'sales', 'delivery.log_confirmation_calls')
  on conflict do nothing;
  return new;
end;
$$;

revoke execute on function public.trg_seed_delivery_permissions()
  from authenticated, anon, public;

-- ============================================================================
-- 2. delivery_route_events.details -- before/after payload for WINDOW_SET
--    (and future event kinds). Nullable; existing rows and writers are
--    unaffected.
-- ============================================================================

alter table public.delivery_route_events
  add column if not exists details jsonb;

comment on column public.delivery_route_events.details is
  'Optional structured payload. WINDOW_SET rows carry a changes array with per-stop before/after window values.';

-- ============================================================================
-- 3. set_delivery_day_settings -- owner/admin only, same gate as
--    set_delivery_contact_hold_days. Writes the four existing columns.
-- ============================================================================

create or replace function public.set_delivery_day_settings(
  p_day_start time,
  p_day_end time,
  p_window_hours integer,
  p_day_mode text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
  v_role text;
  v_day_seconds numeric;
begin
  select e.role, s.company_id into v_role, v_company_id
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid() and e.is_active;

  if v_role is null or v_role not in ('owner', 'admin') then
    raise exception 'Only owners and admins can change company settings.';
  end if;
  if v_company_id is null then
    raise exception 'Only active employees can change company settings.';
  end if;

  if p_day_start is null or p_day_end is null
     or p_window_hours is null or p_day_mode is null then
    raise exception 'Day start, day end, window hours and day mode are all required.';
  end if;
  if p_day_end <= p_day_start then
    raise exception 'The day must end after it starts.';
  end if;
  if p_day_mode not in ('window', 'day_only') then
    raise exception 'Day mode must be window or day_only.';
  end if;
  if p_window_hours < 1 or p_window_hours > 8 then
    raise exception 'Window hours must be a whole number between 1 and 8.';
  end if;

  v_day_seconds := extract(epoch from (p_day_end - p_day_start));
  if p_window_hours * 3600 > v_day_seconds then
    raise exception 'The window cannot be longer than the delivery day.';
  end if;

  update public.companies
  set delivery_day_start = p_day_start,
      delivery_day_end = p_day_end,
      delivery_window_hours = p_window_hours,
      delivery_day_mode = p_day_mode
  where id = v_company_id;
end;
$$;

revoke execute on function public.set_delivery_day_settings(time, time, integer, text)
  from public, anon;
grant execute on function public.set_delivery_day_settings(time, time, integer, text)
  to authenticated;

-- ============================================================================
-- 4. set_delivery_stop_windows -- per-stop window writes.
--
--    p_items: jsonb array of {"stop_id": uuid, "window_start": "HH:MM[:SS]",
--    "window_end": "HH:MM[:SS]"}. Both window fields null clears the
--    window. All-or-nothing: every item is validated before any write.
--
--    Works on OPEN and CLOSED days on purpose: windows are call-prep
--    data, not route shape, so they must stay editable after close.
--    The day plan version is never read or bumped, and
--    save_delivery_day_route never touches window columns.
--    Requires delivery.manage_calendar. Past days stay read-only via
--    delivery_assert_day_writable.
-- ============================================================================

create or replace function public.set_delivery_stop_windows(
  p_date date,
  p_items jsonb
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
  v_employee_id uuid;
  v_count integer;
begin
  v_company_id := public.delivery_caller_company();
  if v_company_id is null then
    raise exception 'Only active employees can manage deliveries.';
  end if;
  if not public.has_permission('delivery.manage_calendar') then
    raise exception 'You do not have permission to manage the delivery calendar.';
  end if;
  perform public.delivery_assert_day_writable(p_date);

  v_employee_id := public.delivery_caller_employee_id();

  if p_items is null
     or jsonb_typeof(p_items) <> 'array'
     or jsonb_array_length(p_items) = 0 then
    raise exception 'Send at least one stop window.';
  end if;

  -- Validate every item and snapshot current windows before writing.
  -- Last duplicate stop_id wins so a repeated row cannot double-apply.
  create temp table if not exists d137_window_items (
    ord integer,
    stop_id uuid,
    window_start time,
    window_end time
  ) on commit drop;
  delete from pg_temp.d137_window_items;

  insert into pg_temp.d137_window_items (ord, stop_id, window_start, window_end)
  select x.ord, x.stop_id, x.window_start, x.window_end
  from (
    select t.ord,
           (t.item->>'stop_id')::uuid as stop_id,
           nullif(t.item->>'window_start', '')::time as window_start,
           nullif(t.item->>'window_end', '')::time as window_end
    from jsonb_array_elements(p_items) with ordinality as t(item, ord)
  ) x;

  if exists (
    select 1 from pg_temp.d137_window_items
    where stop_id is null
       or (window_start is null) <> (window_end is null)
       or (window_start is not null and window_end <= window_start)
  ) then
    raise exception 'Each window needs both a start and an end time, with the end after the start.';
  end if;

  if exists (
    select 1 from (
      select distinct on (stop_id) stop_id
      from pg_temp.d137_window_items
      order by stop_id, ord desc
    ) d
    left join public.delivery_stops ds on ds.id = d.stop_id
    where ds.id is null
       or ds.company_id <> v_company_id
       or ds.delivery_date <> p_date
       or ds.status <> 'BOOKED'
  ) then
    raise exception 'Every window must name a booked stop for this company on that date.';
  end if;

  -- Snapshot current windows for the audit diff before any write.
  create temp table if not exists d137_window_before (
    stop_id uuid primary key,
    journey_id uuid,
    window_start time,
    window_end time
  ) on commit drop;
  delete from pg_temp.d137_window_before;

  insert into pg_temp.d137_window_before (stop_id, journey_id, window_start, window_end)
  select distinct on (i.stop_id) i.stop_id, ds.journey_id,
         ds.window_start, ds.window_end
  from pg_temp.d137_window_items i
  join public.delivery_stops ds on ds.id = i.stop_id
  order by i.stop_id, i.ord desc;

  -- Apply. Count only stops whose window actually changed.
  with dedup as (
    select distinct on (stop_id) stop_id, window_start, window_end
    from pg_temp.d137_window_items
    order by stop_id, ord desc
  ),
  updated as (
    update public.delivery_stops ds
    set window_start = d.window_start,
        window_end = d.window_end,
        updated_at = now()
    from dedup d
    where ds.id = d.stop_id
      and ds.company_id = v_company_id
      and ds.delivery_date = p_date
      and ds.status = 'BOOKED'
      and (ds.window_start is distinct from d.window_start
           or ds.window_end is distinct from d.window_end)
    returning ds.id
  )
  select count(*) into v_count from updated;

  -- One audit row per call; details carries the full before/after map
  -- for every submitted (deduped) stop, changed or not.
  insert into public.delivery_route_events (
    company_id, date, action, actor_id, details
  )
  select v_company_id, p_date, 'WINDOW_SET', v_employee_id,
         jsonb_build_object('changes', coalesce(jsonb_agg(jsonb_build_object(
           'stop_id', b.stop_id,
           'journey_id', b.journey_id,
           'from_start', b.window_start,
           'from_end', b.window_end,
           'to_start', d.window_start,
           'to_end', d.window_end
         ) order by b.stop_id), '[]'::jsonb))
  from (
    select distinct on (stop_id) stop_id, window_start, window_end
    from pg_temp.d137_window_items
    order by stop_id, ord desc
  ) d
  join pg_temp.d137_window_before b on b.stop_id = d.stop_id;

  drop table if exists pg_temp.d137_window_items;
  drop table if exists pg_temp.d137_window_before;

  return v_count;
end;
$$;

revoke execute on function public.set_delivery_stop_windows(date, jsonb)
  from public, anon;
grant execute on function public.set_delivery_stop_windows(date, jsonb)
  to authenticated;
