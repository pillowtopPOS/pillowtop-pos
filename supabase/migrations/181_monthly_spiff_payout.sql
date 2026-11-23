-- 181_monthly_spiff_payout.sql
--
-- Commission is paid per pay period; spiffs accrue by calendar month of
-- the sale and are paid once, on the LAST pay date of the following
-- month. A check goes out a fixed number of days (pay_date_lag_days)
-- after a period ends; a check is the last of its month when pay_date
-- plus the pay period length lands in a different calendar month, and
-- that check carries the month before its own month. Spiffs never count
-- toward the draw: pay = greatest(draw, commission, 0) + spiffs.
--
-- Closes freeze everything the new math produces: the carried spiff
-- month, the per-employee spiff totals and the pay date are written on
-- the close so later setting changes or late spiff entries can never
-- move a closed period's numbers.

-- ============================================================================
-- 1. companies.pay_date_lag_days: days from a period end to its pay
--    date. add column if not exists so a rerun never resets an owner's
--    value.
-- ============================================================================

alter table public.companies
  add column if not exists pay_date_lag_days integer not null default 5;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'companies_pay_date_lag_days_check'
  ) then
    alter table public.companies
      add constraint companies_pay_date_lag_days_check
      check (pay_date_lag_days between 0 and 60);
  end if;
end $$;

-- ============================================================================
-- 2. Frozen columns. commission_period_close_lines already has
--    spiff_cents (frozen as 0 until now); it now stores the carried
--    month's per-employee spiff total. The carried month and the pay
--    date freeze onto the close itself, and the not-deducted flag onto
--    each line, so reports for a closed period read frozen values.
-- ============================================================================

alter table public.commission_period_closes
  add column if not exists pay_date date,
  add column if not exists spiff_month_start date,
  add column if not exists spiff_month_end date;

alter table public.commission_period_close_lines
  add column if not exists spiffs_negative_not_deducted boolean
    not null default false;

-- ============================================================================
-- 3. Helpers.
-- ============================================================================

-- Pay date for a period: period end + the company's lag (5 when unset).
create or replace function public.commission_pay_date_for_period(
  p_company_id uuid,
  p_period_end date
)
returns date
language sql
stable
security definer
set search_path = public
as $$
  select p_period_end + coalesce(
    (select c.pay_date_lag_days
       from public.companies c
      where c.id = p_company_id),
    5
  );
$$;

revoke execute on function public.commission_pay_date_for_period(uuid, date)
  from public, anon, authenticated;

-- First day of the spiff month a check carries, or null when the check
-- is not the last pay date of its calendar month. A check is the last
-- of its month when pay_date + the pay period length lands in a
-- different month; the month carried is the month before the pay date's
-- month (the Oct 30 check carries September, Nov 27 carries October).
create or replace function public.commission_spiff_month_for_period(
  p_company_id uuid,
  p_period_start date,
  p_period_end date
)
returns date
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_pay_date date;
  v_days integer;
begin
  v_pay_date := public.commission_pay_date_for_period(
    p_company_id, p_period_end);

  select coalesce(c.pay_period_days, 14) into v_days
  from public.companies c
  where c.id = p_company_id;

  if v_pay_date is null or v_days is null or v_days <= 0 then
    return null;
  end if;

  if date_trunc('month', v_pay_date + v_days)
     = date_trunc('month', v_pay_date) then
    return null;
  end if;

  return (date_trunc('month', v_pay_date)::date
          - interval '1 month')::date;
end;
$$;

revoke execute on function public.commission_spiff_month_for_period(uuid, date, date)
  from public, anon, authenticated;

-- The check that pays a spiff month: the last pay date inside the
-- following calendar month. Pay dates are the period-end sequence plus
-- lag: pay_date_k = anchor + length*(k+1) - 1 + lag, so the largest k
-- whose pay date is on or before the end of the following month wins.
create or replace function public.commission_spiff_pay_date_for_month(
  p_company_id uuid,
  p_month date
)
returns date
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_anchor date;
  v_days integer;
  v_lag integer;
  v_target_end date;
  v_k integer;
begin
  select coalesce(c.pay_period_anchor, date '2024-01-01'),
         coalesce(c.pay_period_days, 14),
         coalesce(c.pay_date_lag_days, 5)
    into v_anchor, v_days, v_lag
  from public.companies c
  where c.id = p_company_id;

  if v_anchor is null or v_days is null or v_days <= 0 then
    return null;
  end if;

  -- Last day of the month AFTER p_month's month.
  v_target_end := (date_trunc('month', coalesce(p_month, current_date))
                   + interval '2 months - 1 day')::date;

  v_k := floor(
    ((v_target_end - v_anchor) + 1 - v_lag)::numeric / v_days
  )::integer;

  if v_k < 1 then
    return null;
  end if;

  return v_anchor + v_days * v_k - 1 + v_lag;
end;
$$;

revoke execute on function public.commission_spiff_pay_date_for_month(uuid, date)
  from public, anon, authenticated;

-- ============================================================================
-- 4. Pay schedule RPCs. get_pay_schedule is readable by any active
--    employee; set_pay_schedule needs commission.manage and audits
--    before/after. The column check enforces the 0-60 range.
-- ============================================================================

create or replace function public.get_pay_schedule()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
begin
  select s.company_id into v_company_id
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid()
    and e.is_active;

  if v_company_id is null then
    return null;
  end if;

  return (
    select jsonb_build_object('pay_date_lag_days', c.pay_date_lag_days)
    from public.companies c
    where c.id = v_company_id
  );
end;
$$;

revoke execute on function public.get_pay_schedule()
  from public, anon;
grant execute on function public.get_pay_schedule()
  to authenticated;

create or replace function public.set_pay_schedule(
  p_lag_days integer
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
  v_before jsonb;
  v_after jsonb;
begin
  if not public.has_permission('commission.manage') then
    raise exception 'You do not have permission to manage commissions';
  end if;

  select s.company_id into v_company_id
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid()
    and e.is_active;

  if v_company_id is null then
    raise exception 'Not authenticated as an employee';
  end if;

  select jsonb_build_object('pay_date_lag_days', c.pay_date_lag_days)
    into v_before
  from public.companies c
  where c.id = v_company_id;

  -- Stored verbatim; the column check rejects anything outside 0-60.
  update public.companies c
  set pay_date_lag_days = p_lag_days
  where c.id = v_company_id;

  v_after := jsonb_build_object('pay_date_lag_days', p_lag_days);

  perform public.log_audit_event(
    v_company_id,
    'companies',
    v_company_id,
    'PAY_SCHEDULE_SET',
    v_before,
    v_after
  );
end;
$$;

revoke execute on function public.set_pay_schedule(integer)
  from public, anon;
grant execute on function public.set_pay_schedule(integer)
  to authenticated;

-- ============================================================================
-- 5. get_payout_report: same keys plus pay_date, spiff_month_start,
--    spiff_month_end, per-employee spiffs_cents and
--    spiffs_negative_not_deducted. A negative month total floors at 0
--    for pay purposes and flags instead of dragging pay down (design
--    choice, to be revisited in C5). Closed periods read the frozen
--    lines and the frozen carried month from the close.
-- ============================================================================

drop function if exists public.get_payout_report(date);

create function public.get_payout_report(p_date date)
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
  late_entry_count integer,
  pay_date date,
  spiff_month_start date,
  spiff_month_end date,
  spiffs_cents integer,
  spiffs_negative_not_deducted boolean
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
  v_pay_date date;
  v_spiff_month date;
  v_spiff_month_end date;
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
    -- Frozen carried month and pay date come off the close; a close
    -- written before this migration has nulls, so pay_date falls back
    -- to the current lag only for those legacy rows.
    select c.pay_date, c.spiff_month_start, c.spiff_month_end
      into v_pay_date, v_spiff_month, v_spiff_month_end
    from public.commission_period_closes c
    where c.id = v_close_id;

    v_pay_date := coalesce(
      v_pay_date,
      public.commission_pay_date_for_period(v_company_id, v_end)
    );

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
                and ce.created_at > v_closed_at),
             v_pay_date, v_spiff_month, v_spiff_month_end,
             cl.spiff_cents, cl.spiffs_negative_not_deducted
      from public.commission_period_close_lines cl
      join public.employees emp on emp.id = cl.employee_id
      where cl.close_id = v_close_id
      order by emp.name;
    return;
  end if;

  -- Open: live commission numbers plus the carried-month spiff totals.
  v_pay_date := public.commission_pay_date_for_period(v_company_id, v_end);
  v_spiff_month := public.commission_spiff_month_for_period(
    v_company_id, v_start, v_end);
  v_spiff_month_end :=
    case when v_spiff_month is not null
         then (v_spiff_month + interval '1 month - 1 day')::date
         else null end;

  return query
    with base as (
      select l.employee_id, l.entry_count, l.not_calculated_count,
             l.commission_cents, l.draw_cents
      from public.commission_period_live_lines(
             v_company_id, v_start, v_end) l
    ),
    spiffs as (
      select ce.employee_id,
             coalesce(sum(ce.amount_cents), 0)::integer as s
      from public.commission_entries ce
      where ce.company_id = v_company_id
        and ce.employee_id is not null
        and ce.kind = 'SPIFF'
        and v_spiff_month is not null
        and ce.earned_date between v_spiff_month and v_spiff_month_end
      group by ce.employee_id
    ),
    people as (
      select b.employee_id from base b
      union
      select s.employee_id from spiffs s
    )
    select p.employee_id, emp.name, v_start, v_end,
           coalesce(b.entry_count, 0),
           coalesce(b.not_calculated_count, 0),
           coalesce(b.commission_cents, 0),
           coalesce(b.draw_cents, 0),
           greatest(coalesce(s.s, 0), 0),
           greatest(greatest(coalesce(b.draw_cents, 0),
                             coalesce(b.commission_cents, 0)), 0)
             + greatest(coalesce(s.s, 0), 0),
           greatest(coalesce(b.draw_cents, 0)
                    - coalesce(b.commission_cents, 0), 0),
           false, null::timestamptz, 0,
           v_pay_date, v_spiff_month, v_spiff_month_end,
           greatest(coalesce(s.s, 0), 0),
           (coalesce(s.s, 0) < 0)
    from people p
    left join base b on b.employee_id = p.employee_id
    left join spiffs s on s.employee_id = p.employee_id
    join public.employees emp on emp.id = p.employee_id
    order by emp.name;
end;
$$;

revoke execute on function public.get_payout_report(date)
  from public, anon;
grant execute on function public.get_payout_report(date)
  to authenticated;

-- ============================================================================
-- 6. close_commission_period: identical to 176 except the close now
--    freezes the carried spiff month, the pay date, each employee's
--    spiff total and the not-deducted flag. Live spiffs are summed over
--    the carried month exactly as the open report computes them, so
--    what the report showed before the close is what it shows after.
-- ============================================================================

create or replace function public.close_commission_period(p_date date)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
  v_caller_employee_id uuid;
  v_start date;
  v_end date;
  v_close_end date;
  v_close_id uuid;
  v_pay_date date;
  v_spiff_month date;
  v_spiff_month_end date;
begin
  if not public.has_permission('commission.payouts_manage') then
    raise exception 'You do not have permission to manage commission payouts';
  end if;

  select e.id, s.company_id
    into v_caller_employee_id, v_company_id
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid()
    and e.is_active;

  if v_company_id is null then
    raise exception 'Not authenticated as an employee';
  end if;

  if p_date is null then
    raise exception 'p_date is required';
  end if;

  -- p_date inside an ACTIVE close is already closed, whatever the current
  -- settings compute. Reopened closes are ignored.
  if exists (
    select 1
    from public.commission_period_closes c
    where c.company_id = v_company_id
      and c.reopened_at is null
      and c.period_start <= p_date
      and c.period_end >= p_date
  ) then
    raise exception 'The pay period containing % is already closed', p_date;
  end if;

  v_start := public.commission_pay_period_start(v_company_id, p_date);
  v_end := public.commission_pay_period_end(v_company_id, p_date);

  if v_start is null or v_end is null then
    raise exception 'Could not resolve the pay period for %', p_date;
  end if;

  -- Same clamp as get_payout_report: the new close starts the day after
  -- the newest active close that ends inside or before this window, so a
  -- close can never overlap an existing active close.
  select max(c.period_end) into v_close_end
  from public.commission_period_closes c
  where c.company_id = v_company_id
    and c.reopened_at is null
    and c.period_end < v_end;

  if v_close_end is not null and v_close_end + 1 > v_start then
    v_start := v_close_end + 1;
  end if;

  -- Defensive: refuse any residual overlap. After the clamp this should
  -- be impossible, but the never-overlap rule is absolute.
  if exists (
    select 1
    from public.commission_period_closes c
    where c.company_id = v_company_id
      and c.reopened_at is null
      and c.period_start <= v_end
      and c.period_end >= v_start
  ) then
    raise exception 'The pay period starting % overlaps an existing closed period', v_start;
  end if;

  if current_date <= v_end then
    raise warning 'Closing pay period % - % before it has ended', v_start, v_end;
  end if;

  -- Freeze what this check pays beyond the commission itself: the pay
  -- date, whether it is the last check of its month, and which spiff
  -- month it carries.
  v_pay_date := public.commission_pay_date_for_period(v_company_id, v_end);
  v_spiff_month := public.commission_spiff_month_for_period(
    v_company_id, v_start, v_end);
  v_spiff_month_end :=
    case when v_spiff_month is not null
         then (v_spiff_month + interval '1 month - 1 day')::date
         else null end;

  insert into public.commission_period_closes (
    company_id, period_start, period_end, closed_at, closed_by,
    pay_date, spiff_month_start, spiff_month_end
  ) values (
    v_company_id, v_start, v_end, now(), v_caller_employee_id,
    v_pay_date, v_spiff_month, v_spiff_month_end
  )
  returning id into v_close_id;

  insert into public.commission_period_close_lines (
    close_id, employee_id, entry_count, not_calculated_count,
    commission_cents, draw_cents, spiff_cents,
    spiffs_negative_not_deducted, pay_cents
  )
  select v_close_id, p.employee_id,
         coalesce(b.entry_count, 0),
         coalesce(b.not_calculated_count, 0),
         coalesce(b.commission_cents, 0),
         coalesce(b.draw_cents, 0),
         greatest(coalesce(s.s, 0), 0),
         (coalesce(s.s, 0) < 0),
         greatest(greatest(coalesce(b.draw_cents, 0),
                           coalesce(b.commission_cents, 0)), 0)
           + greatest(coalesce(s.s, 0), 0)
  from (
    select employee_id
    from public.commission_period_live_lines(
           v_company_id, v_start, v_end) l
    union
    select ce.employee_id
    from public.commission_entries ce
    where ce.company_id = v_company_id
      and ce.employee_id is not null
      and ce.kind = 'SPIFF'
      and v_spiff_month is not null
      and ce.earned_date between v_spiff_month and v_spiff_month_end
  ) p
  left join (
    select l.employee_id, l.entry_count, l.not_calculated_count,
           l.commission_cents, l.draw_cents
    from public.commission_period_live_lines(
           v_company_id, v_start, v_end) l
  ) b on b.employee_id = p.employee_id
  left join (
    select ce.employee_id,
           coalesce(sum(ce.amount_cents), 0)::integer as s
    from public.commission_entries ce
    where ce.company_id = v_company_id
      and ce.employee_id is not null
      and ce.kind = 'SPIFF'
      and v_spiff_month is not null
      and ce.earned_date between v_spiff_month and v_spiff_month_end
    group by ce.employee_id
  ) s on s.employee_id = p.employee_id;

  perform public.log_audit_event(
    v_company_id,
    'commission_period_close',
    v_close_id,
    'COMMISSION_PERIOD_CLOSED',
    null,
    jsonb_build_object(
      'period_start', v_start,
      'period_end', v_end,
      'line_count', (select count(*) from public.commission_period_close_lines
                     where close_id = v_close_id),
      'commission_cents_total', (select coalesce(sum(commission_cents), 0)
                                 from public.commission_period_close_lines
                                 where close_id = v_close_id),
      'pay_cents_total', (select coalesce(sum(pay_cents), 0)
                          from public.commission_period_close_lines
                          where close_id = v_close_id),
      'pay_date', v_pay_date,
      'spiff_month_start', v_spiff_month
    ),
    null,
    null
  );

  return v_close_id;
end;
$$;

revoke execute on function public.close_commission_period(date)
  from public, anon;
grant execute on function public.close_commission_period(date)
  to authenticated;

-- ============================================================================
-- 7. get_my_earnings: identical to 179 plus the additive pay_date key
--    for the period.
-- ============================================================================

create or replace function public.get_my_earnings(p_date date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_emp_id uuid;
  v_company_id uuid;
  v_start date;
  v_end date;
  v_is_closed boolean;
  v_show_revenue boolean;
  v_show_rate boolean;
  v_show_profit boolean;
  v_cost_switch boolean;
  v_show_draw boolean;
  v_cost_basis text;
  v_show_cost boolean;
  v_lines jsonb;
  v_total integer;
  v_pending integer;
  v_draw integer;
begin
  select e.id, s.company_id into v_emp_id, v_company_id
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid()
    and e.is_active;

  -- No employee row: null, not an empty report, so the client can tell
  -- "no account" apart from "a real empty period".
  if v_emp_id is null or v_company_id is null then
    return null;
  end if;

  select c.earnings_show_revenue, c.earnings_show_rate,
         c.earnings_show_profit, c.earnings_show_cost,
         c.earnings_show_draw_progress, c.commission_cost_basis
    into v_show_revenue, v_show_rate, v_show_profit,
         v_cost_switch, v_show_draw, v_cost_basis
  from public.companies c
  where c.id = v_company_id;

  -- Cost leaves the server only when the switch is on AND the company
  -- prices commission on COMMISSION_COST. On the WHOLESALE basis this
  -- stays false no matter how the switch is set.
  v_show_cost := coalesce(v_cost_switch, false)
                 and v_cost_basis = 'COMMISSION_COST';

  select p.period_start, p.period_end, p.is_closed
    into v_start, v_end, v_is_closed
  from public.commission_payout_period_for(v_company_id, p_date) p;

  select coalesce(
           jsonb_agg(l.line order by l.earned_date, l.created_at),
           '[]'::jsonb
         ),
         coalesce(sum(l.amount_cents), 0)::integer,
         count(*) filter (where l.pending)::integer
    into v_lines, v_total, v_pending
  from (
    select jsonb_build_object(
             'entry_id', ce.id,
             'earned_date', ce.earned_date,
             'journey_id', ce.journey_id,
             'journey_number', sj.journey_number,
             'item_name', li.item_name,
             'kind', ce.kind,
             'amount_cents', ce.amount_cents,
             'pending', (ce.amount_cents is null)
           )
           || case when v_show_revenue then
                jsonb_build_object('revenue_cents', ce.revenue_cents)
                else '{}'::jsonb end
           || case when v_show_rate then
                jsonb_build_object('rate_bp', ce.rate_bp,
                                   'credit_share_bp', ce.credit_share_bp)
                else '{}'::jsonb end
           || case when v_show_profit then
                jsonb_build_object(
                  'profit_cents',
                  case
                    when ce.revenue_cents is not null
                     and ce.cost_cents is not null
                    then ce.revenue_cents - ce.cost_cents
                  end)
                else '{}'::jsonb end
           || case when v_show_cost then
                jsonb_build_object('cost_cents', ce.cost_cents)
                else '{}'::jsonb end
             as line,
           ce.earned_date,
           ce.created_at,
           ce.amount_cents,
           (ce.amount_cents is null) as pending
    from public.commission_entries ce
    join public.sleep_journeys sj on sj.id = ce.journey_id
    left join public.journey_line_items li on li.id = ce.line_item_id
    where ce.company_id = v_company_id
      and ce.employee_id = v_emp_id
      and ce.kind in ('COMMISSION', 'ADJUSTMENT')
      and ce.earned_date between v_start and v_end
  ) l;

  -- Same effective-dated draw rule as the payout report: newest draw
  -- row at or before the period start, 0 when none exists.
  select d.amount_cents into v_draw
  from public.employee_draws d
  where d.company_id = v_company_id
    and d.employee_id = v_emp_id
    and d.effective_from <= v_start
  order by d.effective_from desc, d.created_at desc
  limit 1;

  return jsonb_build_object(
    'period_start', v_start,
    'period_end', v_end,
    'is_closed', coalesce(v_is_closed, false),
    'lines', v_lines,
    'total_cents', v_total,
    'pending_count', v_pending,
    'draw_progress',
      case when v_show_draw then
        jsonb_build_object(
          'draw_cents', coalesce(v_draw, 0),
          'commission_cents', v_total)
        else null end,
    'pay_date',
      public.commission_pay_date_for_period(v_company_id, v_end),
    'visibility', jsonb_build_object(
      'earnings_show_revenue', coalesce(v_show_revenue, false),
      'earnings_show_rate', coalesce(v_show_rate, false),
      'earnings_show_profit', coalesce(v_show_profit, false),
      'earnings_show_cost', v_show_cost,
      'earnings_show_draw_progress', coalesce(v_show_draw, false))
  );
end;
$$;

revoke execute on function public.get_my_earnings(date)
  from public, anon;
grant execute on function public.get_my_earnings(date)
  to authenticated;

-- ============================================================================
-- 8. get_my_spiffs: identical to 179 plus the additive paid_on key, the
--    last pay date inside the month after the spiff month.
-- ============================================================================

create or replace function public.get_my_spiffs(p_month date default current_date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_emp_id uuid;
  v_company_id uuid;
  v_month_start date;
  v_month_end date;
  v_lines jsonb;
  v_total integer;
begin
  select e.id, s.company_id into v_emp_id, v_company_id
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid()
    and e.is_active;

  if v_emp_id is null or v_company_id is null then
    return null;
  end if;

  v_month_start := date_trunc('month', coalesce(p_month, current_date))::date;
  v_month_end := (v_month_start + interval '1 month - 1 day')::date;

  select coalesce(
           jsonb_agg(l.line order by l.earned_date, l.created_at),
           '[]'::jsonb
         ),
         coalesce(sum(l.amount_cents), 0)::integer
    into v_lines, v_total
  from (
    select jsonb_build_object(
             'entry_id', ce.id,
             'earned_date', ce.earned_date,
             'label', coalesce(
               sr.name,
               case when ce.review_spiff_id is not null
                    then 'Google review'
                    else 'Spiff' end),
             'journey_number', sj.journey_number,
             'amount_cents', ce.amount_cents
           ) as line,
           ce.earned_date,
           ce.created_at,
           ce.amount_cents
    from public.commission_entries ce
    join public.sleep_journeys sj on sj.id = ce.journey_id
    left join public.spiff_rules sr on sr.id = ce.spiff_rule_id
    where ce.company_id = v_company_id
      and ce.employee_id = v_emp_id
      and ce.kind = 'SPIFF'
      and ce.earned_date between v_month_start and v_month_end
  ) l;

  return jsonb_build_object(
    'month_start', v_month_start,
    'month_end', v_month_end,
    'lines', v_lines,
    'total_cents', v_total,
    'paid_on',
      public.commission_spiff_pay_date_for_month(v_company_id, v_month_start)
  );
end;
$$;

revoke execute on function public.get_my_spiffs(date)
  from public, anon;
grant execute on function public.get_my_spiffs(date)
  to authenticated;
