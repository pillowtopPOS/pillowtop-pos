-- PillowTop POS m130: read helpers for the D1-b booking screens.
-- Read-only. No new tables, no changes to any 129 object.
--
--   * get_journey_delivery(journey) — active stop, full stop history,
--     and the earliest bookable date, in one call.
--   * get_delivery_cutoff() — the company's cutoff time plus whether the
--     caller may edit it (owner/admin). Saving uses the existing
--     companies-table update path (RLS owner/admin policy), same as the
--     other Company Settings fields — no write RPC needed.

-- ============================================================================
-- get_journey_delivery
-- ============================================================================

create or replace function public.get_journey_delivery(p_journey_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
  v_journey_company uuid;
  v_active record;
  v_history jsonb;
  v_earliest jsonb;
begin
  v_company_id := public.delivery_caller_company();
  if v_company_id is null then
    raise exception 'Only active employees can view deliveries.';
  end if;

  select s.company_id into v_journey_company
  from public.sleep_journeys sj
  join public.stores s on s.id = sj.store_id
  where sj.id = p_journey_id;

  if v_journey_company is null or v_journey_company <> v_company_id then
    raise exception 'That order is not in your company.';
  end if;
  if not public.is_journey_visible(p_journey_id) then
    raise exception 'You cannot view deliveries for that order.';
  end if;

  select ds.id, ds.delivery_date, ds.inside_cutoff, ds.override_reason,
         ds.created_at, ds.booked_by, e.name as booked_by_name
  into v_active
  from public.delivery_stops ds
  left join public.employees e on e.id = ds.booked_by
  where ds.journey_id = p_journey_id
    and ds.status = 'BOOKED'
  order by ds.created_at desc
  limit 1;

  select coalesce(jsonb_agg(row_to_json(h) order by h.created_at desc), '[]'::jsonb)
  into v_history
  from (
    select
      se.action,
      se.from_date,
      se.to_date,
      se.reason,
      se."override",
      e.name as actor_name,
      se.created_at
    from public.delivery_stop_events se
    left join public.employees e on e.id = se.actor_id
    where se.journey_id = p_journey_id
    order by se.created_at desc
    limit 50
  ) h;

  v_earliest := public.get_earliest_bookable_date(p_journey_id);

  return jsonb_build_object(
    'active_stop', case when v_active.id is null then null else jsonb_build_object(
      'id', v_active.id,
      'delivery_date', v_active.delivery_date,
      'inside_cutoff', v_active.inside_cutoff,
      'override_reason', v_active.override_reason,
      'booked_by_name', v_active.booked_by_name,
      'booked_at', v_active.created_at
    ) end,
    'history', v_history,
    'earliest', v_earliest
  );
end;
$$;

revoke execute on function public.get_journey_delivery(uuid) from public, anon;
grant execute on function public.get_journey_delivery(uuid) to authenticated;

-- ============================================================================
-- get_delivery_cutoff — read side of the Company Settings cutoff control.
-- ============================================================================

create or replace function public.get_delivery_cutoff()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
  v_cutoff time;
  v_role text;
begin
  v_company_id := public.delivery_caller_company();
  if v_company_id is null then
    raise exception 'Only active employees can view company settings.';
  end if;

  select c.delivery_cutoff_time into v_cutoff
  from public.companies c where c.id = v_company_id;

  select e.role::text into v_role
  from public.employees e
  where e.auth_user_id = auth.uid() and e.is_active;

  return jsonb_build_object(
    'cutoff_time', v_cutoff,
    'can_edit', coalesce(v_role in ('owner', 'admin'), false)
  );
end;
$$;

revoke execute on function public.get_delivery_cutoff() from public, anon;
grant execute on function public.get_delivery_cutoff() to authenticated;
