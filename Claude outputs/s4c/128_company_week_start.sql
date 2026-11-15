-- PillowTop POS m128: company-wide setting for which weekday the week
-- starts on. 1 = Monday, 7 = Sunday (ISO). Default Monday.
--
-- This is a GENERAL company setting (reports and commissions will use it
-- later), not a delivery setting. Delivery is just the first consumer.
--
--   * companies.week_start_day
--   * get_company_week_start()      — any active employee may read
--   * set_company_week_start(day)   — owner/admin only, same role check
--     set_role_permission uses (caller must be an active owner/admin
--     employee; no new permission key)
--   * company_week_start_date(co, date, scope) — first day of the week
--     containing a date, for future reports. p_scope names the feature
--     ('delivery', 'commission', 'reports'); accepted and ignored for
--     now — it always returns the company default.
--     Per-feature overrides (commission, reports) are future work;
--     commissions may not use weeks at all.
--
-- Safe to run twice (if not exists / create or replace).

alter table public.companies
  add column if not exists week_start_day smallint not null default 1
    check (week_start_day in (1, 7));

-- Any active employee may read it (calendars and reports need it for
-- everyone, not just managers).
create or replace function public.get_company_week_start()
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
  select s.company_id into v_company_id
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid()
    and e.is_active;
  if v_company_id is null then
    return 1;
  end if;
  select c.week_start_day into v_start
  from public.companies c
  where c.id = v_company_id;
  return coalesce(v_start, 1);
end;
$$;

grant execute on function public.get_company_week_start() to authenticated;

-- Owner/admin only — the same caller-role check set_role_permission uses.
create or replace function public.set_company_week_start(p_day smallint)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
  v_role text;
begin
  select e.role, s.company_id into v_role, v_company_id
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid()
    and e.is_active;

  if v_role is null or v_role not in ('owner', 'admin') then
    raise exception 'Only owners and admins can change company settings.';
  end if;
  if p_day is null or p_day not in (1, 7) then
    raise exception 'The week can only start on Sunday or Monday.';
  end if;
  if v_company_id is null then
    raise exception 'Only active employees can change company settings.';
  end if;

  update public.companies
  set week_start_day = p_day
  where id = v_company_id;
end;
$$;

grant execute on function public.set_company_week_start(smallint) to authenticated;

-- First day of the week containing p_date, per that company's setting.
-- Helper for reports/commissions; stable + definer so it can be used in
-- views and other functions without RLS noise.
create or replace function public.company_week_start_date(
  p_company uuid,
  p_date date,
  p_scope text default null
)
returns date
language sql
stable
security definer
set search_path = public
as $$
  select p_date - (
    (extract(isodow from p_date)::int
      - coalesce((
          select c.week_start_day from public.companies c
          where c.id = p_company
        ), 1)
      + 7) % 7
  )::int;
$$;

grant execute on function public.company_week_start_date(uuid, date, text) to authenticated;
