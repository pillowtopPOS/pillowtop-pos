-- ============================================================================
-- 171: get_pickup_dates - read-side RPC for slice 4b.
--
-- Returns the pickup promise date data the order panel needs for a batch
-- of journeys the caller can see:
--   * expected_date   - the explicit sleep_journeys.expected_pickup_date
--   * effective_date  - public.pickup_effective_date (explicit or the
--                       ready-day-plus-2 default)
--   * is_default      - true when only the default applies
--   * units_remaining - pickup units still waiting (same counting rule as
--                       set_pickup_date in migration 170)
--   * store_id
--
-- Invisible journey ids are skipped silently. The input array is capped
-- at 200 ids. Read only; no writes.
-- ============================================================================

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
           sj.fulfillment_type, sj.delivered_at
    from wanted w
    join public.sleep_journeys sj on sj.id = w.journey_id
    where public.is_journey_visible(sj.id)
  ),
  remaining as (
    select
      v.id as journey_id,
      case
        -- Same rule as set_pickup_date (m170): a journey with no line
        -- items counts as one waiting pickup unit when the order-level
        -- method is pickup and it is not delivered; otherwise the pickup
        -- lines' quantity minus their handed-over units.
        when not exists (
          select 1 from public.journey_line_items x
          where x.journey_id = v.id
        ) then
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
