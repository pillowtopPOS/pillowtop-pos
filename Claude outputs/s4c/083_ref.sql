-- PillowTop POS: fix ready-to-schedule recipient rules
--
-- The 082 recipient rule (home_store_id = store_id AND is_journey_visible)
-- had two wrong edges: a sales employee viewing a store that is not their
-- home store was excluded, and owners/managers stationed at the owning
-- store were included even when it wasn't their active store. Redefines
-- list_ready_journeys with the recipient condition only; every other
-- filter, the return shape, and the ordering are unchanged.
--
-- A journey is returned when the caller is an active employee and any of:
--   1. they are the journey's assigned employee,
--   2. the JWT active_store_id equals the journey's store (same claim
--      is_store_visible reads, null/malformed-safe),
--   3. they are a manager whose home_store_id is the journey's store.

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
          or (v_active_store is not null and v_active_store = sj.store_id)
          or (v_employee.role = 'manager'
              and v_employee.home_store_id = sj.store_id)
        )
    ) r
  ), '[]'::jsonb);
end;
$$;

grant execute on function public.list_ready_journeys() to authenticated;
