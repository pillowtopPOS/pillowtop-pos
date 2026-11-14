-- PillowTop POS m139: get_delivery_call_alert — read-only pop-up feed
-- for the "customers need confirmation calls" alert. No writes, no
-- new tables. NOT YET INSTALLED — pending review.
--
-- Returns jsonb for the CALLER's company:
--   { eligible, date, route_closed, team_open, my_open, total_stops }
-- eligible=false short-circuits to {"eligible": false} only.
-- date/team_open/my_open come from get_delivery_confirmation_list
-- itself (null date = the RPC's own "next delivery day" pick), so the
-- alert can never disagree with the call list or the My Work banner.

create or replace function public.get_delivery_call_alert()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
  v_all jsonb;
  v_mine jsonb;
  v_date date;
  v_team_open integer := 0;
  v_my_open integer := 0;
  v_total integer := 0;
  v_route_closed boolean := false;
begin
  v_company_id := public.delivery_caller_company();
  if v_company_id is null then
    return jsonb_build_object('eligible', false);
  end if;
  if not public.has_permission('delivery.log_confirmation_calls') then
    return jsonb_build_object('eligible', false);
  end if;

  -- The list RPCs pick the date themselves and are already scoped to
  -- the caller's company, so there is exactly one date rule.
  v_all := public.get_delivery_confirmation_list(null, 'all');
  v_mine := public.get_delivery_confirmation_list(null, 'mine');

  v_date := nullif(v_all ->> 'date', '')::date;

  if v_date is not null then
    select count(*) into v_team_open
    from jsonb_array_elements(
      coalesce(v_all -> 'items', '[]'::jsonb)) it
    where it ->> 'status' is distinct from 'confirmed';

    select count(*) into v_my_open
    from jsonb_array_elements(
      coalesce(v_mine -> 'items', '[]'::jsonb)) it
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
    'team_open', v_team_open,
    'my_open', v_my_open,
    'total_stops', v_total
  );
end;
$$;

revoke execute on function public.get_delivery_call_alert()
  from public, anon;
grant execute on function public.get_delivery_call_alert()
  to authenticated;
