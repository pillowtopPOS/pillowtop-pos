-- PillowTop POS: "ready to schedule" work item
--
-- When a Journey leaves Waiting for Inventory for Ready to Schedule, the
-- owner and everyone at the owning store need a work item until it is
-- scheduled. There is no notification infrastructure (075 deferred it), so
-- the item is derived at query time — like list_pending_exception_approvals —
-- and disappears on every Ready to Schedule exit automatically.
--
-- ready_after_wait_at marks "arrived at Ready to Schedule after actually
-- waiting" — a stamp set only on the Waiting for Inventory ->
-- Ready to Schedule transition. Journeys that go Quoted/Sold ->
-- Ready to Schedule with no wait (fully stocked orders) never get it and
-- never produce a work item.

-- 1. Episode marker column ---------------------------------------------------

alter table public.sleep_journeys
  add column if not exists ready_after_wait_at timestamptz;

-- 2. Stamp trigger -----------------------------------------------------------
-- BEFORE UPDATE (no column list): only rewrites NEW fields, never issues its
-- own UPDATE, so it cannot recurse or fire a second time. Ordering vs the 077
-- fulfillment lock doesn't matter — that trigger is BEFORE UPDATE OF
-- fulfillment_type and never co-fires with the state writes this one watches.

create or replace function public.stamp_ready_after_wait()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.current_state = 'Waiting for Inventory'::public.journey_state
     and new.current_state = 'Ready to Schedule'::public.journey_state then
    new.ready_after_wait_at := now();
  elsif new.current_state <> 'Ready to Schedule'::public.journey_state then
    new.ready_after_wait_at := null;
  end if;
  return new;
end;
$$;
revoke execute on function public.stamp_ready_after_wait() from authenticated, anon;

drop trigger if exists trg_stamp_ready_after_wait on public.sleep_journeys;
create trigger trg_stamp_ready_after_wait
  before update on public.sleep_journeys
  for each row execute function public.stamp_ready_after_wait();

-- 3. list_ready_journeys -----------------------------------------------------
-- Derived queue, modeled on list_pending_exception_approvals (075). Visible
-- to the assigned employee, or to an active employee whose home_store_id is
-- the journey's store AND who passes is_journey_visible — the home-store
-- equality deliberately excludes owners/managers stationed elsewhere even
-- though is_journey_visible would let them see the journey itself.

create or replace function public.list_ready_journeys()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_employee public.employees%rowtype;
begin
  select * into v_employee
  from public.employees
  where auth_user_id = auth.uid()
    and is_active;
  if v_employee.id is null then
    return '[]'::jsonb;
  end if;

  return coalesce((
    select jsonb_agg(r.row order by r.stamp)
    from (
      select
        sj.ready_after_wait_at as stamp,
        jsonb_build_object(
          'journey_id', sj.id,
          'customer_name', c.first_name || ' ' || c.last_name,
          'store_name', s.name,
          'ready_after_wait_at', sj.ready_after_wait_at,
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
        select
          (array_agg(li.item_name order by li.created_at))[1] as first_name,
          count(*) as n
        from public.journey_line_items li
        where li.journey_id = sj.id
      ) items on true
      where sj.current_state = 'Ready to Schedule'
        and sj.ready_after_wait_at is not null
        and sj.cancelled_at is null
        and sj.delivered_at is null
        and (
          sj.assigned_employee_id = v_employee.id
          or (v_employee.home_store_id = sj.store_id
              and public.is_journey_visible(sj.id))
        )
    ) r
  ), '[]'::jsonb);
end;
$$;

grant execute on function public.list_ready_journeys() to authenticated;
