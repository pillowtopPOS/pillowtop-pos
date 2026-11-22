-- ============================================================================
-- 172: Edge fix for the pickup-unit counting in m170/m171.
--
-- A journey whose fulfillment_type is 'pickup' but whose lines are ALL
-- overridden to delivery was treated like a legacy lineless pickup order:
-- list_overdue_fulfillments could emit a false nag row and get_pickup_dates
-- reported a waiting unit that does not exist.
--
-- Rule now, in both functions: "lineless legacy" means zero line items in
-- total. A journey that has any line items counts only the lines whose
-- effective method is pickup (override wins over journey-level type).
-- Same signatures, same grants, safe to run twice. Read/list functions
-- only; no UPDATE or DELETE.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- list_overdue_fulfillments: re-emit of m170 with the lineless fix. The
-- pickup_counts CTE gains total_lines (all line items, regardless of
-- method); the legacy branch now requires total_lines = 0.
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
      (select count(*) from public.journey_line_items x
       where x.journey_id = sj.id) as total_lines,
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
      -- Lineless legacy (no line items at all) counts only when the
      -- order-level method is pickup. A journey that HAS lines counts on
      -- remaining pickup units only, even when the journey-level type is
      -- pickup and every line is overridden to delivery.
      (pc.total_lines = 0 and pc.journey_method = 'pickup')
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

-- ----------------------------------------------------------------------------
-- get_pickup_dates: re-emit of m171 with the same rule restated. The m171
-- body already separated "no line items at all" from "no pickup lines";
-- this version makes that explicit with a has_lines flag so the two
-- functions read the same way.
-- ----------------------------------------------------------------------------
create or replace function public.get_pickup_dates(p_journey_ids uuid[])
returns table (
  journey_id      uuid,
  expected_date   date,
  effective_date  date,
  is_default      boolean,
  units_remaining integer,
  store_id        uuid
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Not signed in.';
  end if;

  return query
  with wanted as (
    select distinct unnest(p_journey_ids[1:200]) as journey_id
  ),
  visible as (
    select sj.id, sj.store_id, sj.expected_pickup_date,
           sj.fulfillment_type, sj.delivered_at,
           exists (
             select 1 from public.journey_line_items x
             where x.journey_id = sj.id
           ) as has_lines
    from wanted w
    join public.sleep_journeys sj on sj.id = w.journey_id
    where public.is_journey_visible(sj.id)
  ),
  remaining as (
    select
      v.id as journey_id,
      case
        -- Lineless legacy only: a journey with any line items counts
        -- pickup lines exclusively, even when the journey-level type is
        -- pickup and every line is overridden to delivery.
        when not v.has_lines then
          case
            when v.fulfillment_type = 'pickup' and v.delivered_at is null
              then 1
            else 0
          end
        else greatest(
          coalesce((
            select sum(li.quantity)
            from public.journey_line_items li
            where li.journey_id = v.id
              and coalesce(li.fulfillment_type_override, v.fulfillment_type)
                  = 'pickup'
          ), 0)
          - coalesce((
            select count(*)
            from public.journey_fulfillment_units fu
            join public.journey_line_items li2 on li2.id = fu.line_item_id
            where li2.journey_id = v.id
              and coalesce(li2.fulfillment_type_override, v.fulfillment_type)
                  = 'pickup'
          ), 0),
          0
        )::integer
      end as units
    from visible v
  )
  select
    v.id,
    v.expected_pickup_date,
    public.pickup_effective_date(v.id),
    (v.expected_pickup_date is null
      and public.pickup_effective_date(v.id) is not null),
    r.units,
    v.store_id
  from visible v
  join remaining r on r.journey_id = v.id
  order by v.id;
end;
$$;

revoke execute on function public.get_pickup_dates(uuid[])
  from public, anon;
grant execute on function public.get_pickup_dates(uuid[])
  to authenticated;
