-- ============================================================================
-- 179: my earnings
--
--   A rep-facing read of their OWN commission and spiffs. The ledger
--   stays locked behind commission.manage exactly as 174 set it: these
--   functions are security definer, resolve the caller from auth.uid()
--   and only ever return rows whose employee_id is the caller's own
--   employee id. No function accepts an employee id argument, so there
--   is no way to ask for anyone else's rows.
--
--   Five company switches on companies control how much detail the rep
--   sees. They default off so the go-live posture is "amounts only"
--   until an admin widens it. Wholesale cost can never leave this path:
--   cost_cents is returned only when the switch is on AND the company
--   basis is COMMISSION_COST.
-- ============================================================================

-- ============================================================================
-- 1. Visibility switches. Plain columns on companies alongside the
--    other commission settings from 174. get_commission_settings and
--    set_commission_settings are deliberately untouched so their
--    return shapes stay stable.
-- ============================================================================

alter table public.companies
  add column if not exists earnings_show_revenue boolean not null default false;
alter table public.companies
  add column if not exists earnings_show_rate boolean not null default false;
alter table public.companies
  add column if not exists earnings_show_profit boolean not null default false;
alter table public.companies
  add column if not exists earnings_show_cost boolean not null default false;
alter table public.companies
  add column if not exists earnings_show_draw_progress boolean not null default false;

-- ============================================================================
-- 2. Settings RPCs, both commission.manage. Warn never block: the five
--    values are stored exactly as sent, and every write is audited with
--    before and after.
-- ============================================================================

create or replace function public.get_earnings_visibility()
returns table(
  earnings_show_revenue boolean,
  earnings_show_rate boolean,
  earnings_show_profit boolean,
  earnings_show_cost boolean,
  earnings_show_draw_progress boolean,
  commission_cost_basis text
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
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
    return;
  end if;

  return query
    select c.earnings_show_revenue, c.earnings_show_rate,
           c.earnings_show_profit, c.earnings_show_cost,
           c.earnings_show_draw_progress, c.commission_cost_basis
    from public.companies c
    where c.id = v_company_id;
end;
$$;

revoke execute on function public.get_earnings_visibility()
  from public, anon;
grant execute on function public.get_earnings_visibility()
  to authenticated;

create or replace function public.set_earnings_visibility(
  p_show_revenue boolean,
  p_show_rate boolean,
  p_show_profit boolean,
  p_show_cost boolean,
  p_show_draw_progress boolean
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

  select jsonb_build_object(
           'earnings_show_revenue', c.earnings_show_revenue,
           'earnings_show_rate', c.earnings_show_rate,
           'earnings_show_profit', c.earnings_show_profit,
           'earnings_show_cost', c.earnings_show_cost,
           'earnings_show_draw_progress', c.earnings_show_draw_progress,
           'commission_cost_basis', c.commission_cost_basis
         )
    into v_before
  from public.companies c
  where c.id = v_company_id;

  update public.companies c
  set earnings_show_revenue = coalesce(p_show_revenue, false),
      earnings_show_rate = coalesce(p_show_rate, false),
      earnings_show_profit = coalesce(p_show_profit, false),
      earnings_show_cost = coalesce(p_show_cost, false),
      earnings_show_draw_progress = coalesce(p_show_draw_progress, false)
  where c.id = v_company_id;

  v_after := jsonb_build_object(
    'earnings_show_revenue', coalesce(p_show_revenue, false),
    'earnings_show_rate', coalesce(p_show_rate, false),
    'earnings_show_profit', coalesce(p_show_profit, false),
    'earnings_show_cost', coalesce(p_show_cost, false),
    'earnings_show_draw_progress', coalesce(p_show_draw_progress, false),
    'commission_cost_basis',
      (select c.commission_cost_basis
       from public.companies c where c.id = v_company_id)
  );

  perform public.log_audit_event(
    v_company_id,
    'companies',
    v_company_id,
    'EARNINGS_VISIBILITY_SET',
    v_before,
    v_after
  );
end;
$$;

revoke execute on function public.set_earnings_visibility(boolean, boolean, boolean, boolean, boolean)
  from public, anon;
grant execute on function public.set_earnings_visibility(boolean, boolean, boolean, boolean, boolean)
  to authenticated;

-- ============================================================================
-- 3. get_my_earnings: the caller's own ledger slice for the SAME window
--    the payout report uses (commission_payout_period_for: an active
--    close containing the date wins, otherwise the clamped live
--    window), so what a rep sees reconciles with what they are paid.
--    Returns null when the caller has no employee row.
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
-- 4. get_my_spiffs: the caller's own SPIFF rows for the calendar month
--    containing p_month. The label is the rule name for rule spiffs and
--    'Google review' for review spiffs; reversal rows carry the same
--    label with a negative amount.
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
    'total_cents', v_total
  );
end;
$$;

revoke execute on function public.get_my_spiffs(date)
  from public, anon;
grant execute on function public.get_my_spiffs(date)
  to authenticated;
