-- PillowTop POS m132: D1-c1 "close and assign" — day plans, truck
-- assignment and stop order for delivery days.
--
--   * delivery_day_plans: one row per (company, date), created lazily.
--     A day with no row is OPEN, version 0.
--   * delivery_stops gains truck_id / route_position / window_start /
--     window_end (all nullable = unrouted). Window RPCs land in D1-c2.
--   * delivery_route_events: append-only audit of every route change.
--   * RPCs: get_delivery_day_plan, save_delivery_day_route,
--     close_delivery_day, reopen_delivery_day,
--     suggest_delivery_assignments.
--
-- Booking into a CLOSED day keeps working exactly as in m129: the new
-- stop arrives unrouted (all route columns null). A released stop keeps
-- its truck_id/route_position on the CANCELLED/SUPERSEDED row for audit;
-- the partial unique index only counts BOOKED stops, so it never blocks
-- a new stop from taking that truck and position.

-- ============================================================================
-- 1. delivery_day_plans
-- ============================================================================

create table if not exists public.delivery_day_plans (
  company_id uuid not null references public.companies (id) on delete cascade,
  date date not null,
  status text not null default 'OPEN' check (status in ('OPEN', 'CLOSED')),
  version integer not null default 0,
  closed_at timestamptz,
  closed_by uuid,
  reopened_at timestamptz,
  reopened_by uuid,
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (company_id, date)
);

alter table public.delivery_day_plans enable row level security;
-- No client policies: all access goes through the security-definer RPCs.

-- ============================================================================
-- 2. Route columns on delivery_stops
-- ============================================================================

alter table public.delivery_stops
  add column if not exists truck_id uuid
    references public.delivery_trucks (id) on delete set null,
  add column if not exists route_position integer
    check (route_position is null or route_position > 0),
  add column if not exists window_start time,
  add column if not exists window_end time;

-- window_end must be after window_start when both are set.
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'delivery_stops_window_order'
      and conrelid = 'public.delivery_stops'::regclass
  ) then
    alter table public.delivery_stops
      add constraint delivery_stops_window_order
      check (window_start is null or window_end is null or window_end > window_start);
  end if;
end $$;

-- One position per truck among ACTIVE routed stops. CANCELLED and
-- SUPERSEDED rows keep their truck_id/route_position for audit without
-- blocking reuse.
create unique index if not exists delivery_stops_truck_position
  on public.delivery_stops (truck_id, route_position)
  where status = 'BOOKED' and truck_id is not null;

create index if not exists delivery_stops_company_truck_date
  on public.delivery_stops (company_id, truck_id, delivery_date)
  where status = 'BOOKED' and truck_id is not null;

-- ============================================================================
-- 3. delivery_route_events — append-only route audit log
-- ============================================================================

create table if not exists public.delivery_route_events (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  date date not null,
  stop_id uuid references public.delivery_stops (id) on delete cascade,
  journey_id uuid references public.sleep_journeys (id) on delete cascade,
  action text not null check (action in (
    'TRUCK_ASSIGNED', 'REORDERED', 'UNROUTED',
    'WINDOW_SET', 'PLAN_CLOSED', 'PLAN_REOPENED'
  )),
  from_truck_id uuid,
  to_truck_id uuid,
  from_position integer,
  to_position integer,
  actor_id uuid,
  created_at timestamptz not null default now()
);

create index if not exists delivery_route_events_day
  on public.delivery_route_events (company_id, date);
create index if not exists delivery_route_events_stop
  on public.delivery_route_events (stop_id);

alter table public.delivery_route_events enable row level security;
-- No client policies: all access goes through the security-definer RPCs.

create or replace function public.delivery_route_events_immutable()
returns trigger
language plpgsql
as $$
begin
  raise exception 'Delivery route history cannot be changed.';
end;
$$;

drop trigger if exists trg_delivery_route_events_immutable on public.delivery_route_events;
create trigger trg_delivery_route_events_immutable
before update or delete on public.delivery_route_events
for each row execute function public.delivery_route_events_immutable();

revoke execute on function public.delivery_route_events_immutable()
  from public, anon, authenticated;

-- ============================================================================
-- 4. Helpers
-- ============================================================================

-- Company business "today". A delivery DAY is a company-level concept,
-- so this uses companies.business_timezone. Known limitation: booking
-- (get_earliest_bookable_date) uses the fulfilling warehouse's store
-- timezone instead; the two agree for single-timezone retailers and can
-- differ by a day for multi-timezone companies near midnight.
create or replace function public.delivery_company_today()
returns date
language sql
stable
security definer
set search_path = public
as $$
  select (now() at time zone coalesce(
    (select c.business_timezone from public.companies c
     where c.id = public.delivery_caller_company()),
    'America/Denver'
  ))::date;
$$;

revoke execute on function public.delivery_company_today()
  from public, anon, authenticated;

-- The caller's employee id (for actor columns). Null when not an
-- active employee.
create or replace function public.delivery_caller_employee_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select e.id from public.employees e
  where e.auth_user_id = auth.uid() and e.is_active
  limit 1;
$$;

revoke execute on function public.delivery_caller_employee_id()
  from public, anon, authenticated;

-- Past days are read only.
create or replace function public.delivery_assert_day_writable(p_date date)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if p_date is null then
    raise exception 'Pick a delivery day.';
  end if;
  if p_date < public.delivery_company_today() then
    raise exception 'That day is in the past. Past days are read only.';
  end if;
end;
$$;

revoke execute on function public.delivery_assert_day_writable(date)
  from public, anon, authenticated;

-- ============================================================================
-- 5. get_delivery_day_plan — read side of the close-and-assign screen
-- ============================================================================

create or replace function public.get_delivery_day_plan(p_date date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
  v_plan record;
  v_trucks jsonb;
  v_stops jsonb;
  v_released jsonb;
  v_capacity integer;
  v_booked integer;
begin
  v_company_id := public.delivery_caller_company();
  if v_company_id is null then
    raise exception 'Only active employees can view the delivery calendar.';
  end if;
  if p_date is null then
    raise exception 'Pick a delivery day.';
  end if;

  select * into v_plan
  from public.delivery_day_plans
  where company_id = v_company_id and date = p_date;

  -- Trucks ON this date, plus any OFF truck that still has BOOKED stops
  -- assigned (flagged so the screen can warn).
  with candidate_trucks as (
    select t.id, t.name, t.default_stop_cap, t.sort_order,
           ds.is_on, ds.source
    from public.delivery_trucks t
    cross join lateral public.delivery_truck_day_state(t, p_date) ds
    where t.company_id = v_company_id and t.archived_at is null
  ),
  assigned as (
    select distinct ds.truck_id
    from public.delivery_stops ds
    where ds.company_id = v_company_id
      and ds.delivery_date = p_date
      and ds.status = 'BOOKED'
      and ds.truck_id is not null
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'truck_id', ct.id,
      'name', ct.name,
      'stop_cap', case when ct.is_on then ct.default_stop_cap else 0 end,
      'on', ct.is_on,
      'assigned_off', (not ct.is_on)
        and exists (select 1 from assigned a where a.truck_id = ct.id)
    ) order by ct.sort_order, ct.name), '[]'::jsonb)
  into v_trucks
  from candidate_trucks ct
  where ct.is_on
     or exists (select 1 from assigned a where a.truck_id = ct.id);

  select coalesce(jsonb_agg(jsonb_build_object(
      'stop_id', ds.id,
      'journey_id', ds.journey_id,
      'journey_number', sj.journey_number,
      'customer_name', trim(concat_ws(' ', cu.first_name, cu.last_name)),
      'phone', cu.phone,
      'street_address', cu.street_address,
      'street_address_line_2', cu.street_address_line_2,
      'city', cu.city,
      'state', cu.state,
      'zip_code', cu.zip_code,
      'delivery_address', trim(concat_ws(', ',
          nullif(trim(concat_ws(' ', cu.street_address, cu.street_address_line_2)), ''),
          nullif(trim(concat_ws(' ', cu.city, cu.state, cu.zip_code)), ''))),
      'truck_id', ds.truck_id,
      'route_position', ds.route_position,
      'booked_by', ds.booked_by,
      'booked_by_name', eb.name,
      'booked_at', ds.created_at,
      'inside_cutoff', ds.inside_cutoff,
      'window_start', ds.window_start,
      'window_end', ds.window_end
    ) order by ds.truck_id nulls last, ds.route_position nulls last, ds.created_at), '[]'::jsonb)
  into v_stops
  from public.delivery_stops ds
  join public.sleep_journeys sj on sj.id = ds.journey_id
  left join public.customers cu on cu.id = sj.customer_id
  left join public.employees eb on eb.id = ds.booked_by
  where ds.company_id = v_company_id
    and ds.delivery_date = p_date
    and ds.status = 'BOOKED';

  -- Stops released AFTER the day was last reviewed/closed. CANCELLED
  -- rows keep cancelled_at; SUPERSEDED rows (rescheduled away) only get
  -- updated_at, so coalesce covers both. reason_kind tells the screen
  -- whether the stop died ('cancelled') or moved to another day
  -- ('moved', with moved_to_date of the journey's live BOOKED stop).
  select coalesce(jsonb_agg(jsonb_build_object(
      'stop_id', ds.id,
      'journey_id', ds.journey_id,
      'journey_number', sj.journey_number,
      'customer_name', trim(concat_ws(' ', cu.first_name, cu.last_name)),
      'truck_id', ds.truck_id,
      'reason_kind', case when ds.status = 'CANCELLED' then 'cancelled' else 'moved' end,
      'moved_to_date', case when ds.status = 'SUPERSEDED' then (
        select ds2.delivery_date
        from public.delivery_stops ds2
        where ds2.journey_id = ds.journey_id and ds2.status = 'BOOKED'
        order by ds2.delivery_date
        limit 1
      ) end,
      'cancel_reason', ds.cancel_reason,
      'cancelled_at', coalesce(ds.cancelled_at, ds.updated_at)
    ) order by coalesce(ds.cancelled_at, ds.updated_at) desc), '[]'::jsonb)
  into v_released
  from public.delivery_stops ds
  join public.sleep_journeys sj on sj.id = ds.journey_id
  left join public.customers cu on cu.id = sj.customer_id
  where ds.company_id = v_company_id
    and ds.delivery_date = p_date
    and ds.status in ('CANCELLED', 'SUPERSEDED')
    and ds.truck_id is not null
    and coalesce(ds.cancelled_at, ds.updated_at)
        > coalesce(v_plan.reviewed_at, v_plan.closed_at, '-infinity'::timestamptz);

  v_capacity := public.delivery_day_capacity(v_company_id, p_date);
  select count(*) into v_booked
  from public.delivery_stops ds
  where ds.company_id = v_company_id
    and ds.delivery_date = p_date
    and ds.status in ('BOOKED', 'COMPLETED');

  return jsonb_build_object(
    'plan', case when v_plan.company_id is null then jsonb_build_object(
        'status', 'OPEN', 'version', 0, 'closed_at', null,
        'closed_by_name', null, 'reviewed_at', null
      ) else jsonb_build_object(
        'status', v_plan.status,
        'version', v_plan.version,
        'closed_at', v_plan.closed_at,
        'closed_by_name', (select e.name from public.employees e where e.id = v_plan.closed_by),
        'reopened_at', v_plan.reopened_at,
        'reviewed_at', v_plan.reviewed_at
      ) end,
    'trucks', v_trucks,
    'stops', v_stops,
    'released_after_review', v_released,
    'capacity', v_capacity,
    'booked_count', v_booked,
    'today_local', public.delivery_company_today()
  );
end;
$$;

revoke execute on function public.get_delivery_day_plan(date)
  from public, anon;
grant execute on function public.get_delivery_day_plan(date) to authenticated;

-- ============================================================================
-- 6. save_delivery_day_route — bulk route write, one transaction
--
-- p_stops = [{stop_id, truck_id (null = unrouted), route_position}] for
-- the BOOKED stops on this date. Positions are renumbered 1..n per truck
-- inside the function. Stops missing from the payload become unrouted.
-- Over-cap and OFF-truck assignments are warn-only (the screen warns);
-- the only rejections are structural.
-- ============================================================================

create or replace function public.save_delivery_day_route(
  p_date date,
  p_expected_version integer,
  p_stops jsonb
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
  v_employee_id uuid;
  v_plan record;
  v_new_version integer;
  v_item record;
  v_stop record;
  v_stop_ids uuid[];
  v_truck_company uuid;
  v_truck_archived timestamptz;
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

  -- Same (company, date) lock the booking RPCs take.
  perform pg_advisory_xact_lock(
    hashtextextended(v_company_id::text || ':' || p_date::text, 0)
  );

  select * into v_plan
  from public.delivery_day_plans
  where company_id = v_company_id and date = p_date
  for update;

  if coalesce(v_plan.version, 0) <> coalesce(p_expected_version, -1) then
    raise exception 'This day was changed by someone else. Reload and try again.';
  end if;
  if v_plan.status = 'CLOSED' then
    raise exception 'This day is closed. Reopen it to change the route.';
  end if;

  if p_stops is null or jsonb_typeof(p_stops) <> 'array' then
    raise exception 'Send the list of stops for this day.';
  end if;

  -- Snapshot every BOOKED stop's current route for the audit diff.
  -- to_regclass guard avoids the NOTICE a bare DROP IF EXISTS raises.
  if to_regclass('d132_route_old') is null then
    create temp table d132_route_old (
      stop_id uuid primary key,
      truck_id uuid,
      route_position integer
    ) on commit drop;
  else
    truncate d132_route_old;
  end if;
  insert into pg_temp.d132_route_old (stop_id, truck_id, route_position)
  select ds.id, ds.truck_id, ds.route_position
  from public.delivery_stops ds
  where ds.company_id = v_company_id
    and ds.delivery_date = p_date
    and ds.status = 'BOOKED';

  -- Validate the payload: every stop must be a BOOKED stop of this
  -- company on this date, every truck must be this company's and not
  -- archived, and no two stops may claim the same position on a truck.
  for v_item in
    select (s->>'stop_id')::uuid as stop_id,
           nullif(s->>'truck_id', '')::uuid as truck_id,
           (s->>'route_position')::integer as route_position
    from jsonb_array_elements(p_stops) s
  loop
    if v_item.stop_id is null or v_item.stop_id = any(v_stop_ids) then
      raise exception 'This day was changed by someone else. Reload and try again.';
    end if;
    v_stop_ids := array_append(v_stop_ids, v_item.stop_id);

    select ds.id into v_stop
    from public.delivery_stops ds
    where ds.id = v_item.stop_id
      and ds.company_id = v_company_id
      and ds.delivery_date = p_date
      and ds.status = 'BOOKED';
    if v_stop.id is null then
      raise exception 'This day was changed by someone else. Reload and try again.';
    end if;

    if v_item.truck_id is not null then
      select t.company_id, t.archived_at
        into v_truck_company, v_truck_archived
      from public.delivery_trucks t where t.id = v_item.truck_id;
      if v_truck_company is null or v_truck_company <> v_company_id then
        raise exception 'That truck is not in your company.';
      end if;
      if v_truck_archived is not null then
        raise exception 'That truck is archived.';
      end if;
      if v_item.truck_id is not null
         and v_item.route_position is not null
         and v_item.route_position <= 0 then
        raise exception 'Positions start at 1.';
      end if;
    end if;
  end loop;

  if exists (
    select 1
    from jsonb_array_elements(p_stops) s
    where nullif(s->>'truck_id', '') is not null
      and nullif(s->>'route_position', '') is not null
    group by s->>'truck_id', s->>'route_position'
    having count(*) > 1
  ) then
    raise exception 'Two stops cannot share the same position on a truck.';
  end if;

  -- Clear EVERY BOOKED stop's route in one update first, so no
  -- intermediate state can hold two stops at one (truck, position).
  -- Stops missing from the payload, and payload stops with truck_id
  -- null, stay unrouted.
  update public.delivery_stops ds
  set truck_id = null, route_position = null
  where ds.company_id = v_company_id
    and ds.delivery_date = p_date
    and ds.status = 'BOOKED';

  -- Compute final dense positions 1..n per truck in one update:
  -- submitted position first, then booked order for stops submitted
  -- without a position. Submitted gaps (1,3,5) collapse to 1,2,3.
  with payload as (
    select (s->>'stop_id')::uuid as stop_id,
           nullif(s->>'truck_id', '')::uuid as truck_id,
           (s->>'route_position')::integer as submitted_pos
    from jsonb_array_elements(p_stops) s
  ),
  final as (
    select p.stop_id, p.truck_id,
           row_number() over (
             partition by p.truck_id
             order by p.submitted_pos nulls last, ds.created_at, p.stop_id
           ) as rn
    from payload p
    join public.delivery_stops ds on ds.id = p.stop_id
    where p.truck_id is not null
  )
  update public.delivery_stops ds
  set truck_id = f.truck_id,
      route_position = f.rn
  from final f
  where ds.id = f.stop_id;

  -- Audit: one event per stop whose truck or final position changed.
  insert into public.delivery_route_events (
    company_id, date, stop_id, journey_id, action,
    from_truck_id, to_truck_id, from_position, to_position, actor_id
  )
  select v_company_id, p_date, ds.id, ds.journey_id,
         case
           when old.truck_id is null and ds.truck_id is not null then 'TRUCK_ASSIGNED'
           when old.truck_id is not null and ds.truck_id is null then 'UNROUTED'
           when old.truck_id is distinct from ds.truck_id then 'TRUCK_ASSIGNED'
           else 'REORDERED'
         end,
         old.truck_id, ds.truck_id, old.route_position, ds.route_position,
         v_employee_id
  from public.delivery_stops ds
  join pg_temp.d132_route_old old on old.stop_id = ds.id
  where ds.company_id = v_company_id
    and ds.delivery_date = p_date
    and ds.status = 'BOOKED'
    and (old.truck_id is distinct from ds.truck_id
         or old.route_position is distinct from ds.route_position);

  insert into public.delivery_day_plans (
    company_id, date, status, version, reviewed_at, updated_at
  )
  values (v_company_id, p_date, 'OPEN', 1, now(), now())
  on conflict (company_id, date) do update
    set version = public.delivery_day_plans.version + 1,
        reviewed_at = now(),
        updated_at = now();

  v_new_version := coalesce(v_plan.version, 0) + 1;

  return v_new_version;
end;
$$;

revoke execute on function public.save_delivery_day_route(date, integer, jsonb)
  from public, anon;
grant execute on function public.save_delivery_day_route(date, integer, jsonb)
  to authenticated;

-- ============================================================================
-- 7. close_delivery_day / reopen_delivery_day
-- ============================================================================

create or replace function public.close_delivery_day(
  p_date date,
  p_expected_version integer
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
  v_employee_id uuid;
  v_plan record;
  v_new_version integer;
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

  perform pg_advisory_xact_lock(
    hashtextextended(v_company_id::text || ':' || p_date::text, 0)
  );

  select * into v_plan
  from public.delivery_day_plans
  where company_id = v_company_id and date = p_date
  for update;

  if coalesce(v_plan.version, 0) <> coalesce(p_expected_version, -1) then
    raise exception 'This day was changed by someone else. Reload and try again.';
  end if;
  if v_plan.status = 'CLOSED' then
    raise exception 'That day is already closed.';
  end if;

  insert into public.delivery_day_plans (
    company_id, date, status, version, closed_at, closed_by,
    reviewed_at, updated_at
  )
  values (v_company_id, p_date, 'CLOSED', 1, now(), v_employee_id,
          now(), now())
  on conflict (company_id, date) do update
    set status = 'CLOSED',
        closed_at = now(),
        closed_by = v_employee_id,
        reviewed_at = now(),
        version = public.delivery_day_plans.version + 1,
        updated_at = now();

  insert into public.delivery_route_events (
    company_id, date, action, actor_id
  ) values (
    v_company_id, p_date, 'PLAN_CLOSED', v_employee_id
  );

  v_new_version := coalesce(v_plan.version, 0) + 1;
  return v_new_version;
end;
$$;

revoke execute on function public.close_delivery_day(date, integer)
  from public, anon;
grant execute on function public.close_delivery_day(date, integer)
  to authenticated;

create or replace function public.reopen_delivery_day(
  p_date date,
  p_expected_version integer
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
  v_employee_id uuid;
  v_plan record;
  v_new_version integer;
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

  perform pg_advisory_xact_lock(
    hashtextextended(v_company_id::text || ':' || p_date::text, 0)
  );

  select * into v_plan
  from public.delivery_day_plans
  where company_id = v_company_id and date = p_date
  for update;

  if coalesce(v_plan.version, 0) <> coalesce(p_expected_version, -1) then
    raise exception 'This day was changed by someone else. Reload and try again.';
  end if;
  if v_plan.status is distinct from 'CLOSED' then
    raise exception 'That day is not closed.';
  end if;

  -- Assignments, order and windows are KEPT; only the status flips.
  update public.delivery_day_plans
  set status = 'OPEN',
      reopened_at = now(),
      reopened_by = v_employee_id,
      version = version + 1,
      updated_at = now()
  where company_id = v_company_id and date = p_date;

  insert into public.delivery_route_events (
    company_id, date, action, actor_id
  ) values (
    v_company_id, p_date, 'PLAN_REOPENED', v_employee_id
  );

  v_new_version := coalesce(v_plan.version, 0) + 1;
  return v_new_version;
end;
$$;

revoke execute on function public.reopen_delivery_day(date, integer)
  from public, anon;
grant execute on function public.reopen_delivery_day(date, integer)
  to authenticated;

-- ============================================================================
-- 8. suggest_delivery_assignments — read-only grouping proposal
--
-- Fills the ON trucks in sequence with CONTIGUOUS blocks of unrouted
-- stops (sorted by delivery zip, then booked order), each block up to the
-- truck's stop_cap. Already-assigned stops stay where they are. Stops
-- that do not fit are returned as overflow.
--
-- This is a rough geographic grouping until delivery zones exist (D2):
-- zip order is a proxy for "same side of town", NOT route optimization.
-- Round robin was rejected — it would mix North and South stops on one
-- truck.
-- ============================================================================

create or replace function public.suggest_delivery_assignments(p_date date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
  v_unrouted jsonb;
  v_trucks jsonb;
begin
  v_company_id := public.delivery_caller_company();
  if v_company_id is null then
    raise exception 'Only active employees can view the delivery calendar.';
  end if;
  if p_date is null then
    raise exception 'Pick a delivery day.';
  end if;

  -- Unrouted BOOKED stops, sorted by customer zip then booked order.
  select coalesce(jsonb_agg(jsonb_build_object(
      'stop_id', ds.id, 'zip', cu.zip_code, 'created_at', ds.created_at
    ) order by cu.zip_code nulls last, ds.created_at), '[]'::jsonb)
  into v_unrouted
  from public.delivery_stops ds
  join public.sleep_journeys sj on sj.id = ds.journey_id
  left join public.customers cu on cu.id = sj.customer_id
  where ds.company_id = v_company_id
    and ds.delivery_date = p_date
    and ds.status = 'BOOKED'
    and ds.truck_id is null;

  with trucks_on as (
    select t.id, t.name, t.default_stop_cap, t.sort_order,
           row_number() over (order by t.sort_order, t.name) as seq
    from public.delivery_trucks t
    cross join lateral public.delivery_truck_day_state(t, p_date) ds
    where t.company_id = v_company_id
      and t.archived_at is null
      and ds.is_on
  ),
  capacities as (
    select id, name, default_stop_cap as cap, seq,
           sum(default_stop_cap) over (order by seq) as cum_cap
    from trucks_on
  ),
  numbered as (
    select (e->>'stop_id')::uuid as stop_id,
           row_number() over (order by ord) as n
    from jsonb_array_elements(v_unrouted) with ordinality as t(e, ord)
  )
  select jsonb_build_object(
    'assignments', coalesce((
      select jsonb_agg(jsonb_build_object(
        'truck_id', stops.id, 'name', stops.name, 'stop_ids', stops.ids
      )) from (
        select c.id, c.name,
               jsonb_agg(n.stop_id order by n.n) as ids
        from capacities c
        join numbered n
          on n.n > coalesce((
                select c2.cum_cap from capacities c2 where c2.seq = c.seq - 1
              ), 0)
         and n.n <= c.cum_cap
        group by c.id, c.name
      ) stops
    ), '[]'::jsonb),
    'overflow', coalesce((
      select jsonb_agg(n.stop_id order by n.n)
      from numbered n
      where n.n > coalesce((select max(cum_cap) from capacities), 0)
    ), '[]'::jsonb)
  ) into v_trucks;

  return v_trucks;
end;
$$;

revoke execute on function public.suggest_delivery_assignments(date)
  from public, anon;
grant execute on function public.suggest_delivery_assignments(date)
  to authenticated;
