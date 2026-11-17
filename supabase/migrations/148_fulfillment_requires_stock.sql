-- ============================================================================
-- 148_fulfillment_requires_stock.sql
-- Follow up to 147. An order cannot be marked delivered or picked up while any
-- of its inventory requirements is still pending (item not in stock at its
-- location). Before this, completing such an order silently marked the pending
-- requirement "superseded" and no stock was deducted.
-- Orders with no inventory requirements are unaffected. Safe to run twice.
-- ============================================================================

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

  -- m148: stock must be on hand. A requirement still pending means the item
  -- is not in stock at its location; completing would silently drop it.
  if exists (
    select 1 from public.journey_inventory_requirements r
    where r.journey_id = p_journey_id and r.status = 'pending'
  ) then
    raise exception 'Some items on this order are not in stock yet. Receive or transfer the stock before marking it %.',
      case when v_method = 'pickup' then 'picked up' else 'delivered' end;
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
