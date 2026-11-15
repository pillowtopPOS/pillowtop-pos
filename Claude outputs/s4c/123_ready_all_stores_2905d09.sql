-- PillowTop POS m123: "Show all stores" for the My Work ready queue.
--
-- list_ready_journeys gains p_all_stores (default false). The old
-- zero-argument function is DROPPED first — keeping it would make a
-- no-argument call ambiguous. Callers that pass nothing resolve to the
-- defaulted parameter, so behavior is identical until the UI passes true.
--
-- p_all_stores = false: identical to m122 — the 083 three-part recipient
-- rule (assigned employee, JWT active_store_id = journey store, or
-- manager whose home_store_id is the journey store) plus a new company
-- hardening check that cannot change who sees what inside one company.
--
-- p_all_stores = true: the recipient rule is replaced by company
-- membership — any active employee sees every Ready to Schedule delivery
-- order whose store belongs to the caller's company. Company is resolved
-- via employees.home_store_id -> stores.company_id, the same path
-- has_permission uses. An employee with no home store resolves to NULL
-- and sees nothing (safe direction). Company isolation is enforced
-- server-side inside the security-definer function; RLS is untouched.
--
-- Everything else is the m122 body verbatim: Ready to Schedule state,
-- delivery-only filters, cancelled/delivered exclusions, ready_at
-- computation, ordering, and output keys.

drop function if exists public.list_ready_journeys();

create or replace function public.list_ready_journeys(p_all_stores boolean default false)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_employee public.employees%rowtype;
  v_active_store uuid;
  v_company_id uuid;
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

  -- Caller's company via their home store — the same resolution
  -- has_permission and the rest of the app use. Null home store means
  -- no company rows, which is the safe direction.
  select s.company_id into v_company_id
  from public.stores s
  where s.id = v_employee.home_store_id;

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
        and s.company_id = v_company_id
        and (
          p_all_stores
          or sj.assigned_employee_id = v_employee.id
          or (v_active_store is not null and v_active_store = sj.store_id)
          or (v_employee.role = 'manager'
              and v_employee.home_store_id = sj.store_id)
        )
    ) r
  ), '[]'::jsonb);
end;
$$;


grant execute on function public.list_ready_journeys(boolean) to authenticated;
