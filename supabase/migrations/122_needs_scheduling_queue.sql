-- PillowTop POS m122: "Needs scheduling" queue sees EVERY ready delivery
-- order, not just ones that waited for stock.
--
-- Built on the 083_ready_recipients.sql body — the recipient rule is
-- unchanged: the caller is an active employee and any of
--   1. they are the journey's assigned employee,
--   2. the JWT active_store_id equals the journey's store (null/
--      malformed-safe), or
--   3. they are a manager whose home_store_id is the journey's store.
--
-- THE GAP (082/083): the queue required ready_after_wait_at, which
-- stamp_ready_after_wait only sets on Waiting for Inventory -> Ready to
-- Schedule. An order whose stock was already on hand goes
-- Sold -> Ready to Schedule directly, never gets the stamp, and never
-- appeared in My Work.
--
-- THE FIX: the queue is now every journey in Ready to Schedule that is a
-- delivery order and has no active scheduling (being in Ready to
-- Schedule already means not Scheduled; cancelled journeys leave the
-- state, and cancelled_at/delivered_at are belt-and-braces).
--
-- "Delivery order" means journey.fulfillment_type = 'delivery' AND at
-- least one line item whose EFFECTIVE fulfillment (per-line override
-- falling back to the journey default) is not pickup — so a journey
-- marked delivery whose lines are all pickup-override does not appear,
-- and a mixed journey still does.
--
-- Ready timestamp: ready_after_wait_at only exists for waited orders.
-- The real "entered Ready to Schedule" moment is the latest
-- inventory_received journey_event — evaluate_journey_inventory emits it
-- on EVERY transition into Ready to Schedule (095), waited or not, and
-- re-emits if the journey dips back to Waiting and returns. Fallbacks:
-- ready_after_wait_at, then updated_at (sleep_journeys.updated_at exists
-- since 001), for any legacy row without the event. ready_at is returned
-- so the UI can say "Ready 3 days ago" and sort oldest-first. No new
-- column needed.
--
-- journey_number is added for display (SJ-MS00136). All existing keys
-- are preserved so older clients keep working.

create or replace function public.list_ready_journeys()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_employee public.employees%rowtype;
  v_active_store uuid;
begin
  select * into v_employee
  from public.employees
  where auth_user_id = auth.uid()
    and is_active;
  if v_employee.id is null then
    return '[]'::jsonb;
  end if;

  -- Same claim is_store_visible reads; a missing or malformed value means
  -- rule 2 simply does not apply rather than raising a cast error.
  begin
    v_active_store := (auth.jwt() -> 'user_metadata' ->> 'active_store_id')::uuid;
  exception when others then
    v_active_store := null;
  end;

  return coalesce((
    select jsonb_agg(r.row order by r.ready_at asc nulls last, r.stamp)
    from (
      select
        coalesce(ready_ev.ready_at, sj.ready_after_wait_at, sj.updated_at) as ready_at,
        coalesce(ready_ev.ready_at, sj.ready_after_wait_at, sj.updated_at) as stamp,
        jsonb_build_object(
          'journey_id', sj.id,
          'journey_number', sj.journey_number,
          'customer_name', c.first_name || ' ' || c.last_name,
          'store_name', s.name,
          'ready_after_wait_at', sj.ready_after_wait_at,
          'ready_at', coalesce(ready_ev.ready_at, sj.ready_after_wait_at, sj.updated_at),
          'assigned_employee_name', e.name,
          'item_summary', case
            when items.n = 0 then null
            when items.n = 1 then items.first_name
            else items.first_name || ' and ' || (items.n - 1) || ' more'
          end
        ) as row
      from public.sleep_journeys sj
      join public.customers c on c.id = sj.customer_id
      join public.stores s on s.id = sj.store_id
      left join public.employees e on e.id = sj.assigned_employee_id
      left join lateral (
        select max(je.created_at) as ready_at
        from public.journey_events je
        where je.journey_id = sj.id
          and je.event_type = 'inventory_received'
      ) ready_ev on true
      left join lateral (
        select
          (array_agg(li.item_name order by li.created_at))[1] as first_name,
          count(*) as n
        from public.journey_line_items li
        where li.journey_id = sj.id
      ) items on true
      where sj.current_state = 'Ready to Schedule'
        and sj.fulfillment_type = 'delivery'
        and sj.cancelled_at is null
        and sj.delivered_at is null
        and exists (
          select 1
          from public.journey_line_items li2
          where li2.journey_id = sj.id
            and coalesce(li2.fulfillment_type_override, sj.fulfillment_type) <> 'pickup'
        )
        and (
          sj.assigned_employee_id = v_employee.id
          or (v_active_store is not null and v_active_store = sj.store_id)
          or (v_employee.role = 'manager'
              and v_employee.home_store_id = sj.store_id)
        )
    ) r
  ), '[]'::jsonb);
end;
$$;

grant execute on function public.list_ready_journeys() to authenticated;
