-- ============================================================================
-- 176: commission payouts
--
--   Pay for an employee for a pay period is greatest(draw, commission, 0)
--   plus spiffs. The draw is NOT paid on top of commission: when the draw
--   beats commission the extra is a shortfall that disappears; nothing
--   carries forward. spiff_cents exists on every report and close line and
--   is always 0 until the spiffs slice lands.
--
--   1. Permission keys commission.payouts_view and
--      commission.payouts_manage, seeded for owner and admin exactly the
--      way 174 seeded commission.manage. A bookkeeper gets payouts_view
--      through a per-employee permission override (set_employee_permission
--      grant), which is why both keys are added to is_valid_permission_key;
--      nothing about the bookkeeper is hardcoded.
--   2. employee_draws: append-only draw history per employee. The draw for
--      a period is the newest row with effective_from <= period_start; a
--      mid-period effective_from therefore applies from the next period
--      whose start is on or after it.
--   3. commission_period_closes + commission_period_close_lines: closing a
--      period freezes the numbers. A partial unique index allows only one
--      active (not reopened) close per company and period_start; reopening
--      keeps the old lines as history and frees the slot. get_payout_report
--      finds a closed period by date containment (not by recomputing the
--      period from settings), so a close stays reachable even after pay
--      period settings change, and both the report and close_commission_
--      period clamp a live window to start after the newest active close
--      so closes can never overlap live days.
--   4. RLS: select only, and only for commission.payouts_view inside the
--      own company. No insert/update/delete grants to browser roles.
--   5. RPCs, all security definer with the permission checked inside:
--      set_employee_draw, list_employee_draws, get_payout_report,
--      close_commission_period, reopen_commission_period.
--
--   Every draw change, close and reopen writes an audit_events row through
--   log_audit_event. Re-runnable: every object uses or replace /
--   if exists / if not exists / on conflict do nothing.
-- ============================================================================

-- ============================================================================
-- 1. Permission keys. is_valid_permission_key is the single whitelist for
--    set_role_permission and set_employee_permission, so the new keys must
--    be whitelisted for overrides (the bookkeeper grant) to be settable.
-- ============================================================================

create or replace function public.is_valid_permission_key(p_key text)
returns boolean
language sql
immutable
as $$
  select p_key in (
    'sleep_trial.manage_concerns',
    'sleep_trial.start_exchange',
    'sleep_trial.start_return',
    'sleep_trial.request_exceptions',
    'sleep_trial.approve_exceptions',
    'sleep_trial.approve_own_exceptions',
    'sleep_trial.approve_return_exceptions',
    'sleep_trial.override_protector',
    'sleep_trial.correct_dates',
    'sleep_trial.manage_policy',
    'sleep_trial.view_policy_details',
    'inventory.reduce_below_committed',
    'sleep_trial.complete_exchange',
    'inventory.inspect_returns',
    'inventory.manage_inspection_checklist',
    'sleep_trial.void_refund',
    'sleep_trial.reopen_action',
    'units.assign',
    'units.unassign',
    'units.override_set',
    'units.swap',
    'units.void',
    'units.manage_settings',
    'inventory.receive_po',
    'delivery.manage_trucks',
    'delivery.manage_calendar',
    'delivery.book_inside_cutoff',
    'delivery.log_confirmation_calls',
    'delivery.set_windows',
    'orders.mark_fulfilled',
    'orders.backdate_fulfillment',
    'delivery.finalize',
    'orders.pickup_any_location',
    'payments.record_refund',
    'payments.adjust_refund_amount',
    'commission.manage',
    'commission.view_own',
    'commission.payouts_view',
    'commission.payouts_manage'
  );
$$;

revoke execute on function public.is_valid_permission_key(text) from anon;

create or replace function public.seed_sleep_trial_permission_defaults(p_company_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.role_permission_grants (company_id, role, permission_key)
  select p_company_id, g.role, g.permission_key
  from (
    values
      -- manage_concerns: all roles
      ('owner',    'sleep_trial.manage_concerns'),
      ('admin',    'sleep_trial.manage_concerns'),
      ('manager',  'sleep_trial.manage_concerns'),
      ('sales',    'sleep_trial.manage_concerns'),
      ('employee', 'sleep_trial.manage_concerns'),
      -- start_exchange: all roles
      ('owner',    'sleep_trial.start_exchange'),
      ('admin',    'sleep_trial.start_exchange'),
      ('manager',  'sleep_trial.start_exchange'),
      ('sales',    'sleep_trial.start_exchange'),
      ('employee', 'sleep_trial.start_exchange'),
      -- start_return: all roles (161)
      ('owner',    'sleep_trial.start_return'),
      ('admin',    'sleep_trial.start_return'),
      ('manager',  'sleep_trial.start_return'),
      ('sales',    'sleep_trial.start_return'),
      ('employee', 'sleep_trial.start_return'),
      -- request_exceptions: all roles
      ('owner',    'sleep_trial.request_exceptions'),
      ('admin',    'sleep_trial.request_exceptions'),
      ('manager',  'sleep_trial.request_exceptions'),
      ('sales',    'sleep_trial.request_exceptions'),
      ('employee', 'sleep_trial.request_exceptions'),
      -- approve_exceptions: owner, admin, manager
      ('owner',    'sleep_trial.approve_exceptions'),
      ('admin',    'sleep_trial.approve_exceptions'),
      ('manager',  'sleep_trial.approve_exceptions'),
      -- approve_own_exceptions: owner, admin
      ('owner',    'sleep_trial.approve_own_exceptions'),
      ('admin',    'sleep_trial.approve_own_exceptions'),
      -- approve_return_exceptions (168): owner, admin
      ('owner',    'sleep_trial.approve_return_exceptions'),
      ('admin',    'sleep_trial.approve_return_exceptions'),
      -- override_protector: owner, admin
      ('owner',    'sleep_trial.override_protector'),
      ('admin',    'sleep_trial.override_protector'),
      -- correct_dates: owner, admin, manager
      ('owner',    'sleep_trial.correct_dates'),
      ('admin',    'sleep_trial.correct_dates'),
      ('manager',  'sleep_trial.correct_dates'),
      -- manage_policy: owner, admin
      ('owner',    'sleep_trial.manage_policy'),
      ('admin',    'sleep_trial.manage_policy'),
      -- view_policy_details: all roles
      ('owner',    'sleep_trial.view_policy_details'),
      ('admin',    'sleep_trial.view_policy_details'),
      ('manager',  'sleep_trial.view_policy_details'),
      ('sales',    'sleep_trial.view_policy_details'),
      ('employee', 'sleep_trial.view_policy_details'),
      -- reduce_below_committed (084 owner/manager, 085 admin):
      -- owner, admin, manager
      ('owner',    'inventory.reduce_below_committed'),
      ('admin',    'inventory.reduce_below_committed'),
      ('manager',  'inventory.reduce_below_committed'),
      -- complete_exchange (087): owner, admin
      ('owner',    'sleep_trial.complete_exchange'),
      ('admin',    'sleep_trial.complete_exchange'),
      -- inspect_returns (087): owner, admin, manager
      ('owner',    'inventory.inspect_returns'),
      ('admin',    'inventory.inspect_returns'),
      ('manager',  'inventory.inspect_returns'),
      -- manage_inspection_checklist (087): owner, admin
      ('owner',    'inventory.manage_inspection_checklist'),
      ('admin',    'inventory.manage_inspection_checklist'),
      -- void_refund (091): owner, admin
      ('owner',    'sleep_trial.void_refund'),
      ('admin',    'sleep_trial.void_refund'),
      -- reopen_action (164): admin, manager (owner implicit)
      ('admin',    'sleep_trial.reopen_action'),
      ('manager',  'sleep_trial.reopen_action'),
      -- record_refund (162): all roles (R1)
      ('owner',    'payments.record_refund'),
      ('admin',    'payments.record_refund'),
      ('manager',  'payments.record_refund'),
      ('sales',    'payments.record_refund'),
      ('employee', 'payments.record_refund'),
      -- adjust_refund_amount (162): admin, manager
      ('admin',    'payments.adjust_refund_amount'),
      ('manager',  'payments.adjust_refund_amount'),
      -- commission.manage (174): owner, admin
      ('owner',    'commission.manage'),
      ('admin',    'commission.manage'),
      -- commission.view_own (174): all roles
      ('owner',    'commission.view_own'),
      ('admin',    'commission.view_own'),
      ('manager',  'commission.view_own'),
      ('sales',    'commission.view_own'),
      ('employee', 'commission.view_own'),
      -- commission.payouts_view (176): owner, admin
      ('owner',    'commission.payouts_view'),
      ('admin',    'commission.payouts_view'),
      -- commission.payouts_manage (176): owner, admin
      ('owner',    'commission.payouts_manage'),
      ('admin',    'commission.payouts_manage')
  ) as g(role, permission_key)
  on conflict (company_id, role, permission_key) do nothing;
end;
$$;

revoke execute on function public.seed_sleep_trial_permission_defaults(uuid)
  from public, anon, authenticated;

-- Backfill every existing company (new ones get it through the
-- companies-insert trigger installed in 066).
select public.seed_sleep_trial_permission_defaults(id) from public.companies;

-- ============================================================================
-- 2. employee_draws: append-only draw history. "Append-only" is enforced
--    twice: browser roles get no write grant and no write policy, and a
--    trigger raises on update or delete so even a security-definer path
--    cannot mutate history. FK to employees is restrict: a draw row must
--    never silently disappear with an employee row.
-- ============================================================================

create table if not exists public.employee_draws (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  employee_id uuid not null references public.employees (id) on delete restrict,
  amount_cents integer not null check (amount_cents >= 0),
  effective_from date not null,
  note text,
  created_by uuid references public.employees (id) on delete set null,
  created_at timestamptz not null default now()
);

create index if not exists idx_employee_draws_lookup
  on public.employee_draws (company_id, employee_id, effective_from);

alter table public.employee_draws enable row level security;

drop policy if exists "Employee draws readable by commission.payouts_view"
  on public.employee_draws;
create policy "Employee draws readable by commission.payouts_view"
  on public.employee_draws for select
  to authenticated
  using (
    public.is_own_company(company_id)
    and public.has_permission('commission.payouts_view')
  );

-- ============================================================================
-- 3. Period closes. commission_period_closes keeps one row per close and
--    marks it reopened rather than deleting it, so history survives a
--    reopen. The partial unique index is what guarantees at most one
--    active close per company and period_start. commission_period_close_
--    lines is the frozen report written at close; it is append-only for
--    the same reason draws are.
-- ============================================================================

create table if not exists public.commission_period_closes (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  period_start date not null,
  period_end date not null,
  closed_at timestamptz not null default now(),
  closed_by uuid references public.employees (id) on delete set null,
  reopened_at timestamptz,
  reopened_by uuid references public.employees (id) on delete set null,
  reopen_reason text
);

-- Only one ACTIVE close per company and period_start. Reopened closes
-- fall out of the index, so a period can be closed again after a reopen
-- while the old close row and its lines stay as history.
create unique index if not exists idx_commission_closes_active
  on public.commission_period_closes (company_id, period_start)
  where reopened_at is null;

create index if not exists idx_commission_closes_company
  on public.commission_period_closes (company_id, period_start);

create table if not exists public.commission_period_close_lines (
  id uuid primary key default gen_random_uuid(),
  close_id uuid not null references public.commission_period_closes (id) on delete cascade,
  employee_id uuid not null references public.employees (id) on delete restrict,
  entry_count integer not null default 0,
  not_calculated_count integer not null default 0,
  commission_cents integer not null default 0,
  draw_cents integer not null default 0,
  spiff_cents integer not null default 0,
  pay_cents integer not null default 0,
  unique (close_id, employee_id)
);

create index if not exists idx_commission_close_lines_close
  on public.commission_period_close_lines (close_id);

alter table public.commission_period_closes enable row level security;
alter table public.commission_period_close_lines enable row level security;

drop policy if exists "Commission period closes readable by commission.payouts_view"
  on public.commission_period_closes;
create policy "Commission period closes readable by commission.payouts_view"
  on public.commission_period_closes for select
  to authenticated
  using (
    public.is_own_company(company_id)
    and public.has_permission('commission.payouts_view')
  );

-- Lines carry no company_id; scope comes through the parent close.
drop policy if exists "Commission close lines readable by commission.payouts_view"
  on public.commission_period_close_lines;
create policy "Commission close lines readable by commission.payouts_view"
  on public.commission_period_close_lines for select
  to authenticated
  using (
    public.has_permission('commission.payouts_view')
    and exists (
      select 1
      from public.commission_period_closes c
      where c.id = commission_period_close_lines.close_id
        and public.is_own_company(c.company_id)
    )
  );

-- Browser roles: select only. Supabase grants new tables to anon by
-- default; RLS already blocks every row, this removes the table privilege
-- as well (same treatment as the 174 tables).
revoke all on public.employee_draws from anon, public;
revoke all on public.commission_period_closes from anon, public;
revoke all on public.commission_period_close_lines from anon, public;
grant select on public.employee_draws to authenticated;
grant select on public.commission_period_closes to authenticated;
grant select on public.commission_period_close_lines to authenticated;

-- Supabase's default privileges give authenticated every privilege on a
-- new table; RLS was the only write blocker. Take the write privileges
-- away at the table level as well: these tables only ever change through
-- security definer functions.
revoke insert, update, delete, truncate, references, trigger
  on public.employee_draws from authenticated;
revoke insert, update, delete, truncate, references, trigger
  on public.commission_period_closes from authenticated;
revoke insert, update, delete, truncate, references, trigger
  on public.commission_period_close_lines from authenticated;

-- Same treatment for the 174/175 tables: every write to them already
-- goes through a security definer function (earning trigger, plan save,
-- credit RPCs), so the table-level write grant is unused.
revoke insert, update, delete, truncate, references, trigger
  on public.commission_entries from authenticated;
revoke insert, update, delete, truncate, references, trigger
  on public.commission_plans from authenticated;
revoke insert, update, delete, truncate, references, trigger
  on public.sale_credits from authenticated;

-- ============================================================================
-- 4. Append-only guard. employee_draws and commission_period_close_lines
--    must be immutable once written; the reopen path updates
--    commission_period_closes itself, so that table is intentionally not
--    guarded here.
-- ============================================================================

create or replace function public.commission_row_immutable()
returns trigger
language plpgsql
as $$
begin
  raise exception '% is append only; % is not allowed', tg_table_name, tg_op;
end;
$$;

revoke execute on function public.commission_row_immutable()
  from public, anon, authenticated;

drop trigger if exists trg_employee_draws_immutable on public.employee_draws;
create trigger trg_employee_draws_immutable
  before update or delete on public.employee_draws
  for each row execute function public.commission_row_immutable();

drop trigger if exists trg_commission_close_lines_immutable
  on public.commission_period_close_lines;
create trigger trg_commission_close_lines_immutable
  before update or delete on public.commission_period_close_lines
  for each row execute function public.commission_row_immutable();

-- ============================================================================
-- 5. commission_period_live_lines: the shared live computation behind
--    get_payout_report (open periods) and close_commission_period. One row
--    per employee who has a draw applicable to the period (the newest row
--    with effective_from <= period_start, even a 0 draw) or any
--    commission_entries row inside the period. Internal only: no grants to
--    browser roles.
-- ============================================================================

create or replace function public.commission_period_live_lines(
  p_company_id uuid,
  p_period_start date,
  p_period_end date
)
returns table(
  employee_id uuid,
  entry_count integer,
  not_calculated_count integer,
  commission_cents integer,
  draw_cents integer
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  return query
    with drawn as (
      select distinct on (d.employee_id)
             d.employee_id, d.amount_cents
      from public.employee_draws d
      where d.company_id = p_company_id
        and d.effective_from <= p_period_start
      order by d.employee_id, d.effective_from desc, d.created_at desc
    ),
    entries as (
      select ce.employee_id,
             count(*)::integer as entry_count,
             count(*) filter (where ce.amount_cents is null)::integer
               as not_calculated_count,
             coalesce(sum(ce.amount_cents), 0)::integer as commission_cents
      from public.commission_entries ce
      where ce.company_id = p_company_id
        and ce.employee_id is not null
        and ce.earned_date between p_period_start and p_period_end
      group by ce.employee_id
    ),
    people as (
      select drawn.employee_id from drawn
      union
      select entries.employee_id from entries
    )
    select p.employee_id,
           coalesce(en.entry_count, 0),
           coalesce(en.not_calculated_count, 0),
           coalesce(en.commission_cents, 0),
           coalesce(dr.amount_cents, 0)
    from people p
    left join entries en on en.employee_id = p.employee_id
    left join drawn dr on dr.employee_id = p.employee_id;
end;
$$;

revoke execute on function public.commission_period_live_lines(uuid, date, date)
  from public, anon, authenticated;

-- ============================================================================
-- 6. Public RPCs. Every one is security definer and checks its own
--    permission inside, so granting execute to authenticated is safe.
-- ============================================================================

-- set_employee_draw: append a draw row. Draws are never edited; a new row
-- with a later (or same) effective_from supersedes the old one for the
-- periods it covers.
create or replace function public.set_employee_draw(
  p_employee_id uuid,
  p_amount_cents integer,
  p_effective_from date,
  p_note text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
  v_caller_employee_id uuid;
  v_target_id uuid;
  v_draw_id uuid;
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

  if p_amount_cents is null or p_amount_cents < 0 then
    raise exception 'amount_cents must be 0 or more';
  end if;

  if p_effective_from is null then
    raise exception 'effective_from is required';
  end if;

  select e.id into v_target_id
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.id = p_employee_id
    and s.company_id = v_company_id;

  if v_target_id is null then
    raise exception 'Employee does not belong to your company';
  end if;

  insert into public.employee_draws (
    company_id, employee_id, amount_cents, effective_from, note, created_by
  ) values (
    v_company_id, p_employee_id, p_amount_cents, p_effective_from, p_note,
    v_caller_employee_id
  )
  returning id into v_draw_id;

  perform public.log_audit_event(
    v_company_id,
    'employee_draw',
    v_draw_id,
    'EMPLOYEE_DRAW_SET',
    null,
    jsonb_build_object(
      'employee_id', p_employee_id,
      'amount_cents', p_amount_cents,
      'effective_from', p_effective_from
    ),
    null,
    p_note
  );

  return v_draw_id;
end;
$$;

revoke execute on function public.set_employee_draw(uuid, integer, date, text)
  from public, anon;
grant execute on function public.set_employee_draw(uuid, integer, date, text)
  to authenticated;

-- list_employee_draws: the append-only history, newest effective_from
-- first per employee.
create or replace function public.list_employee_draws(
  p_employee_id uuid default null
)
returns table(
  draw_id uuid,
  employee_id uuid,
  employee_name text,
  amount_cents integer,
  effective_from date,
  note text,
  created_at timestamptz,
  created_by_name text
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

  return query
    select d.id, d.employee_id, emp.name, d.amount_cents, d.effective_from,
           d.note, d.created_at, creator.name
    from public.employee_draws d
    join public.employees emp on emp.id = d.employee_id
    left join public.employees creator on creator.id = d.created_by
    where d.company_id = v_company_id
      and (p_employee_id is null or d.employee_id = p_employee_id)
    order by emp.name, d.effective_from desc, d.created_at desc;
end;
$$;

revoke execute on function public.list_employee_draws(uuid)
  from public, anon;
grant execute on function public.list_employee_draws(uuid)
  to authenticated;

-- get_payout_report: one row per employee with a draw or entries in the
-- period containing p_date. A closed period is found by date containment
-- first, so it stays reachable by any date inside it even after pay
-- period settings change. Live numbers are clamped to start the day
-- after the newest active close, so days already closed are never
-- counted twice. late_entry_count stays live so entries that arrive
-- after the close are still visible. No cost fields ever.
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
  v_close public.commission_period_closes%rowtype;
  v_close_end date;
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

  -- An active close covering p_date wins over the live computation. Only
  -- ACTIVE closes count: a reopened close is history and the dates report
  -- live again.
  select * into v_close
  from public.commission_period_closes c
  where c.company_id = v_company_id
    and c.reopened_at is null
    and c.period_start <= p_date
    and c.period_end >= p_date;

  if v_close.id is not null then
    -- Closed: return the frozen lines exactly as written at close, with
    -- the close's own boundaries (which may no longer match settings).
    return query
      select cl.employee_id, emp.name, v_close.period_start,
             v_close.period_end,
             cl.entry_count, cl.not_calculated_count, cl.commission_cents,
             cl.draw_cents, cl.spiff_cents, cl.pay_cents,
             greatest(cl.draw_cents - cl.commission_cents, 0),
             true, v_close.closed_at,
             (select count(*)::integer
              from public.commission_entries ce
              where ce.company_id = v_company_id
                and ce.employee_id = cl.employee_id
                and ce.earned_date between v_close.period_start
                                       and v_close.period_end
                and ce.created_at > v_close.closed_at)
      from public.commission_period_close_lines cl
      join public.employees emp on emp.id = cl.employee_id
      where cl.close_id = v_close.id
      order by emp.name;
    return;
  end if;

  v_start := public.commission_pay_period_start(v_company_id, p_date);
  v_end := public.commission_pay_period_end(v_company_id, p_date);

  if v_start is null or v_end is null then
    return;
  end if;

  -- Clamp the live window: days already inside an active close must not
  -- be counted again. The newest active close that ends inside or before
  -- this window pushes the start to the day after it ends. A reopened
  -- close does not clamp.
  select max(c.period_end) into v_close_end
  from public.commission_period_closes c
  where c.company_id = v_company_id
    and c.reopened_at is null
    and c.period_end < v_end;

  if v_close_end is not null and v_close_end + 1 > v_start then
    v_start := v_close_end + 1;
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

-- close_commission_period: freeze the period containing p_date. The close
-- and all of its lines land in one transaction. A period that has not
-- ended yet warns but still closes (the client warns the user first).
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

  insert into public.commission_period_closes (
    company_id, period_start, period_end, closed_at, closed_by
  ) values (
    v_company_id, v_start, v_end, now(), v_caller_employee_id
  )
  returning id into v_close_id;

  insert into public.commission_period_close_lines (
    close_id, employee_id, entry_count, not_calculated_count,
    commission_cents, draw_cents, spiff_cents, pay_cents
  )
  select v_close_id, l.employee_id, l.entry_count, l.not_calculated_count,
         l.commission_cents, l.draw_cents, 0,
         -- Negative net commission (clawbacks) floors at 0 by design
         -- for now; it disappears exactly like a draw shortfall.
         greatest(greatest(l.draw_cents, l.commission_cents), 0)
  from public.commission_period_live_lines(v_company_id, v_start, v_end) l;

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
                          where close_id = v_close_id)
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

-- reopen_commission_period: mark the active close reopened (the close row
-- and its lines stay as history) so the period reports live numbers again
-- and can be closed again later. A reason is required.
create or replace function public.reopen_commission_period(
  p_date date,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
  v_caller_employee_id uuid;
  v_close public.commission_period_closes%rowtype;
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

  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'A reopen reason is required';
  end if;

  -- Containment, like get_payout_report: the close stays findable by any
  -- date inside it even if pay period settings changed after the close.
  select * into v_close
  from public.commission_period_closes c
  where c.company_id = v_company_id
    and c.reopened_at is null
    and c.period_start <= p_date
    and c.period_end >= p_date;

  if v_close.id is null then
    raise exception 'No closed pay period containing % to reopen', p_date;
  end if;

  update public.commission_period_closes
  set reopened_at = now(),
      reopened_by = v_caller_employee_id,
      reopen_reason = p_reason
  where id = v_close.id;

  perform public.log_audit_event(
    v_company_id,
    'commission_period_close',
    v_close.id,
    'COMMISSION_PERIOD_REOPENED',
    jsonb_build_object(
      'period_start', v_close.period_start,
      'period_end', v_close.period_end,
      'closed_at', v_close.closed_at
    ),
    jsonb_build_object(
      'reopened_at', now(),
      'reopen_reason', p_reason
    ),
    null,
    p_reason
  );
end;
$$;

revoke execute on function public.reopen_commission_period(date, text)
  from public, anon;
grant execute on function public.reopen_commission_period(date, text)
  to authenticated;

-- list_commission_closes: the close history, newest period first.
-- Reopened closes are included; reopened_at / reopen_reason distinguish
-- them from the active ones.
create or replace function public.list_commission_closes(
  p_limit integer default 24
)
returns table(
  close_id uuid,
  period_start date,
  period_end date,
  closed_at timestamptz,
  closed_by_name text,
  reopened_at timestamptz,
  reopen_reason text,
  total_pay_cents integer
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

  return query
    select c.id, c.period_start, c.period_end, c.closed_at, emp.name,
           c.reopened_at, c.reopen_reason,
           coalesce((
             select sum(cl.pay_cents)
             from public.commission_period_close_lines cl
             where cl.close_id = c.id
           ), 0)::integer
    from public.commission_period_closes c
    left join public.employees emp on emp.id = c.closed_by
    where c.company_id = v_company_id
    order by c.period_start desc, c.closed_at desc
    limit greatest(coalesce(p_limit, 24), 0);
end;
$$;

revoke execute on function public.list_commission_closes(integer)
  from public, anon;
grant execute on function public.list_commission_closes(integer)
  to authenticated;
