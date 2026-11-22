-- ============================================================================
-- 170: Expected pickup dates and the "fulfillment overdue" list (slice 4a).
--
--   1. sleep_journeys.expected_pickup_date: optional promise date for store
--      pickup orders. When unset, the effective date is the day the order
--      became ready for pickup plus 2 days (see pickup_effective_date).
--   2. pickup_effective_date: internal helper returning the date in effect
--      (explicit column, else ready day + 2, else null when not ready).
--   3. set_pickup_date: set or move the date. Moving the effective date
--      later requires a reason; first set and moving earlier do not.
--      Writes one journey_interactions internal note per change.
--   4. list_overdue_fulfillments: store-scoped list of overdue pickups and
--      overdue booked deliveries for the My Work nag.
--
--   Tool, not the boss: nothing here blocks a pickup, delivery or any other
--   action. Every rule only decides whether a nag row is returned.
-- ============================================================================

alter table public.sleep_journeys
  add column if not exists expected_pickup_date date;

create index if not exists sleep_journeys_expected_pickup_date_idx
  on public.sleep_journeys (expected_pickup_date)
  where expected_pickup_date is not null;

-- ----------------------------------------------------------------------------
-- pickup_effective_date(p_journey_id)
--
-- Effective pickup promise date:
--   * expected_pickup_date when set,
--   * else the ready day + 2 days,
--   * else null when the order is not ready.
--
-- Ready day derivation (all dates in the journey's store time zone):
--   * The day the order became Sold: latest of journey_updated_to_sold or
--     payment_completed events (payment_completed covers flows that marked
--     the order paid without the balance re-eval event).
--   * The day the order last left Waiting for Inventory: latest
--     inventory_received event.
--   * Ready day = the later of those two, so an order that waited on stock
--     is ready when the stock arrived, and an in-stock order is ready on
--     the day it was sold.
--   * An order currently in Waiting for Inventory, cancelled, or never sold
--     (no sold-day event) is not ready: returns null and is never nagged.
-- ----------------------------------------------------------------------------
create or replace function public.pickup_effective_date(p_journey_id uuid)
returns date
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_j        record;
  v_tz       text;
  v_sold_day date;
  v_inv_day  date;
  v_ready    date;
begin
  select sj.id, sj.store_id, sj.current_state::text as current_state,
         sj.cancelled_at, sj.expected_pickup_date
    into v_j
  from public.sleep_journeys sj
  where sj.id = p_journey_id;

  if not found then
    return null;
  end if;

  if v_j.expected_pickup_date is not null then
    return v_j.expected_pickup_date;
  end if;

  -- Not ready while cancelled or still waiting on stock. Orders that are
  -- already done never need a promise date either.
  if v_j.cancelled_at is not null
     or v_j.current_state in (
          'Waiting for Inventory', 'Sleep Trial', 'Completed'
        ) then
    return null;
  end if;

  select coalesce(nullif(s.timezone, ''), c.business_timezone)
    into v_tz
  from public.stores s
  join public.companies c on c.id = s.company_id
  where s.id = v_j.store_id;
  v_tz := coalesce(v_tz, 'UTC');

  -- Sold day: latest journey_updated_to_sold when one exists; the latest
  -- payment_completed only when the balance re-eval event never fired, so
  -- a later payment cannot move the default date out.
  select max((e.created_at at time zone v_tz)::date)
    into v_sold_day
  from public.journey_events e
  where e.journey_id = p_journey_id
    and e.event_type = 'journey_updated_to_sold';

  if v_sold_day is null then
    select max((e.created_at at time zone v_tz)::date)
      into v_sold_day
    from public.journey_events e
    where e.journey_id = p_journey_id
      and e.event_type = 'payment_completed';
  end if;

  if v_sold_day is null then
    return null;
  end if;

  select max((e.created_at at time zone v_tz)::date)
    into v_inv_day
  from public.journey_events e
  where e.journey_id = p_journey_id
    and e.event_type = 'inventory_received';

  v_ready := greatest(v_sold_day, coalesce(v_inv_day, v_sold_day));
  return v_ready + 2;
end;
$$;

revoke execute on function public.pickup_effective_date(uuid)
  from public, anon, authenticated;

-- ----------------------------------------------------------------------------
-- set_pickup_date(p_journey_id, p_date, p_reason)
--
-- Sets or moves the expected pickup date. Rules:
--   * Cancelled orders and orders with no pickup units still waiting are
--     refused.
--   * Moving the effective date (explicit or default) LATER requires a
--     reason. Setting the first date, moving earlier, or setting the same
--     date never requires one.
--   * Same explicit date: no-op, returns the current state unchanged.
--   * Every real change writes one journey_interactions internal note with
--     source_domain 'pickup_date'.
-- ----------------------------------------------------------------------------
create or replace function public.set_pickup_date(
  p_journey_id uuid,
  p_date       date,
  p_reason     text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_employee_id uuid;
  v_j           record;
  v_remaining   integer;
  v_has_lines   boolean;
  v_prev        date;
  v_reason      text;
  v_summary     text;
begin
  if auth.uid() is null then
    raise exception 'Not signed in.';
  end if;

  if not public.is_journey_visible(p_journey_id) then
    raise exception 'Order not found.';
  end if;

  select e.id into v_employee_id
  from public.employees e
  where e.auth_user_id = auth.uid() and e.is_active;
  if v_employee_id is null then
    raise exception 'Only active employees can set a pickup date.';
  end if;

  if p_date is null then
    raise exception 'Pick a pickup date.';
  end if;

  select * into v_j
  from public.sleep_journeys
  where id = p_journey_id
  for update;

  if v_j.cancelled_at is not null then
    raise exception 'That order is cancelled.';
  end if;

  -- Pickup units still waiting: line-level override wins over the
  -- journey-level fulfillment type, same as record_journey_fulfillment.
  select exists (
           select 1 from public.journey_line_items li
           where li.journey_id = p_journey_id
         )
    into v_has_lines;

  if v_has_lines then
    select coalesce(sum(li.quantity), 0)
         - coalesce(sum(f.cnt), 0)
      into v_remaining
    from public.journey_line_items li
    left join (
      select fu.line_item_id, count(*) as cnt
      from public.journey_fulfillment_units fu
      group by fu.line_item_id
    ) f on f.line_item_id = li.id
    where li.journey_id = p_journey_id
      and coalesce(li.fulfillment_type_override, v_j.fulfillment_type)
          = 'pickup';
  else
    -- Legacy orders without line items: count as one waiting pickup unit
    -- when the order is a pickup order and not yet delivered.
    v_remaining := case
      when v_j.fulfillment_type = 'pickup' and v_j.delivered_at is null
        then 1
      else 0 end;
  end if;

  if coalesce(v_remaining, 0) <= 0 then
    raise exception 'That order has no pickup items still waiting.';
  end if;

  -- Same explicit date: idempotent no-op.
  if v_j.expected_pickup_date is not null
     and v_j.expected_pickup_date = p_date then
    return jsonb_build_object(
      'expected_pickup_date',      v_j.expected_pickup_date,
      'previous_effective_date',   v_j.expected_pickup_date,
      'changed',                   false
    );
  end if;

  v_prev := public.pickup_effective_date(p_journey_id);
  v_reason := nullif(btrim(coalesce(p_reason, '')), '');

  -- Moving the current effective date later needs a reason. First set
  -- (nothing in effect) and moving earlier do not.
  if v_prev is not null and p_date > v_prev and v_reason is null then
    raise exception 'Give a reason for moving the pickup date out.';
  end if;

  update public.sleep_journeys
  set expected_pickup_date = p_date,
      updated_at = now()
  where id = p_journey_id;

  v_summary := case
    when v_j.expected_pickup_date is null then
      'Pickup date set to ' || to_char(p_date, 'Mon FMDD')
    else
      'Pickup date moved from ' || to_char(v_j.expected_pickup_date, 'Mon FMDD')
        || ' to ' || to_char(p_date, 'Mon FMDD')
  end;
  if v_reason is not null then
    v_summary := v_summary || '. Reason: ' || v_reason;
  end if;
  v_summary := v_summary || '.';

  insert into public.journey_interactions (
    journey_id, customer_id, interaction_type, channel, direction,
    topic, summary, created_by_employee_id, source_domain,
    source_record_id, is_internal
  ) values (
    p_journey_id, v_j.customer_id, 'internal_note', 'internal', 'internal',
    'pickup', v_summary, v_employee_id, 'pickup_date',
    p_journey_id, true
  );

  return jsonb_build_object(
    'expected_pickup_date',      p_date,
    'previous_effective_date',   v_prev,
    'changed',                   true
  );
end;
$$;

revoke execute on function public.set_pickup_date(uuid, date, text)
  from public, anon;
grant execute on function public.set_pickup_date(uuid, date, text)
  to authenticated;

-- ----------------------------------------------------------------------------
-- list_overdue_fulfillments(p_store_id)
--
-- One row per overdue fulfillment item for the given store (default: the
-- caller's home store). Store resolution matches the confirmation call
-- list: an explicit store must belong to the caller's company; there is no
-- employee-store access table, so the company check is the rule.
--
--   PICKUP:   pickup units still waiting, order not cancelled, effective
--             pickup date (explicit or default) before today in the store
--             time zone. Orders waiting on inventory are never returned.
--   DELIVERY: an active BOOKED delivery stop whose date is before today in
--             the store time zone, order not cancelled and not delivered.
--
-- A mixed order can produce one row of each kind; each kind is evaluated
-- independently.
-- ----------------------------------------------------------------------------
create or replace function public.list_overdue_fulfillments(
  p_store_id uuid default null
)
returns table (
  kind            text,
  journey_id      uuid,
  journey_number  text,
  customer_name   text,
  due_date        date,
  days_overdue    integer,
  units_remaining integer,
  store_id        uuid
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_employee_id uuid;
  v_company_id  uuid;
  v_store_id    uuid;
  v_today       date;
begin
  select e.id, s.company_id
    into v_employee_id, v_company_id
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid() and e.is_active;
  if v_company_id is null then
    raise exception 'Only active employees can view overdue fulfillments.';
  end if;

  if p_store_id is not null then
    select st.id into v_store_id
    from public.stores st
    where st.id = p_store_id
      and st.company_id = v_company_id;
    if v_store_id is null then
      raise exception 'That store is not in your company.';
    end if;
  else
    select e.home_store_id into v_store_id
    from public.employees e
    where e.id = v_employee_id;
  end if;

  if v_store_id is null then
    raise exception 'No store to check.';
  end if;

  v_today := public.business_today(v_store_id);
  if v_today is null then
    raise exception 'No store to check.';
  end if;

  return query
  with pickup_counts as (
    -- Cheap filter first: which journeys still have pickup units waiting
    -- (or are legacy lineless pickup orders). pickup_effective_date runs
    -- only for these, not for every active journey in the store.
    select
      sj.id as journey_id,
      sj.journey_number,
      cu.first_name || ' ' || cu.last_name as customer_name,
      sj.store_id,
      sj.fulfillment_type::text as journey_method,
      count(li.id) as pickup_lines,
      greatest(
        coalesce(sum(li.quantity), 0) - coalesce(sum(f.cnt), 0), 0
      ) as remaining
    from public.sleep_journeys sj
    join public.customers cu on cu.id = sj.customer_id
    left join public.journey_line_items li
      on li.journey_id = sj.id
     and coalesce(li.fulfillment_type_override, sj.fulfillment_type) = 'pickup'
    left join (
      select fu.line_item_id, count(*) as cnt
      from public.journey_fulfillment_units fu
      group by fu.line_item_id
    ) f on f.line_item_id = li.id
    where sj.store_id = v_store_id
      and sj.cancelled_at is null
      and sj.delivered_at is null
      and sj.current_state::text <> 'Waiting for Inventory'
    group by sj.id, sj.journey_number, cu.first_name, cu.last_name,
             sj.store_id, sj.fulfillment_type
  ),
  pickup_orders as (
    select
      pc.journey_id,
      pc.journey_number,
      pc.customer_name,
      public.pickup_effective_date(pc.journey_id) as eff_date,
      pc.store_id,
      case when pc.pickup_lines = 0 then null else pc.remaining::integer end
        as units_left
    from pickup_counts pc
    where
      -- Legacy orders with no line items count only when the order-level
      -- method is pickup. Lined orders count on remaining pickup units.
      (pc.pickup_lines = 0 and pc.journey_method = 'pickup')
      or pc.remaining > 0
  )
  select 'PICKUP'::text,
         po.journey_id,
         po.journey_number,
         po.customer_name,
         po.eff_date,
         (v_today - po.eff_date)::integer,
         po.units_left,
         po.store_id
  from pickup_orders po
  where po.eff_date is not null
    and po.eff_date < v_today

  union all

  select 'DELIVERY'::text,
         sj.id,
         sj.journey_number,
         cu.first_name || ' ' || cu.last_name,
         ds.delivery_date,
         (v_today - ds.delivery_date)::integer,
         null::integer,
         sj.store_id
  from public.delivery_stops ds
  join public.sleep_journeys sj on sj.id = ds.journey_id
  join public.customers cu on cu.id = sj.customer_id
  where ds.status = 'BOOKED'
    and ds.delivery_date < v_today
    and sj.store_id = v_store_id
    and sj.cancelled_at is null
    and sj.delivered_at is null
    and not exists (
      select 1
      from public.journey_events je
      where je.journey_id = sj.id
        and je.event_type = 'delivery_completed'
    )

  order by 5 desc, 3;
end;
$$;

revoke execute on function public.list_overdue_fulfillments(uuid)
  from public, anon;
grant execute on function public.list_overdue_fulfillments(uuid)
  to authenticated;
