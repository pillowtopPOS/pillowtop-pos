-- PillowTop POS m128: company setting for which weekday the delivery
-- calendar week starts on. 1 = Monday (ISO), 7 = Sunday. Default Monday.
--
-- Small surface on purpose: one column, one read RPC, one write RPC.
-- get_delivery_calendar is deliberately NOT touched (it has already been
-- redefined twice; the client computes week bounds itself).

alter table public.companies
  add column if not exists delivery_week_start smallint not null default 1
    check (delivery_week_start in (1, 7));

-- Any active employee may read it (the calendar grid needs it for
-- everyone, not just managers).
create or replace function public.get_delivery_week_start()
returns smallint
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
  v_start smallint;
begin
  v_company_id := public.delivery_caller_company();
  if v_company_id is null then
    return 1;
  end if;
  select c.delivery_week_start into v_start
  from public.companies c
  where c.id = v_company_id;
  return coalesce(v_start, 1);
end;
$$;

grant execute on function public.get_delivery_week_start() to authenticated;

-- Managers/owners (delivery.manage_trucks) change it.
create or replace function public.set_delivery_week_start(p_day smallint)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
begin
  if not public.has_permission('delivery.manage_trucks') then
    raise exception 'You do not have permission to manage delivery trucks.';
  end if;
  if p_day is null or p_day not in (1, 7) then
    raise exception 'The week can only start on Sunday or Monday.';
  end if;
  v_company_id := public.delivery_caller_company();
  if v_company_id is null then
    raise exception 'Only active employees can change delivery settings.';
  end if;
  update public.companies
  set delivery_week_start = p_day
  where id = v_company_id;
end;
$$;

grant execute on function public.set_delivery_week_start(smallint) to authenticated;
