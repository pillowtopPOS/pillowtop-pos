-- ============================================================================
-- 175: commission earning
--
--   1. commission_earn_for_unit: internal earner called once per inserted
--      journey_fulfillment_units row. Writes one COMMISSION entry per
--      EMPLOYEE credit share; idempotent through the partial unique index
--      idx_commission_entries_unit_earning (on conflict do nothing).
--   2. trg_zz_commission_earn: AFTER INSERT trigger, one row at a time.
--      Earning runs inside an exception handler: a failure raises a warning
--      and writes an audit_events row but never blocks the handover. The zz
--      name keeps it last if more AFTER row triggers are added later.
--   3. list_commission_entries: ledger read for commission.manage,
--      company scoped, newest first, capped at 2000 rows.
--   4. save_commission_plan, set_commission_settings,
--      get_commission_settings: settings RPCs for commission.manage.
--
--   Only DELIVERED / PER_ITEM / PROFIT is earned in v1; exchange child
--   journeys (sale_kind EXCHANGE) earn nothing. No backfill of earlier
--   handovers, no returns or exchange math, no UI, no changes to existing
--   functions. Re-runnable: every object uses or replace / drop if exists.
-- ============================================================================

-- ============================================================================
-- 1. commission_earn_for_unit. Internal only: security definer, no grant to
--    browser roles. Returns the number of ledger rows actually written
--    (0 on a rerun because the conflict is swallowed).
-- ============================================================================

create or replace function public.commission_earn_for_unit(p_unit_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_unit          public.journey_fulfillment_units%rowtype;
  v_ful           public.journey_fulfillments%rowtype;
  v_line          public.journey_line_items%rowtype;
  v_j             public.sleep_journeys%rowtype;
  v_company_id    uuid;
  v_earned_on     text;
  v_partial_mode  text;
  v_basis         text;
  v_cost_basis    text;
  v_revenue_cents integer;
  v_cost_cents    integer;
  v_profit_cents  integer;
  v_share         record;
  v_rate_bp       integer;
  v_amount_cents  integer;
  v_entry_flags   text[];
  v_inserted      integer;
  v_written       integer := 0;
begin
  select * into v_unit
  from public.journey_fulfillment_units
  where id = p_unit_id;
  if not found then
    return 0;
  end if;

  select * into v_ful
  from public.journey_fulfillments
  where id = v_unit.fulfillment_id;
  select * into v_line
  from public.journey_line_items
  where id = v_unit.line_item_id;
  select * into v_j
  from public.sleep_journeys
  where id = v_unit.journey_id;

  if v_ful.id is null or v_line.id is null or v_j.id is null then
    return 0;
  end if;

  select s.company_id into v_company_id
  from public.stores s
  where s.id = v_j.store_id;
  if v_company_id is null then
    return 0;
  end if;

  select c.commission_earned_on, c.commission_partial_mode,
         c.commission_basis, c.commission_cost_basis
    into v_earned_on, v_partial_mode, v_basis, v_cost_basis
  from public.companies c
  where c.id = v_company_id;

  -- v1 acts on DELIVERED / PER_ITEM / PROFIT only.
  if v_earned_on is distinct from 'DELIVERED'
     or v_partial_mode is distinct from 'PER_ITEM'
     or v_basis is distinct from 'PROFIT' then
    return 0;
  end if;

  -- Exchange replacement orders (sale_kind EXCHANGE, parent_journey_id
  -- set by the exchange commit) earn nothing in v1.
  if v_j.sale_kind = 'EXCHANGE' then
    return 0;
  end if;

  -- Credit, fee and other product-less lines carry no snapshots.
  if v_line.product_id is null then
    return 0;
  end if;

  if v_j.cancelled_at is not null then
    return 0;
  end if;

  -- unit_price and the snapshots are dollars per unit; one fulfillment
  -- unit earns on exactly one unit.
  v_revenue_cents := round(v_line.unit_price * 100)::integer;

  if v_cost_basis = 'WHOLESALE' then
    v_cost_cents := round(v_line.unit_cost_snapshot * 100)::integer;
  else
    v_cost_cents := round(v_line.unit_commission_cost_snapshot * 100)::integer;
  end if;

  -- Missing cost: the entry is still written (amount null, MISSING_COST
  -- flag) so the ledger shows the earning could not be priced.
  if v_cost_cents is not null then
    v_profit_cents := v_revenue_cents - v_cost_cents;
  end if;

  for v_share in
    select cs.employee_id, cs.share_bp
    from public.commission_credit_shares(v_unit.journey_id) cs
    where cs.kind = 'EMPLOYEE'
  loop
    -- STORE credit rows produce no ledger entry; store reporting reads
    -- sale_credits directly later. A null employee cannot be keyed into
    -- the ledger either.
    if v_share.employee_id is null then
      continue;
    end if;

    v_entry_flags := '{}'::text[];
    if v_cost_cents is null then
      v_entry_flags := array_append(v_entry_flags, 'MISSING_COST');
    elsif v_profit_cents < 0 then
      v_entry_flags := array_append(v_entry_flags, 'NEGATIVE_PROFIT');
    end if;

    -- Rate: the employee's own plan first, then the company default plan.
    select cp.rate_bp into v_rate_bp
    from public.employees e
    join public.commission_plans cp on cp.id = e.commission_plan_id
    where e.id = v_share.employee_id;

    if v_rate_bp is null then
      select cp.rate_bp into v_rate_bp
      from public.commission_plans cp
      where cp.company_id = v_company_id
        and cp.is_default
      limit 1;
    end if;

    if v_rate_bp is null then
      v_entry_flags := array_append(v_entry_flags, 'NO_PLAN');
      v_amount_cents := null;
    elsif v_profit_cents is null then
      v_amount_cents := null;
    else
      -- round half up = floor(x + 0.5) over exact numerics. rate_bp and
      -- share_bp are both basis points, so the divisor is 10000 * 10000
      -- = 100000000. Example: profit 60000 cents, rate 1000 bp
      -- (10 percent), share 10000 bp (full credit):
      --   floor(60000 * 1000 * 10000 / 100000000 + 0.5) = 6000 cents.
      v_amount_cents := floor(
        v_profit_cents::numeric * v_rate_bp * v_share.share_bp
        / 100000000 + 0.5
      )::integer;
    end if;

    insert into public.commission_entries (
      company_id, journey_id, line_item_id, fulfillment_unit_id,
      employee_id, store_id, kind, amount_cents, earned_at, earned_date,
      pay_period_start, revenue_cents, cost_cents, rate_bp,
      credit_share_bp, flags
    ) values (
      v_company_id, v_unit.journey_id, v_unit.line_item_id, v_unit.id,
      v_share.employee_id, v_j.store_id, 'COMMISSION', v_amount_cents,
      v_ful.recorded_at, v_ful.completed_on,
      coalesce(
        public.commission_pay_period_start(v_company_id, v_ful.completed_on),
        v_ful.completed_on
      ),
      v_revenue_cents, v_cost_cents, v_rate_bp, v_share.share_bp,
      v_entry_flags
    )
    on conflict (fulfillment_unit_id, employee_id, kind)
      where fulfillment_unit_id is not null and reverses_entry_id is null
      do nothing;

    get diagnostics v_inserted = row_count;
    v_written := v_written + v_inserted;
  end loop;

  return v_written;
end;
$$;

revoke execute on function public.commission_earn_for_unit(uuid)
  from public, anon, authenticated;

-- ============================================================================
-- 2. Trigger. The earn runs inside BEGIN ... EXCEPTION WHEN OTHERS so a
--    commission failure can never abort the handover insert. On error the
--    failure is recorded on audit_events as a SYSTEM actor; that write is
--    itself wrapped so even an audit failure only warns.
-- ============================================================================

create or replace function public.trg_commission_earn()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
begin
  perform public.commission_earn_for_unit(new.id);
  return new;
exception when others then
  raise warning 'commission_earn_for_unit failed for fulfillment unit %: %',
    new.id, sqlerrm;

  select s.company_id into v_company_id
  from public.sleep_journeys j
  join public.stores s on s.id = j.store_id
  where j.id = new.journey_id;

  begin
    perform public.log_audit_event(
      v_company_id,
      'journey_fulfillment_unit',
      new.id,
      'COMMISSION_EARN_ERROR',
      null,
      jsonb_build_object(
        'unit_id', new.id,
        'sqlstate', sqlstate,
        'error', sqlerrm
      ),
      'COMMISSION_EARN_FAILED',
      sqlerrm,
      new.journey_id,
      'SYSTEM'
    );
  exception when others then
    raise warning 'commission error audit write failed for unit %: %',
      new.id, sqlerrm;
  end;

  return new;
end;
$$;

revoke execute on function public.trg_commission_earn()
  from public, anon, authenticated;

drop trigger if exists trg_zz_commission_earn on public.journey_fulfillment_units;
create trigger trg_zz_commission_earn
  after insert on public.journey_fulfillment_units
  for each row execute function public.trg_commission_earn();

-- ============================================================================
-- 3. list_commission_entries: the commission.manage ledger read. Joins
--    employee, journey and line for display names; company scoped to the
--    caller; newest earned_date first; hard cap 2000 rows.
-- ============================================================================

create or replace function public.list_commission_entries(
  p_from date,
  p_to date,
  p_employee_id uuid default null
)
returns table(
  entry_id uuid,
  earned_date date,
  pay_period_start date,
  employee_id uuid,
  employee_name text,
  journey_id uuid,
  journey_number text,
  item_name text,
  kind text,
  amount_cents integer,
  revenue_cents integer,
  cost_cents integer,
  rate_bp integer,
  credit_share_bp integer,
  flags text[]
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
    raise exception 'You do not have permission to view commissions';
  end if;

  select s.company_id into v_company_id
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid()
    and e.is_active;

  return query
    select ce.id, ce.earned_date, ce.pay_period_start, ce.employee_id,
           emp.name, ce.journey_id, sj.journey_number, li.item_name,
           ce.kind, ce.amount_cents, ce.revenue_cents, ce.cost_cents,
           ce.rate_bp, ce.credit_share_bp, ce.flags
    from public.commission_entries ce
    join public.employees emp on emp.id = ce.employee_id
    join public.sleep_journeys sj on sj.id = ce.journey_id
    join public.journey_line_items li on li.id = ce.line_item_id
    where ce.company_id = v_company_id
      and (p_from is null or ce.earned_date >= p_from)
      and (p_to is null or ce.earned_date <= p_to)
      and (p_employee_id is null or ce.employee_id = p_employee_id)
    order by ce.earned_date desc
    limit 2000;
end;
$$;

revoke execute on function public.list_commission_entries(date, date, uuid)
  from public, anon;
grant execute on function public.list_commission_entries(date, date, uuid)
  to authenticated;

-- ============================================================================
-- 4. Settings RPCs, all commission.manage only.
-- ============================================================================

-- Creates a plan. When p_make_default, the previous default is cleared
-- first in the same statement sequence so the one-default partial unique
-- index idx_commission_plans_one_default is never violated.
create or replace function public.save_commission_plan(
  p_name text,
  p_rate_bp integer,
  p_make_default boolean default true
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
  v_plan_id uuid;
begin
  if not public.has_permission('commission.manage') then
    raise exception 'You do not have permission to manage commissions';
  end if;

  select s.company_id into v_company_id
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid()
    and e.is_active;

  if p_make_default then
    update public.commission_plans
    set is_default = false
    where company_id = v_company_id
      and is_default;
  end if;

  insert into public.commission_plans (company_id, name, rate_bp, is_default)
  values (v_company_id, p_name, p_rate_bp, coalesce(p_make_default, false))
  returning id into v_plan_id;

  return v_plan_id;
end;
$$;

revoke execute on function public.save_commission_plan(text, integer, boolean)
  from public, anon;
grant execute on function public.save_commission_plan(text, integer, boolean)
  to authenticated;

-- Updates only the pay-period columns on the caller's company; earned_on,
-- partial_mode and basis stay untouched until a later slice.
create or replace function public.set_commission_settings(
  p_pay_period_days integer,
  p_pay_period_anchor date
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
begin
  if not public.has_permission('commission.manage') then
    raise exception 'You do not have permission to manage commissions';
  end if;

  if p_pay_period_days is null
     or p_pay_period_days < 7
     or p_pay_period_days > 31 then
    raise exception 'Pay period must be between 7 and 31 days';
  end if;

  select s.company_id into v_company_id
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid()
    and e.is_active;

  update public.companies
  set pay_period_days = p_pay_period_days,
      pay_period_anchor = p_pay_period_anchor
  where id = v_company_id;
end;
$$;

revoke execute on function public.set_commission_settings(integer, date)
  from public, anon;
grant execute on function public.set_commission_settings(integer, date)
  to authenticated;

-- The caller company's commission settings plus its default plan. One row;
-- the plan fields are null when no default plan exists yet.
create or replace function public.get_commission_settings()
returns table(
  commission_earned_on text,
  commission_partial_mode text,
  commission_basis text,
  commission_cost_basis text,
  pay_period_days integer,
  pay_period_anchor date,
  default_plan_id uuid,
  default_plan_name text,
  default_plan_rate_bp integer
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
    raise exception 'You do not have permission to view commissions';
  end if;

  select s.company_id into v_company_id
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid()
    and e.is_active;

  return query
    select c.commission_earned_on, c.commission_partial_mode,
           c.commission_basis, c.commission_cost_basis,
           c.pay_period_days, c.pay_period_anchor,
           cp.id, cp.name, cp.rate_bp
    from public.companies c
    left join public.commission_plans cp
      on cp.company_id = c.id
      and cp.is_default
    where c.id = v_company_id;
end;
$$;

revoke execute on function public.get_commission_settings()
  from public, anon;
grant execute on function public.get_commission_settings()
  to authenticated;
