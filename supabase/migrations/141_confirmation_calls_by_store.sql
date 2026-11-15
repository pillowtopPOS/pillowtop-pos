-- PillowTop POS m141: confirmation calls follow the STORE, not the
-- salesperson. "Mine" becomes "My store": the person working a store
-- calls all of that store's customers regardless of which salesperson
-- wrote the order. A customer belongs to the store the order was
-- written out of (sleep_journeys.store_id).
--
--   1. get_delivery_confirmation_list: scope values are now 'store'
--      and 'all' ('mine' is gone). New optional p_store_id uuid.
--      Resolution order: p_store_id when given (validated to be in
--      the caller's company), otherwise the caller's home_store_id.
--      The salesperson condition is dropped entirely;
--      assigned_employee_name is still returned for display.
--   2. get_delivery_call_alert: same p_store_id parameter and store
--      resolution. Returns store_open (the active store's unconfirmed
--      count) plus store_id and store_name. team_open/my_open are
--      removed; store_open replaces them.
--   3. The "next delivery date" is chosen per scope, not company-wide:
--      'store' picks the earliest day that store has a booked stop,
--      and the available_dates chips list only that scope's days.
--
-- Store access rule: there is no employee-store access table in this
-- schema. selectableStores (lib/journeys/queries.ts) is a client-side
-- filter only, so the server-side rule is the company check: a
-- p_store_id must belong to the caller's company or the call raises.
--
-- Idempotent: safe to re-run. The old signatures are dropped first so
-- the 'mine' scope cannot linger as an overload.

-- ============================================================================
-- 1. get_delivery_confirmation_list - 'store'/'all' scopes, p_store_id.
-- ============================================================================

drop function if exists public.get_delivery_confirmation_list(date, text);
drop function if exists public.get_delivery_confirmation_list(date, text, uuid);

create function public.get_delivery_confirmation_list(
  p_date date default null,
  p_scope text default 'store',
  p_store_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_employee_id uuid;
  v_company_id uuid;
  v_store_id uuid;
  v_store_name text;
  v_tomorrow date;
  v_date date;
  v_mode text;
  v_day_start time;
  v_day_end time;
  v_dates jsonb;
  v_items jsonb;
begin
  select e.id, s.company_id
    into v_employee_id, v_company_id
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid() and e.is_active;
  if v_company_id is null then
    raise exception 'Only active employees can view the confirmation list.';
  end if;
  if not public.has_permission('delivery.log_confirmation_calls') then
    raise exception 'You do not have permission to view the confirmation list.';
  end if;
  if p_scope is null or p_scope not in ('store', 'all') then
    raise exception 'Scope must be store or all.';
  end if;

  -- Store resolution: an explicit p_store_id must belong to the
  -- caller's company; otherwise fall back to the home store. There is
  -- no employee-store access table, so the company check is the rule.
  if p_store_id is not null then
    select st.id, st.name
      into v_store_id, v_store_name
    from public.stores st
    where st.id = p_store_id
      and st.company_id = v_company_id;
    if v_store_id is null then
      raise exception 'That store is not in your company.';
    end if;
  else
    select e.home_store_id
      into v_store_id
    from public.employees e
    where e.id = v_employee_id;
    select st.name
      into v_store_name
    from public.stores st
    where st.id = v_store_id;
  end if;

  select c.delivery_day_mode, c.delivery_day_start, c.delivery_day_end
    into v_mode, v_day_start, v_day_end
  from public.companies c where c.id = v_company_id;

  v_tomorrow := public.delivery_company_today() + 1;

  if p_date is null then
    -- Earliest day THIS scope has a booked stop: a store with no
    -- stops on the company's next day must not be shown that day.
    select min(ds.delivery_date) into v_date
    from public.delivery_stops ds
    join public.sleep_journeys sj on sj.id = ds.journey_id
    where ds.company_id = v_company_id
      and ds.status = 'BOOKED'
      and ds.delivery_date >= v_tomorrow
      and (p_scope = 'all' or sj.store_id = v_store_id);
  else
    v_date := p_date;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'date', d.delivery_date, 'stop_count', d.n
    ) order by d.delivery_date), '[]'::jsonb)
  into v_dates
  from (
    select ds.delivery_date, count(*) as n
    from public.delivery_stops ds
    join public.sleep_journeys sj on sj.id = ds.journey_id
    where ds.company_id = v_company_id
      and ds.status = 'BOOKED'
      and ds.delivery_date >= v_tomorrow
      and (p_scope = 'all' or sj.store_id = v_store_id)
    group by ds.delivery_date
    order by ds.delivery_date
    limit 7
  ) d;

  if v_date is null then
    return jsonb_build_object(
      'date', null, 'day_mode', v_mode,
      'day_start', v_day_start, 'day_end', v_day_end,
      'available_dates', v_dates, 'scope', p_scope,
      'store_id', v_store_id, 'store_name', v_store_name,
      'items', '[]'::jsonb);
  end if;

  with stops as (
    select
      ds.id as stop_id,
      ds.journey_id,
      ds.delivery_date,
      ds.truck_id,
      ds.route_position,
      ds.booked_by,
      ds.window_start,
      ds.window_end,
      sj.journey_number,
      sj.assigned_employee_id,
      sj.customer_id,
      sj.store_id,
      cu.first_name || ' ' || cu.last_name as customer_name,
      cu.phone as customer_phone,
      cu.email as customer_email,
      nullif(trim(concat_ws(', ',
        nullif(trim(concat_ws(' ', cu.street_address, cu.street_address_line_2)), ''),
        nullif(trim(concat_ws(' ', cu.city, cu.state, cu.zip_code)), '')
      )), '') as delivery_address,
      t.name as truck_name,
      t.sort_order as truck_sort_order,
      ae.name as assigned_employee_name
    from public.delivery_stops ds
    join public.sleep_journeys sj on sj.id = ds.journey_id
    join public.stores st on st.id = sj.store_id
    join public.customers cu on cu.id = sj.customer_id
    left join public.delivery_trucks t on t.id = ds.truck_id
    left join public.employees ae on ae.id = sj.assigned_employee_id
    where ds.company_id = v_company_id
      and ds.delivery_date = v_date
      and ds.status = 'BOOKED'
      and st.company_id = v_company_id
      -- 'store' = the journey's store is the resolved store; the
      -- salesperson no longer decides membership. 'all' = company.
      and (p_scope = 'all' or sj.store_id = v_store_id)
  ),
  conf as (
    select
      ji.stop_id,
      count(*) as attempts,
      (array_agg(ji.contact_outcome
        order by ji.occurred_at desc, ji.recorded_at desc))[1] as last_outcome,
      (array_agg(ji.occurred_at
        order by ji.occurred_at desc, ji.recorded_at desc))[1] as last_at,
      (array_agg(ji.summary
        order by ji.occurred_at desc, ji.recorded_at desc))[1] as last_note,
      (array_agg(ji.window_snapshot
        order by ji.occurred_at desc, ji.recorded_at desc))[1] as last_snapshot,
      (array_agg(ji.created_by_employee_id
        order by ji.occurred_at desc, ji.recorded_at desc))[1] as last_employee_id
    from public.journey_interactions ji
    where ji.company_id = v_company_id
      and ji.purpose = 'CONFIRMATION'
      and ji.stop_id is not null
      and ji.entered_in_error_at is null
      and ji.stop_id in (select s.stop_id from stops s)
    group by ji.stop_id
  )
  select coalesce(jsonb_agg(x.jb order by
      x.truck_sort_order nulls last, x.truck_name nulls last,
      x.truck_id nulls last,
      x.route_position nulls last, x.customer_name, x.stop_id),
    '[]'::jsonb)
  into v_items
  from (
    select
      jsonb_build_object(
        'stop_id', s.stop_id,
        'journey_id', s.journey_id,
        'journey_number', s.journey_number,
        'customer_name', s.customer_name,
        'customer_phone', s.customer_phone,
        'customer_email', s.customer_email,
        'delivery_address', s.delivery_address,
        'truck_id', s.truck_id,
        'truck_name', s.truck_name,
        'route_position', s.route_position,
        'window_start', case when v_mode = 'day_only' then null else s.window_start end,
        'window_end', case when v_mode = 'day_only' then null else s.window_end end,
        'outside_day_hours',
          case
            when v_mode = 'day_only' or s.window_start is null then false
            else s.window_start < v_day_start or s.window_end > v_day_end
          end,
        'assigned_employee_id', s.assigned_employee_id,
        'assigned_employee_name', s.assigned_employee_name,
        'status',
          case
            when c.stop_id is null then 'not_called'
            when c.last_outcome = 'confirmed'
                 and (c.last_snapshot ->> 'delivery_date') = s.delivery_date::text
                 and (v_mode = 'day_only'
                      or (((c.last_snapshot ->> 'window_start')
                            is not distinct from
                           (case when s.window_start is null then null
                                 else to_char(s.window_start, 'HH24:MI:SS') end))
                          and ((c.last_snapshot ->> 'window_end')
                            is not distinct from
                           (case when s.window_end is null then null
                                 else to_char(s.window_end, 'HH24:MI:SS') end))))
              then 'confirmed'
            when c.last_outcome = 'confirmed' then 'confirmed_window_changed'
            else c.last_outcome
          end,
        'attempts', coalesce(c.attempts, 0),
        'last_call', case when c.stop_id is null then null else jsonb_build_object(
          'outcome', c.last_outcome,
          'occurred_at', c.last_at,
          'by_name', be.name,
          'note', c.last_note,
          'window_snapshot', c.last_snapshot
        ) end
      ) as jb,
      s.truck_id,
      s.truck_sort_order,
      s.truck_name,
      s.route_position,
      s.customer_name,
      s.stop_id
    from stops s
    left join conf c on c.stop_id = s.stop_id
    left join public.employees be on be.id = c.last_employee_id
  ) x;

  return jsonb_build_object(
    'date', v_date,
    'day_mode', v_mode,
    'day_start', v_day_start,
    'day_end', v_day_end,
    'available_dates', v_dates,
    'scope', p_scope,
    'store_id', v_store_id,
    'store_name', v_store_name,
    'items', v_items);
end;
$$;

revoke execute on function public.get_delivery_confirmation_list(date, text, uuid)
  from public, anon;
grant execute on function public.get_delivery_confirmation_list(date, text, uuid)
  to authenticated;

-- ============================================================================
-- 2. get_delivery_call_alert - store-scoped counts for the pop-up.
--    Same eligibility, route_closed and date rules; team_open/my_open
--    are replaced by store_open plus store_id/store_name.
-- ============================================================================

drop function if exists public.get_delivery_call_alert();
drop function if exists public.get_delivery_call_alert(uuid);

create function public.get_delivery_call_alert(p_store_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_employee_id uuid;
  v_company_id uuid;
  v_store_id uuid;
  v_store_name text;
  v_store_list jsonb;
  v_date date;
  v_store_open integer := 0;
  v_total integer := 0;
  v_route_closed boolean := false;
begin
  select e.id, s.company_id
    into v_employee_id, v_company_id
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid() and e.is_active;
  if v_company_id is null then
    return jsonb_build_object('eligible', false);
  end if;
  if not public.has_permission('delivery.log_confirmation_calls') then
    return jsonb_build_object('eligible', false);
  end if;

  -- Same store resolution as the list RPC: explicit p_store_id must
  -- be in the caller's company, otherwise the home store.
  if p_store_id is not null then
    select st.id, st.name
      into v_store_id, v_store_name
    from public.stores st
    where st.id = p_store_id
      and st.company_id = v_company_id;
    if v_store_id is null then
      raise exception 'That store is not in your company.';
    end if;
  else
    select e.home_store_id
      into v_store_id
    from public.employees e
    where e.id = v_employee_id;
    select st.name
      into v_store_name
    from public.stores st
    where st.id = v_store_id;
  end if;

  -- The store list picks its own date (earliest day this store has a
  -- booked stop), already scoped to the caller's company.
  v_store_list := public.get_delivery_confirmation_list(null, 'store', v_store_id);

  v_date := nullif(v_store_list ->> 'date', '')::date;

  if v_date is not null then
    select count(*) into v_store_open
    from jsonb_array_elements(
      coalesce(v_store_list -> 'items', '[]'::jsonb)) it
    where it ->> 'status' is distinct from 'confirmed';

    select count(*) into v_total
    from public.delivery_stops ds
    where ds.company_id = v_company_id
      and ds.delivery_date = v_date
      and ds.status = 'BOOKED';

    select exists (
      select 1
      from public.delivery_day_plans p
      where p.company_id = v_company_id
        and p.date = v_date
        and p.status = 'CLOSED'
    ) into v_route_closed;
  end if;

  return jsonb_build_object(
    'eligible', true,
    'date', v_date,
    'route_closed', v_route_closed,
    'store_open', v_store_open,
    'store_id', v_store_id,
    'store_name', v_store_name,
    'total_stops', v_total
  );
end;
$$;

revoke execute on function public.get_delivery_call_alert(uuid)
  from public, anon;
grant execute on function public.get_delivery_call_alert(uuid)
  to authenticated;

-- ============================================================================
-- Verification (run after install):
--   -- signatures and grants
--   select p.proname, pg_get_function_arguments(p.oid) as args
--   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--   where n.nspname = 'public'
--     and p.proname in ('get_delivery_confirmation_list',
--                       'get_delivery_call_alert')
--   order by p.proname;
--   -- expect (date, text, uuid) and (uuid); the old (date, text) and
--   -- () overloads must be gone.
--   -- smoke: as an authenticated employee,
--   --   select get_delivery_call_alert(null);
--   --   select get_delivery_confirmation_list(null, 'store', null);
--   -- 'mine' must now raise 'Scope must be store or all.'
-- ============================================================================
