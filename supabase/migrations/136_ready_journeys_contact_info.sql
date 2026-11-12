-- ============================================================================
-- 136: list_ready_journeys returns customer_phone and customer_email.
--
-- My Work needs the customer's contact info on each ready row so the
-- salesperson can call or email without opening the order. Values are
-- the customer's phone/email as stored, trimmed, null when blank.
--
-- Nothing else changes: same signature, same existing keys (journey_id,
-- journey_number, customer_name, store_name, ready_after_wait_at,
-- ready_at, assigned_employee_name, item_summary, last_contact, held,
-- hold_until, callback_due, bad_number), same filters, same ordering,
-- same MATERIALIZED CTE structure. create or replace keeps the
-- (boolean) -> jsonb signature so grants survive; they are re-asserted
-- below. Safe to run twice. No em dash characters.
-- ============================================================================

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

  -- Caller's company via their home store - the same resolution
  -- has_permission and the rest of the app use. Null home store means
  -- no company rows, which is the safe direction.
  select s.company_id into v_company_id
  from public.stores s
  where s.id = v_employee.home_store_id;

  return coalesce((
    -- MATERIALIZED is load-bearing: without it the planner inlines these
    -- CTEs and re-runs delivery_contact_key_state once per joined row
    -- (measured: ~4.2s for 500 rows vs ~33ms materialized at 20k
    -- interactions).
    with base as materialized (
      select
        sj.id as journey_id,
        sj.customer_id,
        sj.journey_number,
        sj.ready_after_wait_at,
        sj.assigned_employee_id,
        public.delivery_norm_phone(c.phone) as norm_phone,
        c.first_name || ' ' || c.last_name as customer_name,
        nullif(btrim(c.phone), '') as customer_phone,
        nullif(btrim(c.email), '') as customer_email,
        s.name as store_name,
        e.name as assigned_employee_name,
        coalesce(ready_ev.ready_at, sj.ready_after_wait_at, sj.updated_at) as ready_at,
        coalesce(ready_ev.ready_at, sj.ready_after_wait_at, sj.updated_at) as stamp
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
    ),
    -- One key-state computation per distinct customer key, not per row:
    -- several ready orders for the same person share the same contact
    -- set, and the per-call cost is a scan of that company's contacts.
    keys as materialized (
      select distinct customer_id, norm_phone
      from base
    ),
    states as materialized (
      select k.customer_id, k.norm_phone,
        public.delivery_contact_key_state(
          v_company_id, k.customer_id, k.norm_phone, null) as dc
      from keys k
    )
    select jsonb_agg(r.row order by r.ready_at asc nulls last, r.stamp)
    from (
      select
        b.ready_at,
        b.stamp,
        jsonb_build_object(
          'journey_id', b.journey_id,
          'journey_number', b.journey_number,
          'customer_name', b.customer_name,
          'customer_phone', b.customer_phone,
          'customer_email', b.customer_email,
          'store_name', b.store_name,
          'ready_after_wait_at', b.ready_after_wait_at,
          'ready_at', b.ready_at,
          'assigned_employee_name', b.assigned_employee_name,
          'item_summary', case
            when items.n = 0 then null
            when items.n = 1 then items.first_name
            else items.first_name || ' and ' || (items.n - 1) || ' more'
          end,
          'last_contact', case
            when jsonb_typeof(st.dc -> 'last_contact') = 'object'
            then (st.dc -> 'last_contact') || jsonb_build_object(
              'on_this_order',
              (st.dc -> 'last_contact' ->> 'journey_id') = b.journey_id::text)
            else null
          end,
          'held', coalesce((st.dc ->> 'held')::boolean, false),
          'hold_until', st.dc -> 'hold_until',
          'callback_due', coalesce((st.dc ->> 'callback_due')::boolean, false),
          'bad_number', coalesce((st.dc ->> 'bad_number')::boolean, false)
        ) as row
      from base b
      join states st
        on st.customer_id = b.customer_id
       and st.norm_phone is not distinct from b.norm_phone
      left join lateral (
        select
          (array_agg(li.item_name order by li.created_at))[1] as first_name,
          count(*) as n
        from public.journey_line_items li
        where li.journey_id = b.journey_id
      ) items on true
    ) r
  ), '[]'::jsonb);
end;
$$;

revoke execute on function public.list_ready_journeys(boolean) from public, anon;
grant execute on function public.list_ready_journeys(boolean) to authenticated;
