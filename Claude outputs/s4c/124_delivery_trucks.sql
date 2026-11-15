-- PillowTop POS m124: delivery trucks, weekly patterns, date exceptions,
-- day slot adjustments, company delivery settings, and calendar RPCs.
--
-- D1-a scope: MANAGEMENT ONLY. No stops/bookings yet (D1-b) — the
-- calendar reports booked_count = 0, wired for later.
--
-- Model (Zach's decisions):
--   * Capacity is ONE POOL PER DAY = sum of stop caps of trucks ON that
--     day, plus the day's extra_slots adjustment (clamped >= 0).
--   * A truck runs on a WEEKLY PATTERN (ISO weekdays 1=Mon..7=Sun) plus
--     per-date EXCEPTIONS (force on or off). Nobody creates days by hand.
--   * "Off" closes a truck/day to NEW bookings only; existing stops are
--     unaffected (there are none yet).
--   * All dates are DATE columns in the company business timezone; no
--     truck-day rows are ever materialized.
--
-- Permissions: delivery.manage_trucks (truck CRUD, patterns, date
-- on/off) and delivery.manage_calendar (day slot adjustments) — owner,
-- admin and manager by default. Everyone in the company can VIEW via
-- get_delivery_calendar (any active employee of the company).

-- ============================================================================
-- 1. Tables
-- ============================================================================

create table if not exists public.delivery_trucks (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  name text not null,
  home_location_id uuid references public.stores (id) on delete set null,
  default_stop_cap integer not null default 8 check (default_stop_cap >= 0),
  -- ISO weekdays it normally runs: 1=Mon .. 7=Sun. Default Mon-Sat.
  weekly_pattern smallint[] not null default '{1,2,3,4,5,6}',
  sort_order integer not null default 0,
  archived_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.delivery_truck_exceptions (
  id uuid primary key default gen_random_uuid(),
  truck_id uuid not null references public.delivery_trucks (id) on delete cascade,
  date date not null,
  is_on boolean not null,
  created_at timestamptz not null default now(),
  unique (truck_id, date)
);

-- Per-date slot adjustment for the WHOLE day pool (can be negative).
-- Effective capacity is clamped at 0 when read.
create table if not exists public.delivery_day_adjustments (
  company_id uuid not null references public.companies (id) on delete cascade,
  date date not null,
  extra_slots integer not null default 0,
  updated_at timestamptz not null default now(),
  primary key (company_id, date)
);

alter table public.delivery_trucks enable row level security;
alter table public.delivery_truck_exceptions enable row level security;
alter table public.delivery_day_adjustments enable row level security;

-- No client table policies: all reads go through the security-definer
-- RPCs below, which enforce company scope themselves.

-- ============================================================================
-- 2. Company settings (typed columns, TBM-safe defaults)
-- ============================================================================

alter table public.companies
  add column if not exists delivery_limit_type text not null default 'stops'
    check (delivery_limit_type in ('stops', 'time', 'both')),
  add column if not exists delivery_window_hours integer not null default 3
    check (delivery_window_hours > 0),
  add column if not exists delivery_day_mode text not null default 'window'
    check (delivery_day_mode in ('window', 'day_only')),
  add column if not exists delivery_day_start time not null default '09:00',
  add column if not exists delivery_day_end time not null default '17:00';

-- ============================================================================
-- 3. Permission keys + grants
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
    'delivery.manage_calendar'
  );
$$;

revoke execute on function public.is_valid_permission_key(text) from anon;

-- Default grants: owner, admin, manager. Seeded for existing companies;
-- set_role_permission covers companies created later.
insert into public.role_permission_grants (company_id, role, permission_key)
select c.id, g.role, g.permission_key
from public.companies c
cross join (values
  ('owner',   'delivery.manage_trucks'),
  ('admin',   'delivery.manage_trucks'),
  ('manager', 'delivery.manage_trucks'),
  ('owner',   'delivery.manage_calendar'),
  ('admin',   'delivery.manage_calendar'),
  ('manager', 'delivery.manage_calendar')
) as g (role, permission_key)
on conflict do nothing;

-- ============================================================================
-- 4. Internal helpers
-- ============================================================================

-- Caller's company via home store (same resolution as has_permission).
create or replace function public.delivery_caller_company()
returns uuid
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
begin
  select s.company_id into v_company_id
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid()
    and e.is_active;
  return v_company_id;
end;
$$;

revoke execute on function public.delivery_caller_company() from public, anon;
grant execute on function public.delivery_caller_company() to authenticated;

-- Effective on/off for one truck on one date: exception wins, else the
-- weekly pattern (ISO isodow 1=Mon..7=Sun).
create or replace function public.delivery_truck_day_state(
  p_truck public.delivery_trucks,
  p_date date
)
returns table(is_on boolean, source text)
language sql
stable
security definer
set search_path = public
as $$
  select
    coalesce(ex.is_on, extract(isodow from p_date)::smallint = any(p_truck.weekly_pattern)),
    case when ex.is_on is not null then 'exception' else 'pattern' end
  from (select 1) one
  left join public.delivery_truck_exceptions ex
    on ex.truck_id = p_truck.id and ex.date = p_date;
$$;

revoke execute on function public.delivery_truck_day_state(public.delivery_trucks, date)
  from public, anon, authenticated;

-- ============================================================================
-- 5. Write RPCs (manage permissions enforced inside)
-- ============================================================================

create or replace function public.create_delivery_truck(
  p_name text,
  p_home_location_id uuid default null,
  p_default_stop_cap integer default 8,
  p_weekly_pattern smallint[] default '{1,2,3,4,5,6}'
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
  v_id uuid;
begin
  if not public.has_permission('delivery.manage_trucks') then
    raise exception 'You do not have permission to manage delivery trucks.';
  end if;
  v_company_id := public.delivery_caller_company();
  if v_company_id is null then
    raise exception 'Only active employees can manage delivery trucks.';
  end if;
  if p_name is null or trim(p_name) = '' then
    raise exception 'Give the truck a name.';
  end if;
  if p_default_stop_cap is null or p_default_stop_cap < 0 then
    raise exception 'The daily stop cap cannot be negative.';
  end if;
  if p_home_location_id is not null and not exists (
    select 1 from public.stores
    where id = p_home_location_id and company_id = v_company_id
  ) then
    raise exception 'That location is not in your company.';
  end if;
  if p_weekly_pattern is null
     or exists (select 1 from unnest(p_weekly_pattern) d where d < 1 or d > 7) then
    raise exception 'Pick the weekdays this truck runs (1 = Monday through 7 = Sunday).';
  end if;

  insert into public.delivery_trucks (
    company_id, name, home_location_id, default_stop_cap, weekly_pattern
  ) values (
    v_company_id, trim(p_name), p_home_location_id,
    p_default_stop_cap, p_weekly_pattern
  ) returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.update_delivery_truck(
  p_truck_id uuid,
  p_name text,
  p_home_location_id uuid,
  p_default_stop_cap integer
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
begin
  if not public.has_permission('delivery.manage_trucks') then
    raise exception 'You do not have permission to manage delivery trucks.';
  end if;
  v_company_id := public.delivery_caller_company();
  if not exists (
    select 1 from public.delivery_trucks
    where id = p_truck_id and company_id = v_company_id
      and archived_at is null
  ) then
    raise exception 'That truck was not found.';
  end if;
  if p_name is null or trim(p_name) = '' then
    raise exception 'Give the truck a name.';
  end if;
  if p_default_stop_cap is null or p_default_stop_cap < 0 then
    raise exception 'The daily stop cap cannot be negative.';
  end if;
  if p_home_location_id is not null and not exists (
    select 1 from public.stores
    where id = p_home_location_id and company_id = v_company_id
  ) then
    raise exception 'That location is not in your company.';
  end if;

  update public.delivery_trucks
  set name = trim(p_name),
      home_location_id = p_home_location_id,
      default_stop_cap = p_default_stop_cap,
      updated_at = now()
  where id = p_truck_id;
end;
$$;

create or replace function public.set_delivery_truck_archived(
  p_truck_id uuid,
  p_archived boolean
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
begin
  if not public.has_permission('delivery.manage_trucks') then
    raise exception 'You do not have permission to manage delivery trucks.';
  end if;
  v_company_id := public.delivery_caller_company();
  update public.delivery_trucks
  set archived_at = case when p_archived then now() else null end,
      updated_at = now()
  where id = p_truck_id and company_id = v_company_id;
  if not found then
    raise exception 'That truck was not found.';
  end if;
end;
$$;

create or replace function public.set_truck_weekday_pattern(
  p_truck_id uuid,
  p_weekdays smallint[]
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
begin
  if not public.has_permission('delivery.manage_trucks') then
    raise exception 'You do not have permission to manage delivery trucks.';
  end if;
  v_company_id := public.delivery_caller_company();
  if p_weekdays is null
     or exists (select 1 from unnest(p_weekdays) d where d < 1 or d > 7) then
    raise exception 'Pick the weekdays this truck runs (1 = Monday through 7 = Sunday).';
  end if;
  update public.delivery_trucks
  set weekly_pattern = p_weekdays, updated_at = now()
  where id = p_truck_id
    and company_id = v_company_id
    and archived_at is null;
  if not found then
    raise exception 'That truck was not found.';
  end if;
end;
$$;

-- p_on: true = force this date on, false = force it off,
-- null = clear the exception (back to the weekly pattern).
create or replace function public.set_truck_date_state(
  p_truck_id uuid,
  p_date date,
  p_on boolean
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
begin
  if not public.has_permission('delivery.manage_trucks') then
    raise exception 'You do not have permission to manage delivery trucks.';
  end if;
  v_company_id := public.delivery_caller_company();
  if p_date is null then
    raise exception 'Pick a date.';
  end if;
  if not exists (
    select 1 from public.delivery_trucks
    where id = p_truck_id and company_id = v_company_id
      and archived_at is null
  ) then
    raise exception 'That truck was not found.';
  end if;

  if p_on is null then
    delete from public.delivery_truck_exceptions
    where truck_id = p_truck_id and date = p_date;
  else
    insert into public.delivery_truck_exceptions (truck_id, date, is_on)
    values (p_truck_id, p_date, p_on)
    on conflict (truck_id, date) do update set is_on = excluded.is_on;
  end if;
end;
$$;

create or replace function public.set_day_extra_slots(
  p_date date,
  p_extra_slots integer
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
begin
  if not public.has_permission('delivery.manage_calendar') then
    raise exception 'You do not have permission to manage the delivery calendar.';
  end if;
  v_company_id := public.delivery_caller_company();
  if v_company_id is null then
    raise exception 'Only active employees can manage the delivery calendar.';
  end if;
  if p_date is null then
    raise exception 'Pick a date.';
  end if;
  if p_extra_slots is null then
    raise exception 'Give a number of extra slots.';
  end if;

  if p_extra_slots = 0 then
    delete from public.delivery_day_adjustments
    where company_id = v_company_id and date = p_date;
  else
    insert into public.delivery_day_adjustments (company_id, date, extra_slots)
    values (v_company_id, p_date, p_extra_slots)
    on conflict (company_id, date)
    do update set extra_slots = excluded.extra_slots, updated_at = now();
  end if;
end;
$$;

grant execute on function public.create_delivery_truck(text, uuid, integer, smallint[]) to authenticated;
grant execute on function public.update_delivery_truck(uuid, text, uuid, integer) to authenticated;
grant execute on function public.set_delivery_truck_archived(uuid, boolean) to authenticated;
grant execute on function public.set_truck_weekday_pattern(uuid, smallint[]) to authenticated;
grant execute on function public.set_truck_date_state(uuid, date, boolean) to authenticated;
grant execute on function public.set_day_extra_slots(date, integer) to authenticated;

-- ============================================================================
-- 6. Read RPC: the whole calendar page in one call.
--    Any active employee of the company may view.
--    Returns { settings, trucks, days[] }.
--    booked_count is 0 until D1-b adds stops.
-- ============================================================================

create or replace function public.get_delivery_calendar(
  p_start_date date,
  p_end_date date
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
  v_result jsonb;
begin
  v_company_id := public.delivery_caller_company();
  if v_company_id is null then
    return jsonb_build_object('settings', null, 'trucks', '[]'::jsonb, 'days', '[]'::jsonb);
  end if;
  if p_start_date is null or p_end_date is null or p_end_date < p_start_date then
    raise exception 'Pick a valid date range.';
  end if;
  if p_end_date - p_start_date > 62 then
    raise exception 'Pick a range of 62 days or fewer.';
  end if;

  with days as (
    select generate_series(p_start_date, p_end_date, interval '1 day')::date as d
  ),
  trucks as (
    select t.*
    from public.delivery_trucks t
    where t.company_id = v_company_id
      and t.archived_at is null
    order by t.sort_order, t.name
  ),
  day_trucks as (
    select
      d.d as date,
      t.id as truck_id,
      t.name as truck_name,
      t.default_stop_cap,
      t.home_location_id,
      st.name as home_location_name,
      st.location_type::text as home_location_type,
      ds.is_on,
      ds.source,
      case when ds.is_on then t.default_stop_cap else 0 end as stop_cap
    from days d
    cross join trucks t
    left join public.stores st on st.id = t.home_location_id
    cross join lateral public.delivery_truck_day_state(t, d.d) ds
  ),
  day_rollup as (
    select
      dt.date,
      coalesce(sum(dt.stop_cap), 0) as pattern_capacity,
      coalesce((
        select a.extra_slots
        from public.delivery_day_adjustments a
        where a.company_id = v_company_id and a.date = dt.date
      ), 0) as extra_slots,
      jsonb_agg(
        jsonb_build_object(
          'truck_id', dt.truck_id,
          'name', dt.truck_name,
          'home_location_id', dt.home_location_id,
          'home_location_name', dt.home_location_name,
          'home_location_type', dt.home_location_type,
          'on', dt.is_on,
          'source', dt.source,
          'stop_cap', dt.stop_cap
        ) order BY dt.truck_name
      ) as trucks
    from day_trucks dt
    group by dt.date
  )
  select jsonb_build_object(
    'settings', (
      select jsonb_build_object(
        'delivery_limit_type', c.delivery_limit_type,
        'delivery_window_hours', c.delivery_window_hours,
        'delivery_day_mode', c.delivery_day_mode,
        'delivery_day_start', c.delivery_day_start,
        'delivery_day_end', c.delivery_day_end
      )
      from public.companies c where c.id = v_company_id
    ),
    'trucks', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', t.id,
        'name', t.name,
        'home_location_id', t.home_location_id,
        'home_location_name', st.name,
        'default_stop_cap', t.default_stop_cap,
        'weekly_pattern', t.weekly_pattern,
        'sort_order', t.sort_order
      ) order by t.sort_order, t.name)
      from public.delivery_trucks t
      left join public.stores st on st.id = t.home_location_id
      where t.company_id = v_company_id and t.archived_at is null
    ), '[]'::jsonb),
    'days', coalesce((
      select jsonb_agg(jsonb_build_object(
        'date', r.date,
        'extra_slots', r.extra_slots,
        'capacity', greatest(0, r.pattern_capacity + r.extra_slots),
        'booked_count', 0,
        'trucks', r.trucks
      ) order by r.date)
      from day_rollup r
    ), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$$;

grant execute on function public.get_delivery_calendar(date, date) to authenticated;
