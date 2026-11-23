-- ============================================================================
-- 177: payout period bounds
--
--   get_payout_report returns zero rows for an empty period, so the
--   client had no boundaries to display or navigate by. The fix is
--   server-side: the period lookup (an active close found by date
--   containment, else the live settings window clamped to start after
--   the newest earlier active close) moves into one shared helper,
--   commission_payout_period_for, called by both get_payout_report and
--   the new get_payout_period. One helper means the two functions can
--   never disagree about boundaries or closed state.
--
--   get_payout_report is replaced via create or replace with an
--   identical signature and identical results; only its internals move.
--   No new tables. Re-runnable throughout.
-- ============================================================================

-- ============================================================================
-- 1. commission_payout_period_for: the single source of truth for which
--    period a date belongs to. Internal only: no grants to browser roles.
--    Returns one row (or none when the date or company settings cannot
--    resolve a window).
-- ============================================================================

create or replace function public.commission_payout_period_for(
  p_company_id uuid,
  p_date date
)
returns table(
  period_start date,
  period_end date,
  is_closed boolean,
  closed_at timestamptz,
  close_id uuid
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_close public.commission_period_closes%rowtype;
  v_start date;
  v_end date;
  v_close_end date;
begin
  if p_company_id is null or p_date is null then
    return;
  end if;

  -- An active close covering p_date wins over the live computation.
  -- Only ACTIVE closes count: a reopened close is history and the dates
  -- report live again.
  select * into v_close
  from public.commission_period_closes c
  where c.company_id = p_company_id
    and c.reopened_at is null
    and c.period_start <= p_date
    and c.period_end >= p_date;

  if v_close.id is not null then
    return query
      select v_close.period_start, v_close.period_end, true,
             v_close.closed_at, v_close.id;
    return;
  end if;

  v_start := public.commission_pay_period_start(p_company_id, p_date);
  v_end := public.commission_pay_period_end(p_company_id, p_date);

  if v_start is null or v_end is null then
    return;
  end if;

  -- Clamp the live window: days already inside an active close must not
  -- be counted again. The newest active close that ends inside or before
  -- this window pushes the start to the day after it ends. A reopened
  -- close does not clamp.
  select max(c.period_end) into v_close_end
  from public.commission_period_closes c
  where c.company_id = p_company_id
    and c.reopened_at is null
    and c.period_end < v_end;

  if v_close_end is not null and v_close_end + 1 > v_start then
    v_start := v_close_end + 1;
  end if;

  return query
    select v_start, v_end, false, null::timestamptz, null::uuid;
end;
$$;

revoke execute on function public.commission_payout_period_for(uuid, date)
  from public, anon, authenticated;

-- ============================================================================
-- 2. get_payout_report: same signature and same results as 176. The
--    period decision now comes from commission_payout_period_for, so the
--    report can never disagree with get_payout_period about which
--    boundaries or closed state a date resolves to.
-- ============================================================================

create or replace function public.get_payout_report(p_date date)
returns table(
  employee_id uuid,
  employee_name text,
  period_start date,
  period_end date,
  entry_count integer,
  not_calculated_count integer,
  commission_cents integer,
  draw_cents integer,
  spiff_cents integer,
  pay_cents integer,
  draw_covers_cents integer,
  is_closed boolean,
  closed_at timestamptz,
  late_entry_count integer
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
  v_start date;
  v_end date;
  v_is_closed boolean;
  v_closed_at timestamptz;
  v_close_id uuid;
begin
  if not public.has_permission('commission.payouts_view') then
    raise exception 'You do not have permission to view commission payouts';
  end if;

  select s.company_id into v_company_id
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid()
    and e.is_active;

  if v_company_id is null or p_date is null then
    return;
  end if;

  select p.period_start, p.period_end, p.is_closed, p.closed_at,
         p.close_id
    into v_start, v_end, v_is_closed, v_closed_at, v_close_id
  from public.commission_payout_period_for(v_company_id, p_date) p;

  if v_start is null then
    return;
  end if;

  if v_is_closed then
    -- Closed: return the frozen lines exactly as written at close, with
    -- the close's own boundaries (which may no longer match settings).
    return query
      select cl.employee_id, emp.name, v_start, v_end,
             cl.entry_count, cl.not_calculated_count, cl.commission_cents,
             cl.draw_cents, cl.spiff_cents, cl.pay_cents,
             greatest(cl.draw_cents - cl.commission_cents, 0),
             true, v_closed_at,
             (select count(*)::integer
              from public.commission_entries ce
              where ce.company_id = v_company_id
                and ce.employee_id = cl.employee_id
                and ce.earned_date between v_start and v_end
                and ce.created_at > v_closed_at)
      from public.commission_period_close_lines cl
      join public.employees emp on emp.id = cl.employee_id
      where cl.close_id = v_close_id
      order by emp.name;
    return;
  end if;

  -- Open: live numbers, spiffs 0 until the spiffs slice.
  return query
    select l.employee_id, emp.name, v_start, v_end,
           l.entry_count, l.not_calculated_count, l.commission_cents,
           l.draw_cents, 0,
           -- Negative net commission (clawbacks) floors at 0 by design
           -- for now; it disappears exactly like a draw shortfall.
           greatest(greatest(l.draw_cents, l.commission_cents), 0),
           greatest(l.draw_cents - l.commission_cents, 0),
           false, null::timestamptz, 0
    from public.commission_period_live_lines(v_company_id, v_start, v_end) l
    join public.employees emp on emp.id = l.employee_id
    order by emp.name;
end;
$$;

revoke execute on function public.get_payout_report(date)
  from public, anon;
grant execute on function public.get_payout_report(date)
  to authenticated;

-- ============================================================================
-- 3. get_payout_period: the boundaries alone, for clients that need the
--    period even when the report is empty. Same permission and company
--    scoping as get_payout_report, same helper, so the dates the client
--    shows always match the rows it renders.
-- ============================================================================

create or replace function public.get_payout_period(p_date date)
returns table(
  period_start date,
  period_end date,
  is_closed boolean,
  closed_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
begin
  if not public.has_permission('commission.payouts_view') then
    raise exception 'You do not have permission to view commission payouts';
  end if;

  select s.company_id into v_company_id
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid()
    and e.is_active;

  if v_company_id is null or p_date is null then
    return;
  end if;

  return query
    select p.period_start, p.period_end, p.is_closed, p.closed_at
    from public.commission_payout_period_for(v_company_id, p_date) p;
end;
$$;

revoke execute on function public.get_payout_period(date)
  from public, anon;
grant execute on function public.get_payout_period(date)
  to authenticated;
