-- 182_sales_bonuses.sql
--
-- Monthly sales bonuses, computed per calendar month of delivered date
-- (commission_entries.earned_date, already store-local). Two plan
-- scopes: INDIVIDUAL (per employee, on their credit-share of delivered
-- sales) and STORE (the whole store's delivered sales, paid to the
-- store's manager). A month only pays when total margin for the month
-- meets the plan's margin floor; margin always uses true wholesale
-- cost, never the loaded commission cost.
--
-- bonus_plans are append-only like employee_draws: a new plan takes
-- effect for months whose first day is on or after its starts_on, and
-- the newest qualifying plan per scope wins. The preview is read only;
-- nothing here writes to commission_entries, payouts or close lines.

-- ============================================================================
-- 1. Tables. Tiers: the tier with the highest threshold <= sales pays
--    base + step_bonus * floor((sales - threshold) / step).
-- ============================================================================

create table if not exists public.bonus_plans (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  scope text not null check (scope in ('INDIVIDUAL', 'STORE')),
  name text not null,
  margin_floor_bp integer not null
    check (margin_floor_bp between 0 and 10000),
  starts_on date not null,
  created_by uuid references public.employees (id) on delete set null,
  created_at timestamptz not null default now()
);

create index if not exists idx_bonus_plans_company_scope
  on public.bonus_plans (company_id, scope, starts_on);

create table if not exists public.bonus_plan_tiers (
  plan_id uuid not null references public.bonus_plans (id) on delete cascade,
  threshold_cents bigint not null check (threshold_cents > 0),
  base_cents integer not null check (base_cents >= 0),
  step_cents bigint not null check (step_cents > 0),
  step_bonus_cents integer not null check (step_bonus_cents >= 0),
  primary key (plan_id, threshold_cents)
);

alter table public.bonus_plans enable row level security;
alter table public.bonus_plan_tiers enable row level security;

drop policy if exists bonus_plans_select on public.bonus_plans;
create policy bonus_plans_select
  on public.bonus_plans for select
  to authenticated
  using (public.is_own_company(company_id));

drop policy if exists bonus_plan_tiers_select on public.bonus_plan_tiers;
create policy bonus_plan_tiers_select
  on public.bonus_plan_tiers for select
  to authenticated
  using (
    exists (
      select 1 from public.bonus_plans p
      where p.id = bonus_plan_tiers.plan_id
        and public.is_own_company(p.company_id)
    )
  );

revoke all on public.bonus_plans from anon, public;
revoke all on public.bonus_plan_tiers from anon, public;
grant select on public.bonus_plans to authenticated;
grant select on public.bonus_plan_tiers to authenticated;
revoke insert, update, delete, truncate, references, trigger
  on public.bonus_plans from authenticated;
revoke insert, update, delete, truncate, references, trigger
  on public.bonus_plan_tiers from authenticated;

-- Append only: plans and tiers can never be edited or removed. A new
-- plan supersedes by starts_on, the same model draws use.
drop trigger if exists trg_bonus_plans_immutable on public.bonus_plans;
create trigger trg_bonus_plans_immutable
  before update or delete on public.bonus_plans
  for each row execute function public.commission_row_immutable();

drop trigger if exists trg_bonus_plan_tiers_immutable on public.bonus_plan_tiers;
create trigger trg_bonus_plan_tiers_immutable
  before update or delete on public.bonus_plan_tiers
  for each row execute function public.commission_row_immutable();

-- ============================================================================
-- 2. save_bonus_plan: insert a new plan with its tiers. commission.manage.
-- ============================================================================

create or replace function public.save_bonus_plan(
  p_scope text,
  p_name text,
  p_margin_floor_bp integer,
  p_starts_on date,
  p_tiers jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
  v_caller_employee_id uuid;
  v_plan_id uuid;
  v_tier jsonb;
  v_prev_threshold bigint;
  v_threshold bigint;
  v_base integer;
  v_step bigint;
  v_step_bonus integer;
  v_count integer := 0;
begin
  if not public.has_permission('commission.manage') then
    raise exception 'You do not have permission to manage commissions';
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

  if p_scope not in ('INDIVIDUAL', 'STORE') then
    raise exception 'scope must be INDIVIDUAL or STORE';
  end if;

  if p_name is null or btrim(p_name) = '' then
    raise exception 'A plan name is required';
  end if;

  if p_margin_floor_bp is null
     or p_margin_floor_bp < 0
     or p_margin_floor_bp > 10000 then
    raise exception 'margin_floor_bp must be between 0 and 10000';
  end if;

  if p_starts_on is null then
    raise exception 'starts_on is required';
  end if;

  if p_tiers is null
     or jsonb_typeof(p_tiers) <> 'array'
     or jsonb_array_length(p_tiers) = 0 then
    raise exception 'At least one tier is required';
  end if;

  -- Validate before inserting anything: thresholds strictly ascending,
  -- every number inside its column check range.
  v_prev_threshold := null;
  for v_tier in select * from jsonb_array_elements(p_tiers) loop
    v_threshold := (v_tier ->> 'threshold_cents')::bigint;
    v_base := (v_tier ->> 'base_cents')::integer;
    v_step := (v_tier ->> 'step_cents')::bigint;
    v_step_bonus := (v_tier ->> 'step_bonus_cents')::integer;

    if v_threshold is null or v_threshold <= 0 then
      raise exception 'Every tier threshold must be greater than 0';
    end if;
    if v_base is null or v_base < 0 then
      raise exception 'Every tier base must be 0 or more';
    end if;
    if v_step is null or v_step <= 0 then
      raise exception 'Every tier step must be greater than 0';
    end if;
    if v_step_bonus is null or v_step_bonus < 0 then
      raise exception 'Every tier step bonus must be 0 or more';
    end if;
    if v_prev_threshold is not null
       and v_threshold <= v_prev_threshold then
      raise exception 'Tier thresholds must be strictly ascending';
    end if;
    v_prev_threshold := v_threshold;
    v_count := v_count + 1;
  end loop;

  insert into public.bonus_plans (
    company_id, scope, name, margin_floor_bp, starts_on, created_by
  ) values (
    v_company_id, p_scope, btrim(p_name), p_margin_floor_bp,
    p_starts_on, v_caller_employee_id
  )
  returning id into v_plan_id;

  for v_tier in select * from jsonb_array_elements(p_tiers) loop
    insert into public.bonus_plan_tiers (
      plan_id, threshold_cents, base_cents, step_cents, step_bonus_cents
    ) values (
      v_plan_id,
      (v_tier ->> 'threshold_cents')::bigint,
      (v_tier ->> 'base_cents')::integer,
      (v_tier ->> 'step_cents')::bigint,
      (v_tier ->> 'step_bonus_cents')::integer
    );
  end loop;

  perform public.log_audit_event(
    v_company_id,
    'bonus_plan',
    v_plan_id,
    'BONUS_PLAN_SAVED',
    null,
    jsonb_build_object(
      'scope', p_scope,
      'name', btrim(p_name),
      'margin_floor_bp', p_margin_floor_bp,
      'starts_on', p_starts_on,
      'tier_count', v_count,
      'tiers', p_tiers
    )
  );

  return v_plan_id;
end;
$$;

revoke execute on function public.save_bonus_plan(text, text, integer, date, jsonb)
  from public, anon;
grant execute on function public.save_bonus_plan(text, text, integer, date, jsonb)
  to authenticated;

-- ============================================================================
-- 3. list_bonus_plans: plans with their tiers, newest first.
--    commission.payouts_view or commission.manage.
-- ============================================================================

create or replace function public.list_bonus_plans()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
begin
  if not (
    public.has_permission('commission.payouts_view')
    or public.has_permission('commission.manage')
  ) then
    raise exception 'You do not have permission to view bonuses';
  end if;

  select s.company_id into v_company_id
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid()
    and e.is_active;

  if v_company_id is null then
    return null;
  end if;

  return coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'plan_id', p.id,
          'scope', p.scope,
          'name', p.name,
          'margin_floor_bp', p.margin_floor_bp,
          'starts_on', p.starts_on,
          'created_at', p.created_at,
          'tiers', (
            select coalesce(jsonb_agg(
                     jsonb_build_object(
                       'threshold_cents', t.threshold_cents,
                       'base_cents', t.base_cents,
                       'step_cents', t.step_cents,
                       'step_bonus_cents', t.step_bonus_cents
                     )
                     order by t.threshold_cents),
                     '[]'::jsonb)
            from public.bonus_plan_tiers t
            where t.plan_id = p.id
          )
        )
        order by p.starts_on desc, p.created_at desc
      )
      from public.bonus_plans p
      where p.company_id = v_company_id
    ),
    '[]'::jsonb
  );
end;
$$;

revoke execute on function public.list_bonus_plans()
  from public, anon;
grant execute on function public.list_bonus_plans()
  to authenticated;

-- ============================================================================
-- 4. get_bonus_preview: read-only monthly bonus preview for a calendar
--    month. Sales are revenue_cents * credit_share_bp / 10000 over
--    COMMISSION and ADJUSTMENT entries (negative return entries subtract
--    in the month they land in). Cost is TRUE wholesale: the entry's
--    cost_cents under the WHOLESALE basis, or the line item's
--    unit_cost_snapshot (per unit, matching how the ledger priced cost)
--    under COMMISSION_COST. Margin uses exact integer math.
-- ============================================================================

create or replace function public.get_bonus_preview(p_month date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
  v_month_start date;
  v_month_end date;
  v_cost_basis text;
  v_plan_i_id uuid;
  v_plan_i_name text;
  v_plan_i_floor integer;
  v_plan_s_id uuid;
  v_plan_s_name text;
  v_plan_s_floor integer;
  v_ind jsonb := '[]'::jsonb;
  v_sto jsonb := '[]'::jsonb;
  r record;
  v_sales bigint;
  v_cost bigint;
  v_needs integer;
  v_margin_bp integer;
  v_margin_ok boolean;
  v_tier_threshold bigint;
  v_tier_base integer;
  v_tier_step bigint;
  v_tier_step_bonus integer;
  v_next bigint;
  v_bonus bigint;
  v_status text;
begin
  if not (
    public.has_permission('commission.payouts_view')
    or public.has_permission('commission.manage')
  ) then
    raise exception 'You do not have permission to view bonuses';
  end if;

  select s.company_id into v_company_id
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid()
    and e.is_active;

  if v_company_id is null or p_month is null then
    return null;
  end if;

  v_month_start := date_trunc('month', p_month)::date;
  v_month_end := (v_month_start + interval '1 month - 1 day')::date;

  select c.commission_cost_basis into v_cost_basis
  from public.companies c
  where c.id = v_company_id;

  -- Newest plan per scope whose window covers this month.
  select p.id, p.name, p.margin_floor_bp
    into v_plan_i_id, v_plan_i_name, v_plan_i_floor
  from public.bonus_plans p
  where p.company_id = v_company_id
    and p.scope = 'INDIVIDUAL'
    and p.starts_on <= v_month_start
  order by p.starts_on desc, p.created_at desc
  limit 1;

  select p.id, p.name, p.margin_floor_bp
    into v_plan_s_id, v_plan_s_name, v_plan_s_floor
  from public.bonus_plans p
  where p.company_id = v_company_id
    and p.scope = 'STORE'
    and p.starts_on <= v_month_start
  order by p.starts_on desc, p.created_at desc
  limit 1;

  for r in
    select a.employee_id,
           e.name as employee_name,
           e.home_store_id as store_id,
           a.sales_cents,
           a.cost_cents,
           a.needs_cost_count
    from (
      select ce.employee_id,
             coalesce(sum(
               case when ce.revenue_cents is not null
                    then floor(ce.revenue_cents::numeric
                         * coalesce(ce.credit_share_bp, 10000)
                         / 10000)::bigint
                    else 0 end), 0) as sales_cents,
             coalesce(sum(
               case when ce.revenue_cents is not null
                    then floor(
                         (case
                            when v_cost_basis = 'WHOLESALE'
                              then ce.cost_cents
                            else round(li.unit_cost_snapshot * 100)::integer
                          end)::numeric
                         * coalesce(ce.credit_share_bp, 10000)
                         / 10000)::bigint
                    else 0 end), 0) as cost_cents,
             count(*) filter (
               where ce.revenue_cents is not null
                 and (case
                        when v_cost_basis = 'WHOLESALE'
                          then ce.cost_cents
                        else round(li.unit_cost_snapshot * 100)::integer
                      end) is null
             )::integer as needs_cost_count
      from public.commission_entries ce
      left join public.journey_line_items li
        on li.id = ce.line_item_id
      where ce.company_id = v_company_id
        and ce.employee_id is not null
        and ce.kind in ('COMMISSION', 'ADJUSTMENT')
        and ce.earned_date between v_month_start and v_month_end
      group by ce.employee_id
    ) a
    join public.employees e on e.id = a.employee_id
    order by e.name
  loop
    v_sales := r.sales_cents;
    v_cost := r.cost_cents;
    v_needs := r.needs_cost_count;
    v_margin_bp := case when v_sales > 0
                        then floor((v_sales - v_cost) * 10000
                                   / v_sales)::integer
                        else null end;
    v_margin_ok := v_sales > 0
                   and v_needs = 0
                   and v_plan_i_id is not null
                   and (v_sales - v_cost) * 10000
                       >= v_plan_i_floor * v_sales;

    v_tier_threshold := null;
    v_tier_base := null;
    v_tier_step := null;
    v_tier_step_bonus := null;
    v_next := null;
    v_bonus := null;

    if v_plan_i_id is null then
      v_status := 'NO_PLAN';
    elsif v_needs > 0 then
      v_status := 'NEEDS_COST';
    elsif not v_margin_ok then
      v_status := 'BELOW_MARGIN';
      v_bonus := 0;
    else
      select t.threshold_cents, t.base_cents, t.step_cents,
             t.step_bonus_cents
        into v_tier_threshold, v_tier_base, v_tier_step,
             v_tier_step_bonus
      from public.bonus_plan_tiers t
      where t.plan_id = v_plan_i_id
        and t.threshold_cents <= v_sales
      order by t.threshold_cents desc
      limit 1;

      select min(t.threshold_cents) into v_next
      from public.bonus_plan_tiers t
      where t.plan_id = v_plan_i_id
        and t.threshold_cents > v_sales;

      if v_tier_threshold is null then
        v_status := 'BELOW_TIER';
        v_bonus := 0;
      else
        v_status := 'PAID_TIER';
        v_bonus := v_tier_base
          + v_tier_step_bonus
            * floor((v_sales - v_tier_threshold)::numeric
                    / v_tier_step)::bigint;
      end if;
    end if;

    v_ind := v_ind || jsonb_build_object(
      'employee_id', r.employee_id,
      'name', r.employee_name,
      'store_id', r.store_id,
      'sales_cents', v_sales,
      'cost_cents', v_cost,
      'margin_bp', v_margin_bp,
      'margin_ok', coalesce(v_margin_ok, false),
      'needs_cost_count', v_needs,
      'plan_name', v_plan_i_name,
      'tier_threshold_cents', v_tier_threshold,
      'bonus_cents', v_bonus,
      'next_threshold_cents', v_next,
      'to_next_cents',
        case when v_next is not null then v_next - v_sales end,
      'status', v_status
    );
  end loop;

  for r in
    select a.store_id,
           s.name as store_name,
           a.sales_cents,
           a.cost_cents,
           a.needs_cost_count
    from (
      select ce.store_id,
             coalesce(sum(
               case when ce.revenue_cents is not null
                    then floor(ce.revenue_cents::numeric
                         * coalesce(ce.credit_share_bp, 10000)
                         / 10000)::bigint
                    else 0 end), 0) as sales_cents,
             coalesce(sum(
               case when ce.revenue_cents is not null
                    then floor(
                         (case
                            when v_cost_basis = 'WHOLESALE'
                              then ce.cost_cents
                            else round(li.unit_cost_snapshot * 100)::integer
                          end)::numeric
                         * coalesce(ce.credit_share_bp, 10000)
                         / 10000)::bigint
                    else 0 end), 0) as cost_cents,
             count(*) filter (
               where ce.revenue_cents is not null
                 and (case
                        when v_cost_basis = 'WHOLESALE'
                          then ce.cost_cents
                        else round(li.unit_cost_snapshot * 100)::integer
                      end) is null
             )::integer as needs_cost_count
      from public.commission_entries ce
      left join public.journey_line_items li
        on li.id = ce.line_item_id
      where ce.company_id = v_company_id
        and ce.store_id is not null
        and ce.kind in ('COMMISSION', 'ADJUSTMENT')
        and ce.earned_date between v_month_start and v_month_end
      group by ce.store_id
    ) a
    join public.stores s on s.id = a.store_id
    order by s.name
  loop
    v_sales := r.sales_cents;
    v_cost := r.cost_cents;
    v_needs := r.needs_cost_count;
    v_margin_bp := case when v_sales > 0
                        then floor((v_sales - v_cost) * 10000
                                   / v_sales)::integer
                        else null end;
    v_margin_ok := v_sales > 0
                   and v_needs = 0
                   and v_plan_s_id is not null
                   and (v_sales - v_cost) * 10000
                       >= v_plan_s_floor * v_sales;

    v_tier_threshold := null;
    v_tier_base := null;
    v_tier_step := null;
    v_tier_step_bonus := null;
    v_next := null;
    v_bonus := null;

    if v_plan_s_id is null then
      v_status := 'NO_PLAN';
    elsif v_needs > 0 then
      v_status := 'NEEDS_COST';
    elsif not v_margin_ok then
      v_status := 'BELOW_MARGIN';
      v_bonus := 0;
    else
      select t.threshold_cents, t.base_cents, t.step_cents,
             t.step_bonus_cents
        into v_tier_threshold, v_tier_base, v_tier_step,
             v_tier_step_bonus
      from public.bonus_plan_tiers t
      where t.plan_id = v_plan_s_id
        and t.threshold_cents <= v_sales
      order by t.threshold_cents desc
      limit 1;

      select min(t.threshold_cents) into v_next
      from public.bonus_plan_tiers t
      where t.plan_id = v_plan_s_id
        and t.threshold_cents > v_sales;

      if v_tier_threshold is null then
        v_status := 'BELOW_TIER';
        v_bonus := 0;
      else
        v_status := 'PAID_TIER';
        v_bonus := v_tier_base
          + v_tier_step_bonus
            * floor((v_sales - v_tier_threshold)::numeric
                    / v_tier_step)::bigint;
      end if;
    end if;

    v_sto := v_sto || jsonb_build_object(
      'store_id', r.store_id,
      'store_name', r.store_name,
      'sales_cents', v_sales,
      'cost_cents', v_cost,
      'margin_bp', v_margin_bp,
      'margin_ok', coalesce(v_margin_ok, false),
      'needs_cost_count', v_needs,
      'plan_name', v_plan_s_name,
      'tier_threshold_cents', v_tier_threshold,
      'bonus_cents', v_bonus,
      'next_threshold_cents', v_next,
      'to_next_cents',
        case when v_next is not null then v_next - v_sales end,
      'status', v_status,
      'manager_employee_ids',
        (select coalesce(jsonb_agg(e.id order by e.name), '[]'::jsonb)
         from public.employees e
         where e.home_store_id = r.store_id
           and e.role = 'manager'
           and e.is_active)
    );
  end loop;

  return jsonb_build_object(
    'month_start', v_month_start,
    'month_end', v_month_end,
    'paid_on',
      public.commission_spiff_pay_date_for_month(
        v_company_id, v_month_start),
    'individual', v_ind,
    'store', v_sto
  );
end;
$$;

revoke execute on function public.get_bonus_preview(date)
  from public, anon;
grant execute on function public.get_bonus_preview(date)
  to authenticated;

-- ============================================================================
-- PART C(a). commission_spiff_pay_date_for_month: allow negative k so
-- months whose pay dates predate the pay period anchor still resolve.
-- Everything else identical to the 181 version.
-- ============================================================================

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

  -- floor() handles negative k correctly, so a spiff month whose pay
  -- dates precede the anchor still finds its last in-month check.
  v_k := floor(
    ((v_target_end - v_anchor) + 1 - v_lag)::numeric / v_days
  )::integer;

  return v_anchor + v_days * v_k - 1 + v_lag;
end;
$$;

revoke execute on function public.commission_spiff_pay_date_for_month(uuid, date)
  from public, anon, authenticated;

-- ============================================================================
-- PART C(b). set_pay_schedule: validate with a plain message before the
-- column check can fire. Everything else identical to the 181 version.
-- ============================================================================

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

  if p_lag_days is null or p_lag_days < 0 or p_lag_days > 60 then
    raise exception 'Days must be between 0 and 60.';
  end if;

  select jsonb_build_object('pay_date_lag_days', c.pay_date_lag_days)
    into v_before
  from public.companies c
  where c.id = v_company_id;

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
