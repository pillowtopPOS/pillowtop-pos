-- PillowTop POS m129: D1-b delivery stop booking engine.
--
-- A stop = one order (journey) on one delivery day. Salespeople pick a
-- DAY, never a truck; capacity stays the pooled per-day number from D1-a.
--
-- Decisions baked in here:
--   * Earliest bookable day is TOMORROW in the fulfilling warehouse's
--     local time (resolve_journey_inventory_location -> stores.timezone
--     -> companies.business_timezone). companies.delivery_cutoff_time
--     (nullable = no cutoff; default 15:00) pushes it one more day once
--     the local time is at/after the cutoff.
--   * delivery.book_inside_cutoff (owner/admin by default) lets a caller
--     book before the earliest day — never today or the past — with a
--     required reason; the stop is flagged inside_cutoff.
--   * Full days reject callers without delivery.manage_calendar.
--   * booking/reschedule/cancel are single RPCs that lock the day
--     (pg_advisory_xact_lock), write the stop, write the append-only
--     delivery_stop_events log row, and insert the journey_event in ONE
--     transaction.
--   * delivery_scheduled / delivery_unscheduled journey_events can ONLY
--     be written by those RPCs (transaction-local GUC + matching stop
--     row check in a journey_events trigger). Direct inserts are
--     rejected — see section 7 for the mechanism and its limits.
--   * Pickup journeys are not bookable.
--   * No backfill: legacy Scheduled journeys keep working and simply
--     have no stop ("not on the calendar") until someone books them.
--
-- Enum note: 'delivery_unscheduled' is added at the top. It is only
-- referenced inside plpgsql function BODIES (never executed at migration
-- time), which is safe in one file — same pattern concern as 096/097,
-- but plpgsql bodies are not parsed at CREATE time.

-- ============================================================================
-- 1. New journey event type (plpgsql-only references below)
-- ============================================================================

alter type public.journey_event_type add value if not exists 'delivery_unscheduled';

-- ============================================================================
-- 2. Company setting: delivery cutoff time (nullable = no cutoff)
-- ============================================================================

alter table public.companies
  add column if not exists delivery_cutoff_time time default '15:00';

-- ============================================================================
-- 3. Permission key delivery.book_inside_cutoff — owner/admin only by
--    default, same seed pattern as the other delivery keys (124-126).
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
    'delivery.book_inside_cutoff'
  );
$$;

revoke execute on function public.is_valid_permission_key(text) from anon;

-- Existing companies: owner + admin only.
insert into public.role_permission_grants (company_id, role, permission_key)
select c.id, g.role, 'delivery.book_inside_cutoff'
from public.companies c
cross join (values ('owner'), ('admin')) as g (role)
on conflict do nothing;

-- New companies: same, via the existing seed trigger (126 version + new key).
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
    (new.id, 'admin', 'delivery.book_inside_cutoff')
  on conflict do nothing;
  return new;
end;
$$;

revoke execute on function public.trg_seed_delivery_permissions()
  from authenticated, anon, public;

-- ============================================================================
-- 4. Tables
-- ============================================================================

create table if not exists public.delivery_stops (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  store_id uuid not null references public.stores (id),
  journey_id uuid not null references public.sleep_journeys (id) on delete cascade,
  delivery_date date not null,
  status text not null default 'BOOKED'
    check (status in ('BOOKED', 'COMPLETED', 'CANCELLED', 'SUPERSEDED')),
  inside_cutoff boolean not null default false,
  override_reason text,
  booked_by uuid,
  cancelled_at timestamptz,
  cancel_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- At most one ACTIVE (BOOKED) stop per order.
create unique index if not exists delivery_stops_one_booked_per_journey
  on public.delivery_stops (journey_id)
  where status = 'BOOKED';

-- Calendar counts: booked = BOOKED + COMPLETED for the date.
create index if not exists delivery_stops_company_date_active
  on public.delivery_stops (company_id, delivery_date)
  where status in ('BOOKED', 'COMPLETED');

create table if not exists public.delivery_stop_events (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  stop_id uuid not null references public.delivery_stops (id) on delete cascade,
  journey_id uuid not null references public.sleep_journeys (id) on delete cascade,
  action text not null check (action in ('BOOKED', 'RESCHEDULED', 'CANCELLED', 'COMPLETED')),
  from_date date,
  to_date date,
  reason text,
  "override" boolean not null default false,
  actor_id uuid,
  created_at timestamptz not null default now()
);

create index if not exists delivery_stop_events_stop
  on public.delivery_stop_events (stop_id);
create index if not exists delivery_stop_events_journey
  on public.delivery_stop_events (journey_id);
create index if not exists delivery_stop_events_company
  on public.delivery_stop_events (company_id, created_at);

alter table public.delivery_stops enable row level security;
alter table public.delivery_stop_events enable row level security;

-- No client policies: all access goes through the security-definer RPCs.

-- Append-only audit log: no update, no delete for any role.
create or replace function public.delivery_stop_events_immutable()
returns trigger
language plpgsql
as $$
begin
  raise exception 'Delivery stop history cannot be changed.';
end;
$$;

drop trigger if exists trg_delivery_stop_events_immutable on public.delivery_stop_events;
create trigger trg_delivery_stop_events_immutable
before update or delete on public.delivery_stop_events
for each row execute function public.delivery_stop_events_immutable();

revoke execute on function public.delivery_stop_events_immutable()
  from public, anon, authenticated;

-- ============================================================================
-- 5. One capacity formula, shared by the calendar read and the booking RPCs
-- ============================================================================

create or replace function public.delivery_day_capacity(
  p_company_id uuid,
  p_date date
)
returns integer
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_pattern integer;
  v_extra integer;
begin
  select coalesce(sum(
    case when ds.is_on then t.default_stop_cap else 0 end
  ), 0)
  into v_pattern
  from public.delivery_trucks t
  cross join lateral public.delivery_truck_day_state(t, p_date) ds
  where t.company_id = p_company_id
    and t.archived_at is null;

  select coalesce(a.extra_slots, 0) into v_extra
  from (select 1) one
  left join public.delivery_day_adjustments a
    on a.company_id = p_company_id and a.date = p_date;

  return greatest(0, v_pattern + v_extra);
end;
$$;

revoke execute on function public.delivery_day_capacity(uuid, date)
  from public, anon, authenticated;

-- ============================================================================
-- 6. event_to_state: delivery_unscheduled returns the order to
--    "Ready to Schedule" so it reappears in the Needs scheduling queue.
--    (006b body + one new WHEN.)
-- ============================================================================

create or replace function public.event_to_state(evt public.journey_event_type)
returns public.journey_state
language plpgsql
stable
as $$
begin
  return case evt
    when 'quote_created' then 'Quoted'::public.journey_state
    when 'quote_sent' then 'Quoted'::public.journey_state
    when 'deposit_received' then 'Quoted'::public.journey_state
    when 'payment_completed' then 'Quoted'::public.journey_state
    when 'inventory_required' then 'Waiting for Inventory'::public.journey_state
    when 'inventory_received' then 'Ready to Schedule'::public.journey_state
    when 'delivery_scheduled' then 'Scheduled'::public.journey_state
    when 'delivery_unscheduled' then 'Ready to Schedule'::public.journey_state
    when 'delivery_completed' then 'Sleep Trial'::public.journey_state
    when 'trial_completed' then 'Completed'::public.journey_state
    when 'journey_updated_to_sold' then 'Sold'::public.journey_state
    when 'line_items_changed_balance_due' then 'Quoted'::public.journey_state
    else null
  end;
end;
$$;

-- ============================================================================
-- 7. derive_journey_state: identical to 020 plus ONE added block — when a
--    delivery_completed event lands, the order's BOOKED stop flips to
--    COMPLETED and the log gets a COMPLETED row. Legacy orders with no
--    stop are untouched (update finds nothing).
-- ============================================================================

create or replace function public.derive_journey_state()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  target public.journey_state;
  journey_price numeric;
  paid numeric;
  new_price numeric;
  store_rec public.stores%rowtype;
  emp_id uuid;
  follow_up_due timestamptz;
  max_due timestamptz;
  cadence int;
  v_written_sale_id uuid;
  v_previous_committed numeric;
  v_new_committed numeric;
  v_adjustment numeric;
  v_stop_id uuid;
  v_stop_company uuid;
  v_stop_date date;
  v_stop_actor uuid;
begin
  select id into emp_id
  from public.employees
  where auth_user_id = auth.uid();

  if new.event_type = 'journey_cancelled' then
    update public.sleep_journeys
    set cancelled_at = now(),
        cancelled_reason = coalesce(new.event_data->>'reason', 'No reason provided'),
        updated_at = now()
    where id = new.journey_id;

    update public.follow_ups
    set completed_at = now()
    where journey_id = new.journey_id
      and completed_at is null;

    select id into v_written_sale_id
    from public.written_sales
    where order_id = new.journey_id;

    if v_written_sale_id is not null then
      v_previous_committed := (
        select ws.qualifying_order_amount + coalesce(sum(wsa.adjustment_amount), 0)
        from public.written_sales ws
        left join public.written_sale_adjustments wsa on wsa.written_sale_id = ws.id
        where ws.id = v_written_sale_id
        group by ws.qualifying_order_amount
      );

      v_new_committed := 0;
      v_adjustment := v_new_committed - v_previous_committed;

      insert into public.written_sale_adjustments (
        written_sale_id,
        tenant_id,
        order_id,
        adjustment_amount,
        previous_qualifying_committed_amount,
        new_qualifying_committed_amount,
        adjustment_type,
        adjustment_reason,
        actor_id
      )
      select
        v_written_sale_id,
        ws.tenant_id,
        new.journey_id,
        v_adjustment,
        v_previous_committed,
        v_new_committed,
        'cancellation',
        coalesce(new.event_data->>'reason', 'No reason provided'),
        new.triggered_by
      from public.written_sales ws
      where ws.id = v_written_sale_id;
    end if;

    return new;
  end if;

  target := public.event_to_state(new.event_type);

  if target is null then
    return new;
  end if;

  if new.event_type in ('deposit_received', 'payment_completed') then
    if new.outcome = 'SUCCEEDED' then
      select price into journey_price
      from public.sleep_journeys
      where id = new.journey_id;

      paid := public.total_paid(new.journey_id);

      if journey_price is not null and paid >= journey_price then
        target := 'Sold'::public.journey_state;
      else
        target := 'Quoted'::public.journey_state;
      end if;
    else
      target := 'Quoted'::public.journey_state;
    end if;
  end if;

  if new.event_type in ('quote_created', 'quote_sent')
    and new.event_data->>'amount' ~ '^[0-9]+(\.[0-9]+)?$'
  then
    new_price := (new.event_data->>'amount')::numeric;
  end if;

  update public.sleep_journeys
  set current_state = target,
      price = coalesce(price, new_price),
      updated_at = now()
  where id = new.journey_id;

  if target = 'Sold'::public.journey_state then
    update public.follow_ups
    set completed_at = now()
    where journey_id = new.journey_id
      and completed_at is null;
  end if;

  if new.event_type = 'quote_sent' then
    select * into store_rec
    from public.stores
    where id = (select store_id from public.sleep_journeys where id = new.journey_id);

    for cadence in
      select jsonb_array_elements_text(coalesce(store_rec.quote_follow_up_cadence, '[1]'::jsonb))::int
    loop
      insert into public.follow_ups (journey_id, employee_id, type, due_at, notes)
      values (
        new.journey_id,
        emp_id,
        'quote',
        new.created_at + (cadence || ' days')::interval,
        'Quote follow-up (day ' || cadence || ')'
      );
    end loop;
  end if;

  if new.event_type = 'deposit_received' and new.outcome = 'SUCCEEDED' then
    select * into store_rec
    from public.stores
    where id = (select store_id from public.sleep_journeys where id = new.journey_id);

    follow_up_due := new.created_at + (store_rec.deposit_follow_up_default_days || ' days')::interval;
    max_due := new.created_at + (store_rec.deposit_follow_up_max_days || ' days')::interval;

    if new.event_data->>'follow_up_due_at' is not null then
      begin
        follow_up_due := (new.event_data->>'follow_up_due_at')::timestamptz;
      exception when others then
        follow_up_due := new.created_at + (store_rec.deposit_follow_up_default_days || ' days')::interval;
      end;

      if follow_up_due > max_due then
        follow_up_due := max_due;
      end if;
      if follow_up_due < new.created_at then
        follow_up_due := new.created_at;
      end if;
    end if;

    insert into public.follow_ups (journey_id, employee_id, type, due_at, notes)
    values (
      new.journey_id,
      emp_id,
      'deposit',
      follow_up_due,
      'Deposit follow-up: balance due'
    );
  end if;

  -- m129: Mark Delivered closes the order's open delivery stop and logs
  -- COMPLETED. Orders with no stop (legacy) match nothing.
  if new.event_type = 'delivery_completed' then
    update public.delivery_stops
    set status = 'COMPLETED',
        updated_at = now()
    where journey_id = new.journey_id
      and status = 'BOOKED'
    returning id, company_id, delivery_date into v_stop_id, v_stop_company, v_stop_date;

    if v_stop_id is not null then
      select e.id into v_stop_actor
      from public.employees e
      where e.auth_user_id = auth.uid() and e.is_active;

      insert into public.delivery_stop_events (
        company_id, stop_id, journey_id, action, to_date, actor_id
      ) values (
        v_stop_company, v_stop_id, new.journey_id, 'COMPLETED',
        v_stop_date, v_stop_actor
      );
    end if;
  end if;

  return new;
end;
$$;

-- ============================================================================
-- 8. Insert guard: delivery_scheduled / delivery_unscheduled journey_events
--    may only be written by the booking RPCs. Mechanism:
--      a) the RPC sets a TRANSACTION-LOCAL GUC
--         (set_config('pillowtop.delivery_event_write','on',true)) — it
--         dies with the transaction and cannot be set through PostgREST;
--      b) the trigger ALSO requires a matching stop row: a BOOKED stop at
--         the event's delivery_date for delivery_scheduled, or a
--         CANCELLED stop for the journey for delivery_unscheduled.
--    Limit: this stops application-level writes (the board's direct
--    journey_events insert, any future client code). It cannot stop
--    someone with direct database access, and it does not stop OTHER
--    event types — only these two are guarded.
-- ============================================================================

create or replace function public.guard_delivery_event_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_date date;
begin
  if new.event_type not in ('delivery_scheduled', 'delivery_unscheduled') then
    return new;
  end if;

  if coalesce(current_setting('pillowtop.delivery_event_write', true), '') <> 'on' then
    raise exception 'Delivery scheduling must go through the delivery stop functions.';
  end if;

  if new.event_type = 'delivery_scheduled' then
    v_date := nullif(new.event_data->>'delivery_date', '')::date;
    if v_date is null or not exists (
      select 1 from public.delivery_stops ds
      where ds.journey_id = new.journey_id
        and ds.delivery_date = v_date
        and ds.status = 'BOOKED'
    ) then
      raise exception 'Delivery scheduling must go through the delivery stop functions.';
    end if;
  else
    if not exists (
      select 1 from public.delivery_stops ds
      where ds.journey_id = new.journey_id
        and ds.status = 'CANCELLED'
    ) then
      raise exception 'Delivery scheduling must go through the delivery stop functions.';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_guard_delivery_event_insert on public.journey_events;
create trigger trg_guard_delivery_event_insert
before insert on public.journey_events
for each row execute function public.guard_delivery_event_insert();

revoke execute on function public.guard_delivery_event_insert()
  from public, anon, authenticated;

-- ============================================================================
-- 9. Read helper: earliest bookable date + the cutoff in use, computed
--    server-side so screens never do this math in the browser.
--    Returns jsonb: { earliest_date, cutoff_time, timezone, today_local }.
-- ============================================================================

create or replace function public.get_earliest_bookable_date(p_journey_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
  v_source_store uuid;
  v_store_tz text;
  v_business_tz text;
  v_cutoff time;
  v_tz text;
  v_now_local timestamp;
  v_today date;
  v_earliest date;
begin
  v_company_id := public.delivery_caller_company();
  if v_company_id is null then
    raise exception 'Only active employees can view the delivery calendar.';
  end if;

  select public.resolve_journey_inventory_location(p_journey_id)
    into v_source_store;
  if v_source_store is null then
    raise exception 'That order was not found.';
  end if;

  -- Same-company only.
  if not exists (
    select 1 from public.stores s
    join public.sleep_journeys sj on sj.store_id = s.id
    where sj.id = p_journey_id and s.company_id = v_company_id
  ) then
    raise exception 'That order is not in your company.';
  end if;

  select s.timezone into v_store_tz
  from public.stores s where s.id = v_source_store;

  select c.business_timezone, c.delivery_cutoff_time
    into v_business_tz, v_cutoff
  from public.companies c where c.id = v_company_id;

  v_tz := coalesce(v_store_tz, v_business_tz);
  v_now_local := now() at time zone v_tz;
  v_today := v_now_local::date;
  v_earliest := v_today + 1;
  if v_cutoff is not null and v_now_local::time >= v_cutoff then
    v_earliest := v_today + 2;
  end if;

  return jsonb_build_object(
    'earliest_date', v_earliest,
    'cutoff_time', v_cutoff,
    'timezone', v_tz,
    'today_local', v_today
  );
end;
$$;

grant execute on function public.get_earliest_bookable_date(uuid) to authenticated;

-- ============================================================================
-- 10. book_delivery_stop
-- ============================================================================

create or replace function public.book_delivery_stop(
  p_journey_id uuid,
  p_date date,
  p_override_reason text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
  v_employee_id uuid;
  v_journey record;
  v_earliest jsonb;
  v_earliest_date date;
  v_today date;
  v_inside boolean := false;
  v_reason text := nullif(trim(coalesce(p_override_reason, '')), '');
  v_capacity integer;
  v_booked integer;
  v_stop_id uuid;
begin
  v_company_id := public.delivery_caller_company();
  if v_company_id is null then
    raise exception 'Only active employees can book deliveries.';
  end if;

  select e.id into v_employee_id
  from public.employees e
  where e.auth_user_id = auth.uid() and e.is_active;
  if v_employee_id is null then
    raise exception 'Only active employees can book deliveries.';
  end if;

  select sj.id, sj.current_state::text as current_state,
         sj.fulfillment_type::text as fulfillment_type, sj.store_id,
         sj.cancelled_at, s.company_id
  into v_journey
  from public.sleep_journeys sj
  join public.stores s on s.id = sj.store_id
  where sj.id = p_journey_id;

  if v_journey.id is null or v_journey.company_id <> v_company_id then
    raise exception 'That order is not in your company.';
  end if;
  if v_journey.cancelled_at is not null then
    raise exception 'That order is cancelled.';
  end if;
  if not public.is_journey_visible(p_journey_id) then
    raise exception 'You cannot schedule deliveries for that order.';
  end if;
  if v_journey.fulfillment_type <> 'delivery' then
    raise exception 'Pickup orders don''t go on a delivery truck.';
  end if;

  -- Ready to Schedule, or legacy Scheduled with no active stop.
  if v_journey.current_state = 'Scheduled' then
    if exists (
      select 1 from public.delivery_stops ds
      where ds.journey_id = p_journey_id and ds.status = 'BOOKED'
    ) then
      raise exception 'That order already has a delivery booked. Reschedule it instead.';
    end if;
  elsif v_journey.current_state <> 'Ready to Schedule' then
    raise exception 'That order is not ready to schedule a delivery.';
  end if;

  if p_date is null then
    raise exception 'Pick a delivery day.';
  end if;

  v_earliest := public.get_earliest_bookable_date(p_journey_id);
  v_earliest_date := (v_earliest->>'earliest_date')::date;
  v_today := (v_earliest->>'today_local')::date;

  -- Today and the past are NEVER bookable, override or not.
  if p_date <= v_today then
    raise exception 'Deliveries can''t be booked for today or earlier.';
  end if;

  if p_date < v_earliest_date then
    if not public.has_permission('delivery.book_inside_cutoff') then
      raise exception 'Booking before % requires the inside-cutoff permission.',
        to_char(v_earliest_date, 'Dy Mon FMDD');
    end if;
    if v_reason is null then
      raise exception 'Give a reason for booking inside the cutoff window.';
    end if;
    v_inside := true;
  end if;

  -- Lock the day, then check capacity.
  perform pg_advisory_xact_lock(
    hashtextextended(v_company_id::text || ':' || p_date::text, 0)
  );

  v_capacity := public.delivery_day_capacity(v_company_id, p_date);
  select count(*) into v_booked
  from public.delivery_stops ds
  where ds.company_id = v_company_id
    and ds.delivery_date = p_date
    and ds.status in ('BOOKED', 'COMPLETED');

  if v_capacity - v_booked <= 0
     and not public.has_permission('delivery.manage_calendar') then
    raise exception 'That day is fully booked. Ask someone who manages the delivery calendar to add spots.';
  end if;

  insert into public.delivery_stops (
    company_id, store_id, journey_id, delivery_date, status,
    inside_cutoff, override_reason, booked_by
  ) values (
    v_company_id, v_journey.store_id, p_journey_id, p_date, 'BOOKED',
    v_inside, case when v_inside then v_reason else null end, v_employee_id
  ) returning id into v_stop_id;

  insert into public.delivery_stop_events (
    company_id, stop_id, journey_id, action, to_date, reason, "override", actor_id
  ) values (
    v_company_id, v_stop_id, p_journey_id, 'BOOKED', p_date,
    case when v_inside then v_reason else null end, v_inside, v_employee_id
  );

  -- Arm the guard, then write the journey event (trigger verifies the
  -- matching BOOKED stop exists — inserted above, same transaction).
  perform set_config('pillowtop.delivery_event_write', 'on', true);
  insert into public.journey_events (journey_id, event_type, event_data, triggered_by)
  values (
    p_journey_id,
    'delivery_scheduled',
    jsonb_build_object('delivery_date', p_date::text, 'delivery_stop_id', v_stop_id),
    auth.uid()::text
  );

  return v_stop_id;
end;
$$;

grant execute on function public.book_delivery_stop(uuid, date, text) to authenticated;

-- ============================================================================
-- 11. reschedule_delivery_stop — old row SUPERSEDED, new BOOKED row, one
--     transaction, both days locked in ascending order (no deadlock).
-- ============================================================================

create or replace function public.reschedule_delivery_stop(
  p_stop_id uuid,
  p_new_date date,
  p_override_reason text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
  v_employee_id uuid;
  v_stop record;
  v_journey_state text;
  v_earliest jsonb;
  v_earliest_date date;
  v_today date;
  v_inside boolean := false;
  v_reason text := nullif(trim(coalesce(p_override_reason, '')), '');
  v_capacity integer;
  v_booked integer;
  v_new_stop_id uuid;
begin
  v_company_id := public.delivery_caller_company();
  if v_company_id is null then
    raise exception 'Only active employees can reschedule deliveries.';
  end if;

  select e.id into v_employee_id
  from public.employees e
  where e.auth_user_id = auth.uid() and e.is_active;
  if v_employee_id is null then
    raise exception 'Only active employees can reschedule deliveries.';
  end if;

  select ds.id, ds.journey_id, ds.delivery_date, ds.company_id
  into v_stop
  from public.delivery_stops ds
  where ds.id = p_stop_id and ds.status = 'BOOKED';

  if v_stop.id is null or v_stop.company_id <> v_company_id then
    raise exception 'That delivery was not found.';
  end if;

  if not public.is_journey_visible(v_stop.journey_id) then
    raise exception 'You cannot schedule deliveries for that order.';
  end if;

  select sj.current_state::text into v_journey_state
  from public.sleep_journeys sj
  where sj.id = v_stop.journey_id and sj.cancelled_at is null;
  if v_journey_state is distinct from 'Scheduled' then
    raise exception 'That order is no longer scheduled for delivery.';
  end if;

  if p_new_date is null then
    raise exception 'Pick a delivery day.';
  end if;
  if p_new_date = v_stop.delivery_date then
    raise exception 'That order is already booked for that day.';
  end if;

  v_earliest := public.get_earliest_bookable_date(v_stop.journey_id);
  v_earliest_date := (v_earliest->>'earliest_date')::date;
  v_today := (v_earliest->>'today_local')::date;

  if p_new_date <= v_today then
    raise exception 'Deliveries can''t be booked for today or earlier.';
  end if;

  if p_new_date < v_earliest_date then
    if not public.has_permission('delivery.book_inside_cutoff') then
      raise exception 'Booking before % requires the inside-cutoff permission.',
        to_char(v_earliest_date, 'Dy Mon FMDD');
    end if;
    if v_reason is null then
      raise exception 'Give a reason for booking inside the cutoff window.';
    end if;
    v_inside := true;
  end if;

  -- Lock BOTH days in ascending order so two reschedules between the
  -- same two days cannot deadlock.
  perform pg_advisory_xact_lock(
    hashtextextended(v_company_id::text || ':' || least(v_stop.delivery_date, p_new_date)::text, 0)
  );
  perform pg_advisory_xact_lock(
    hashtextextended(v_company_id::text || ':' || greatest(v_stop.delivery_date, p_new_date)::text, 0)
  );

  v_capacity := public.delivery_day_capacity(v_company_id, p_new_date);
  select count(*) into v_booked
  from public.delivery_stops ds
  where ds.company_id = v_company_id
    and ds.delivery_date = p_new_date
    and ds.status in ('BOOKED', 'COMPLETED')
    and ds.id <> v_stop.id;

  if v_capacity - v_booked <= 0
     and not public.has_permission('delivery.manage_calendar') then
    raise exception 'That day is fully booked. Ask someone who manages the delivery calendar to add spots.';
  end if;

  update public.delivery_stops
  set status = 'SUPERSEDED', updated_at = now()
  where id = v_stop.id;

  insert into public.delivery_stops (
    company_id, store_id, journey_id, delivery_date, status,
    inside_cutoff, override_reason, booked_by
  )
  select v_stop.company_id, ds.store_id, v_stop.journey_id, p_new_date,
         'BOOKED', v_inside,
         case when v_inside then v_reason else null end, v_employee_id
  from public.delivery_stops ds where ds.id = v_stop.id
  returning id into v_new_stop_id;

  insert into public.delivery_stop_events (
    company_id, stop_id, journey_id, action, from_date, to_date,
    reason, "override", actor_id
  ) values (
    v_company_id, v_stop.id, v_stop.journey_id, 'RESCHEDULED',
    v_stop.delivery_date, p_new_date,
    v_reason, v_inside, v_employee_id
  );

  perform set_config('pillowtop.delivery_event_write', 'on', true);
  insert into public.journey_events (journey_id, event_type, event_data, triggered_by)
  values (
    v_stop.journey_id,
    'delivery_scheduled',
    jsonb_build_object('delivery_date', p_new_date::text, 'delivery_stop_id', v_new_stop_id),
    auth.uid()::text
  );

  return v_new_stop_id;
end;
$$;

grant execute on function public.reschedule_delivery_stop(uuid, date, text) to authenticated;

-- ============================================================================
-- 12. cancel_delivery_stop — frees the day immediately, journey returns to
--     Ready to Schedule via the delivery_unscheduled event.
-- ============================================================================

create or replace function public.cancel_delivery_stop(
  p_stop_id uuid,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
  v_employee_id uuid;
  v_stop record;
  v_reason text := nullif(trim(coalesce(p_reason, '')), '');
begin
  v_company_id := public.delivery_caller_company();
  if v_company_id is null then
    raise exception 'Only active employees can cancel deliveries.';
  end if;

  select e.id into v_employee_id
  from public.employees e
  where e.auth_user_id = auth.uid() and e.is_active;
  if v_employee_id is null then
    raise exception 'Only active employees can cancel deliveries.';
  end if;

  select ds.id, ds.journey_id, ds.delivery_date, ds.company_id
  into v_stop
  from public.delivery_stops ds
  where ds.id = p_stop_id and ds.status = 'BOOKED';

  if v_stop.id is null or v_stop.company_id <> v_company_id then
    raise exception 'That delivery was not found.';
  end if;

  if not public.is_journey_visible(v_stop.journey_id) then
    raise exception 'You cannot schedule deliveries for that order.';
  end if;

  -- A BOOKED stop normally implies Scheduled. If the journey moved on
  -- (e.g. inventory pulled it back to Waiting for Inventory), flipping
  -- it to Ready to Schedule would be wrong — refuse instead.
  if not exists (
    select 1 from public.sleep_journeys sj
    where sj.id = v_stop.journey_id
      and sj.current_state = 'Scheduled'
      and sj.cancelled_at is null
  ) then
    raise exception 'That order is no longer scheduled for delivery.';
  end if;

  if v_reason is null then
    raise exception 'Give a reason for cancelling the delivery.';
  end if;

  update public.delivery_stops
  set status = 'CANCELLED',
      cancelled_at = now(),
      cancel_reason = v_reason,
      updated_at = now()
  where id = v_stop.id;

  insert into public.delivery_stop_events (
    company_id, stop_id, journey_id, action, from_date, reason, actor_id
  ) values (
    v_company_id, v_stop.id, v_stop.journey_id, 'CANCELLED',
    v_stop.delivery_date, v_reason, v_employee_id
  );

  perform set_config('pillowtop.delivery_event_write', 'on', true);
  insert into public.journey_events (journey_id, event_type, event_data, triggered_by)
  values (
    v_stop.journey_id,
    'delivery_unscheduled',
    jsonb_build_object('reason', v_reason, 'delivery_stop_id', v_stop.id),
    auth.uid()::text
  );
end;
$$;

grant execute on function public.cancel_delivery_stop(uuid, text) to authenticated;

-- ============================================================================
-- 13. get_delivery_calendar: identical to 127 except capacity now comes
--     from delivery_day_capacity() and booked_count is the real count of
--     BOOKED + COMPLETED stops for the date.
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
    return jsonb_build_object('settings', null, 'trucks', '[]'::jsonb, 'archived_trucks', '[]'::jsonb, 'days', '[]'::jsonb);
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
      coalesce((
        select a.extra_slots
        from public.delivery_day_adjustments a
        where a.company_id = v_company_id and a.date = dt.date
      ), 0) as extra_slots,
      coalesce((
        select count(*)
        from public.delivery_stops ds
        where ds.company_id = v_company_id
          and ds.delivery_date = dt.date
          and ds.status in ('BOOKED', 'COMPLETED')
      ), 0) as booked_count,
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
        'home_location_type', st.location_type::text,
        'default_stop_cap', t.default_stop_cap,
        'weekly_pattern', t.weekly_pattern,
        'sort_order', t.sort_order
      ) order by t.sort_order, t.name)
      from public.delivery_trucks t
      left join public.stores st on st.id = t.home_location_id
      where t.company_id = v_company_id and t.archived_at is null
    ), '[]'::jsonb),
    'archived_trucks', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', t.id,
        'name', t.name,
        'home_location_id', t.home_location_id,
        'home_location_name', st.name,
        'home_location_type', st.location_type::text,
        'default_stop_cap', t.default_stop_cap,
        'weekly_pattern', t.weekly_pattern,
        'archived_at', t.archived_at
      ) order by t.name)
      from public.delivery_trucks t
      left join public.stores st on st.id = t.home_location_id
      where t.company_id = v_company_id and t.archived_at is not null
    ), '[]'::jsonb),
    'days', coalesce((
      select jsonb_agg(jsonb_build_object(
        'date', r.date,
        'extra_slots', r.extra_slots,
        'capacity', public.delivery_day_capacity(v_company_id, r.date),
        'booked_count', r.booked_count,
        'trucks', r.trucks
      ) order by r.date)
      from day_rollup r
    ), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$$;

grant execute on function public.get_delivery_calendar(date, date) to authenticated;
