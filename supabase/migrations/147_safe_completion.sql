-- ============================================================================
-- 147_safe_completion.sql
-- Slice 1 of the fulfillment redesign: SAFE COMPLETION.
--
-- Problems this fixes (all found by testing the real database):
--   1. Any signed-in employee of the company could insert a delivery_completed
--      event straight into journey_events. It was accepted on a Quoted unpaid
--      order (straight to Sleep Trial), accepted twice (restamping delivered_at),
--      and recorded no reliable "who".
--   2. A pickup order had NO way to be completed: "Mark Delivered" exists only
--      from Scheduled, and the database refuses to book a delivery stop for a
--      pickup order.
--   3. Anyone could backdate a delivery or pickup.
--
-- What it adds:
--   * Two permissions
--       orders.mark_fulfilled        owner, admin, manager, sales
--       orders.backdate_fulfillment  owner, admin, manager
--     (per-employee overrides already work through has_permission)
--   * complete_journey_fulfillment(journey, date, reason): the ONLY way to
--     complete an order. Delivery orders must be Scheduled. Pickup orders
--     must be Sold or Ready to Schedule. Cancelled orders and orders already
--     completed are refused. No date means today in the STORE's time zone.
--     An earlier date needs the backdate permission and a typed reason.
--     A future date is always refused. It records who, when it was entered,
--     the date used, the method (pickup or delivery), and any backdate reason
--     inside the event itself.
--   * Direct inserts of delivery_completed are refused for signed-in users
--     (policy plus guard trigger), and a second delivery_completed for the
--     same order is refused for everyone.
--   * Direct UPDATEs of sleep_journeys.current_state and delivered_at from a
--     signed-in browser session are refused (found in testing: any employee
--     could set an order to Completed with a delivered date by a plain
--     update). Database functions and triggers still change them normally.
--
-- Server side scripts with no signed-in user (the SQL editor, service role,
-- seed scripts, the future importer) are not blocked from inserting the event,
-- but are still refused a duplicate.
--
-- Safe to run twice.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Permission keys
-- ----------------------------------------------------------------------------
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
    'delivery.log_confirmation_calls',
    'delivery.set_windows',
    'orders.mark_fulfilled',
    'orders.backdate_fulfillment'
  );
$$;

revoke execute on function public.is_valid_permission_key(text) from anon;

-- Existing companies.
insert into public.role_permission_grants (company_id, role, permission_key)
select c.id, g.role, 'orders.mark_fulfilled'
from public.companies c
cross join (values ('owner'), ('admin'), ('manager'), ('sales')) as g (role)
on conflict do nothing;

insert into public.role_permission_grants (company_id, role, permission_key)
select c.id, g.role, 'orders.backdate_fulfillment'
from public.companies c
cross join (values ('owner'), ('admin'), ('manager')) as g (role)
on conflict do nothing;

-- New companies (separate trigger so the older seed functions stay untouched).
create or replace function public.trg_seed_fulfillment_permissions()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.role_permission_grants (company_id, role, permission_key)
  values
    (new.id, 'owner',   'orders.mark_fulfilled'),
    (new.id, 'admin',   'orders.mark_fulfilled'),
    (new.id, 'manager', 'orders.mark_fulfilled'),
    (new.id, 'sales',   'orders.mark_fulfilled'),
    (new.id, 'owner',   'orders.backdate_fulfillment'),
    (new.id, 'admin',   'orders.backdate_fulfillment'),
    (new.id, 'manager', 'orders.backdate_fulfillment')
  on conflict do nothing;
  return new;
end;
$$;

revoke execute on function public.trg_seed_fulfillment_permissions()
  from authenticated, anon, public;

drop trigger if exists trg_companies_seed_fulfillment_permissions on public.companies;
create trigger trg_companies_seed_fulfillment_permissions
  after insert on public.companies
  for each row execute function public.trg_seed_fulfillment_permissions();

-- ----------------------------------------------------------------------------
-- 2. Guard: delivery_completed may only be written by the RPC below
-- ----------------------------------------------------------------------------
create or replace function public.guard_delivery_event_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_date date;
begin
  -- m147: completion events.
  if new.event_type = 'delivery_completed' then
    -- A second completion is never valid, for anyone.
    if exists (
      select 1 from public.journey_events e
      where e.journey_id = new.journey_id
        and e.event_type = 'delivery_completed'
    ) then
      raise exception 'This order is already marked fulfilled.';
    end if;

    -- Signed-in users must come through complete_journey_fulfillment().
    -- Server side scripts with no signed-in user are not blocked.
    if auth.uid() is not null
       and coalesce(current_setting('pillowtop.fulfillment_write', true), '') <> 'on' then
      raise exception 'Orders must be completed through complete_journey_fulfillment().';
    end if;

    return new;
  end if;

  if new.event_type not in ('delivery_scheduled', 'delivery_unscheduled') then
    return new;
  end if;

  if coalesce(current_setting('pillowtop.delivery_event_write', true), '') <> 'on' then
    raise exception 'Delivery scheduling must go through the delivery stop functions.';
  end if;

  if new.event_type = 'delivery_scheduled' then
    v_date := nullif(new.event_data->>'delivery_date', '')::date;
    -- created_at = now() proves the stop was written in THIS transaction
    -- by the booking RPC; an old BOOKED row cannot satisfy the guard.
    if v_date is null or not exists (
      select 1 from public.delivery_stops ds
      where ds.journey_id = new.journey_id
        and ds.delivery_date = v_date
        and ds.status = 'BOOKED'
        and ds.created_at = now()
    ) then
      raise exception 'Delivery scheduling must go through the delivery stop functions.';
    end if;
  else
    -- cancelled_at = now() proves the cancellation happened in THIS
    -- transaction; an old CANCELLED row cannot satisfy the guard.
    if not exists (
      select 1 from public.delivery_stops ds
      where ds.journey_id = new.journey_id
        and ds.status = 'CANCELLED'
        and ds.cancelled_at = now()
    ) then
      raise exception 'Delivery scheduling must go through the delivery stop functions.';
    end if;
  end if;

  return new;
end;
$$;

-- Defence in depth: the insert policy also refuses the event for signed-in
-- users, so the table itself says no even if the trigger were ever dropped.
drop policy if exists "Journey events insertable by authenticated users"
  on public.journey_events;
create policy "Journey events insertable by authenticated users"
  on public.journey_events
  for insert
  to authenticated
  with check (
    public.is_journey_visible(journey_id)
    and event_type <> all (array[
      'inventory_required'::public.journey_event_type,
      'inventory_received'::public.journey_event_type,
      'delivery_completed'::public.journey_event_type
    ])
  );

-- ----------------------------------------------------------------------------
-- 3. complete_journey_fulfillment
-- ----------------------------------------------------------------------------
create or replace function public.complete_journey_fulfillment(
  p_journey_id   uuid,
  p_completed_on date default null,
  p_reason       text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_emp        public.employees%rowtype;
  v_j          public.sleep_journeys%rowtype;
  v_tz         text;
  v_today      date;
  v_date       date;
  v_created    date;
  v_method     text;
  v_backdated  boolean;
  v_reason     text := nullif(btrim(coalesce(p_reason, '')), '');
  v_prev_date  date;
  v_state      public.journey_state;
begin
  if auth.uid() is null then
    raise exception 'Not signed in.';
  end if;

  select * into v_emp
  from public.employees e
  where e.auth_user_id = auth.uid() and e.is_active;
  if not found then
    raise exception 'Not signed in as an active employee.';
  end if;

  if not public.is_journey_visible(p_journey_id) then
    raise exception 'Order not found.';
  end if;

  -- Lock the order so two people clicking at once cannot both complete it.
  select * into v_j
  from public.sleep_journeys
  where id = p_journey_id
  for update;
  if not found then
    raise exception 'Order not found.';
  end if;

  if not public.has_permission('orders.mark_fulfilled') then
    raise exception 'You do not have permission to mark orders fulfilled.';
  end if;

  if v_j.cancelled_at is not null then
    raise exception 'This order is cancelled.';
  end if;

  if v_j.delivered_at is not null or exists (
    select 1 from public.journey_events e
    where e.journey_id = p_journey_id and e.event_type = 'delivery_completed'
  ) then
    v_prev_date := v_j.delivered_at;
    raise exception 'This order is already marked % on %.',
      case when v_j.fulfillment_type = 'pickup' then 'picked up' else 'delivered' end,
      coalesce(to_char(v_prev_date, 'Mon DD, YYYY'), 'an earlier date');
  end if;

  v_method := case when v_j.fulfillment_type = 'pickup' then 'pickup' else 'delivery' end;

  if v_method = 'pickup' then
    if v_j.current_state not in ('Sold', 'Ready to Schedule') then
      raise exception 'This order is not ready for pickup yet (it is %).', v_j.current_state;
    end if;
  else
    if v_j.current_state <> 'Scheduled' then
      raise exception 'Book a delivery before marking this order delivered (it is %).', v_j.current_state;
    end if;
  end if;

  -- Dates are judged in the STORE's time zone, so the answer does not depend
  -- on which computer or time zone the browser is in.
  select coalesce(nullif(s.timezone, ''), 'America/Phoenix') into v_tz
  from public.stores s where s.id = v_j.store_id;

  v_today := (now() at time zone v_tz)::date;
  v_date  := coalesce(p_completed_on, v_today);

  if v_date > v_today then
    raise exception 'The date cannot be in the future.';
  end if;

  -- Same floor the existing delivered_at trigger enforces.
  v_created := v_j.created_at::date;
  if v_date < v_created - 1 then
    raise exception 'The date cannot be before this order was created.';
  end if;

  v_backdated := v_date < v_today;
  if v_backdated then
    if not public.has_permission('orders.backdate_fulfillment') then
      raise exception 'Only an owner, admin or manager can record an earlier date. Use today''s date.';
    end if;
    if v_reason is null or length(v_reason) < 3 then
      raise exception 'Enter a reason for the earlier date.';
    end if;
  end if;

  perform set_config('pillowtop.fulfillment_write', 'on', true);

  insert into public.journey_events (
    journey_id, event_type, event_data, triggered_by
  ) values (
    p_journey_id,
    'delivery_completed',
    jsonb_strip_nulls(jsonb_build_object(
      'delivered_at',    to_char(v_date, 'YYYY-MM-DD'),
      'method',          v_method,
      'recorded_by',     v_emp.id,
      'recorded_by_name', coalesce(nullif(btrim(coalesce(v_emp.first_name, '') || ' ' || coalesce(v_emp.last_name, '')), ''), v_emp.name),
      'recorded_at',     now(),
      'backdated',       v_backdated,
      'backdate_reason', case when v_backdated then v_reason end
    )),
    auth.uid()::text
  );

  perform set_config('pillowtop.fulfillment_write', 'off', true);

  select current_state into v_state
  from public.sleep_journeys where id = p_journey_id;

  return jsonb_build_object(
    'journey_id',   p_journey_id,
    'delivered_at', v_date,
    'method',       v_method,
    'backdated',    v_backdated,
    'state',        v_state
  );
end;
$$;

revoke all on function public.complete_journey_fulfillment(uuid, date, text) from public, anon;
grant execute on function public.complete_journey_fulfillment(uuid, date, text) to authenticated;

-- ----------------------------------------------------------------------------
-- 4. A browser session may not set the state or delivered date directly.
--    The trigger is deliberately SECURITY INVOKER: inside a security definer
--    function (every state-changing RPC and trigger) current_user is the
--    function owner, while a plain client update runs as authenticated.
-- ----------------------------------------------------------------------------
create or replace function public.guard_journey_direct_update()
returns trigger
language plpgsql
as $$
begin
  if current_user in ('authenticated', 'anon')
     and (new.current_state is distinct from old.current_state
          or new.delivered_at is distinct from old.delivered_at) then
    raise exception 'An order''s status and delivered date can only be changed by recording an event.';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_guard_journey_direct_update on public.sleep_journeys;
create trigger trg_guard_journey_direct_update
  before update on public.sleep_journeys
  for each row execute function public.guard_journey_direct_update();
