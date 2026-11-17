-- ============================================================================
-- 149_completion_rules.sql
-- Follow up to 147/148, from Zach's human pass (Nov 17):
--   1. Store staff finalize PICKUPS only, and only pickups leaving the store
--      they are logged into today (the active_store_id the app already keeps in
--      the login token). Owners and admins may finalize any location
--      (orders.pickup_any_location). A warehouse pickup is finalized by someone
--      logged into the warehouse.
--   2. DELIVERIES are never finalized by store staff. New permission
--      delivery.finalize: default owner, admin, and a manager whose home
--      location is a warehouse (warehouse manager). Anyone else only through a
--      per-employee grant. (The driver step and the end-of-route warehouse
--      finalize come with the warehouse module; this is the interim rule.)
--   3. An order with NO sleep trial (for example only pillows) goes to
--      Completed (off the board) when it is handed over, not to Sleep Trial.
--      Only orders with a live sleep trial item go to Sleep Trial.
--      Exchange orders are left as they were.
-- Safe to run twice.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Permission keys
-- ---------------------------------------------------------------------------
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
    'orders.backdate_fulfillment',
    'delivery.finalize',
    'orders.pickup_any_location'
  );
$$;

revoke execute on function public.is_valid_permission_key(text) from anon;

insert into public.role_permission_grants (company_id, role, permission_key)
select c.id, g.role, k.key
from public.companies c
cross join (values ('owner'), ('admin')) as g (role)
cross join (values ('delivery.finalize'), ('orders.pickup_any_location')) as k (key)
on conflict do nothing;

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
    (new.id, 'manager', 'orders.backdate_fulfillment'),
    (new.id, 'owner',   'delivery.finalize'),
    (new.id, 'admin',   'delivery.finalize'),
    (new.id, 'owner',   'orders.pickup_any_location'),
    (new.id, 'admin',   'orders.pickup_any_location')
  on conflict do nothing;
  return new;
end;
$$;

revoke execute on function public.trg_seed_fulfillment_permissions()
  from authenticated, anon, public;

-- ---------------------------------------------------------------------------
-- 2. Who may finalize a delivery
--    An explicit per-employee grant or denial always wins. Otherwise: the role
--    grant (owner, admin), or a manager whose home location is a warehouse.
-- ---------------------------------------------------------------------------
create or replace function public.can_finalize_delivery()
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_emp public.employees%rowtype;
  v_override boolean;
  v_home_type text;
begin
  select * into v_emp
  from public.employees e
  where e.auth_user_id = auth.uid() and e.is_active;
  if not found then
    return false;
  end if;

  select o.granted into v_override
  from public.employee_permission_overrides o
  where o.employee_id = v_emp.id
    and o.permission_key = 'delivery.finalize';
  if v_override is not null then
    return v_override;
  end if;

  if public.has_permission('delivery.finalize') then
    return true;
  end if;

  select s.location_type::text into v_home_type
  from public.stores s where s.id = v_emp.home_store_id;

  return v_emp.role::text = 'manager' and v_home_type = 'WAREHOUSE';
end;
$$;

revoke all on function public.can_finalize_delivery() from public, anon;
grant execute on function public.can_finalize_delivery() to authenticated;

-- ---------------------------------------------------------------------------
-- 3. complete_journey_fulfillment with the location and delivery rules
-- ---------------------------------------------------------------------------
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
  v_active     uuid;
  v_locs       uuid[];
  v_loc_names  text;
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

  v_method := case when v_j.fulfillment_type = 'pickup' then 'pickup' else 'delivery' end;

  if v_method = 'pickup' then
    if not public.has_permission('orders.mark_fulfilled') then
      raise exception 'You do not have permission to mark orders picked up.';
    end if;
  else
    if not public.can_finalize_delivery() then
      raise exception 'Deliveries are finalized by the warehouse team, an admin or an owner. You do not have permission to mark this delivered.';
    end if;
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

  if v_method = 'pickup' then
    if v_j.current_state not in ('Sold', 'Ready to Schedule') then
      raise exception 'This order is not ready for pickup yet (it is %).', v_j.current_state;
    end if;

    -- Location rule: the order must be leaving the location the person is
    -- working in today. The active location is the one the app saved in the
    -- login token at store select; with none saved, the home location.
    if not public.has_permission('orders.pickup_any_location') then
      begin
        v_active := nullif(auth.jwt() -> 'user_metadata' ->> 'active_store_id', '')::uuid;
      exception when others then
        v_active := null;
      end;
      v_active := coalesce(v_active, v_emp.home_store_id);

      select array_agg(distinct loc) into v_locs
      from (
        select coalesce(li.pickup_location_id, v_j.store_id) as loc
        from public.journey_line_items li
        where li.journey_id = p_journey_id
          and coalesce(li.fulfillment_type_override::text, v_j.fulfillment_type::text) = 'pickup'
        union
        select v_j.store_id
        where not exists (
          select 1 from public.journey_line_items li2 where li2.journey_id = p_journey_id
        )
      ) q;

      if v_locs is null or exists (
        select 1 from unnest(v_locs) l where l is distinct from v_active
      ) then
        select string_agg(s.name, ' and ' order by s.name) into v_loc_names
        from public.stores s where s.id = any (coalesce(v_locs, array[v_j.store_id]));
        raise exception 'This order is picked up at %. Log in to that location to mark it picked up.',
          coalesce(v_loc_names, 'another location');
      end if;
    end if;
  else
    if v_j.current_state <> 'Scheduled' then
      raise exception 'Book a delivery before marking this order delivered (it is %).', v_j.current_state;
    end if;
  end if;

  -- m148: stock must be on hand.
  if exists (
    select 1 from public.journey_inventory_requirements r
    where r.journey_id = p_journey_id and r.status = 'pending'
  ) then
    raise exception 'Some items on this order are not in stock yet. Receive or transfer the stock before marking it %.',
      case when v_method = 'pickup' then 'picked up' else 'delivered' end;
  end if;

  select coalesce(nullif(s.timezone, ''), 'America/Phoenix') into v_tz
  from public.stores s where s.id = v_j.store_id;

  v_today := (now() at time zone v_tz)::date;
  v_date  := coalesce(p_completed_on, v_today);

  if v_date > v_today then
    raise exception 'The date cannot be in the future.';
  end if;

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

-- ---------------------------------------------------------------------------
-- 4. No sleep trial, no Sleep Trial: such an order goes to Completed.
--    Runs after the state derivation trigger (trigger names fire in order).
-- ---------------------------------------------------------------------------
create or replace function public.complete_order_without_trial()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.event_type <> 'delivery_completed' then
    return new;
  end if;

  if exists (
    select 1 from public.sleep_journeys sj
    where sj.id = new.journey_id
      and sj.sale_kind = 'STANDARD'
      and sj.current_state = 'Sleep Trial'
  ) and not exists (
    select 1 from public.sleep_trial_items sti
    where sti.journey_id = new.journey_id
      and sti.status in ('PENDING_FULFILLMENT', 'ACTIVE')
  ) then
    update public.sleep_journeys
    set current_state = 'Completed', updated_at = now()
    where id = new.journey_id;
  end if;

  return new;
end;
$$;

revoke all on function public.complete_order_without_trial() from public, anon, authenticated;

drop trigger if exists zzz_complete_without_trial on public.journey_events;
create trigger zzz_complete_without_trial
  after insert on public.journey_events
  for each row execute function public.complete_order_without_trial();
