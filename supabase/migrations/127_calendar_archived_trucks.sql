-- PillowTop POS m127: get_delivery_calendar also returns archived trucks
-- and each truck's home_location_type, so the Manage trucks panel can
-- list/restore archived trucks and label Warehouse vs Store.
--
-- Identical to the 124 body except:
--   * 'trucks' rows gain 'home_location_type'
--   * new top-level 'archived_trucks' array (same shape minus pattern
--     ordering; archived rows keep sort_order/name order)
-- Everything else — company scope, day math, capacity, booked_count —
-- is unchanged.

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
