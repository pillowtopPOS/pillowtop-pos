-- ============================================================================
-- 174: commission foundation
--
--   1. companies: commission earning mode, basis and pay-period settings.
--   2. commission_plans: flat-rate plans; one default per company;
--      employees.commission_plan_id points at a plan (null = company default).
--   3. sale_credits: who shares credit on a sale, with supersede history.
--   4. commission_entries: the append-only ledger (no update/delete policies).
--   5. RLS on the three new tables; nothing granted to anon.
--   6. Permission keys commission.manage and commission.view_own.
--   7. Pay-period helpers and the internal credit-share reader.
--
--   Schema and access only. No earning logic, no triggers on fulfillment,
--   no UI. Re-runnable: every object uses if not exists / or replace /
--   drop ... if exists. No backfill beyond the permission seed.
-- ============================================================================

-- ============================================================================
-- 1. companies columns. Only DELIVERED, PER_ITEM and PROFIT are acted on by
--    the earning logic in the next migration; the other enum values are
--    accepted now so the settings table is complete before the UI exists.
-- ============================================================================

alter table public.companies
  add column if not exists commission_earned_on text not null default 'DELIVERED';
alter table public.companies
  add column if not exists commission_partial_mode text not null default 'PER_ITEM';
alter table public.companies
  add column if not exists commission_basis text not null default 'PROFIT';
alter table public.companies
  add column if not exists pay_period_days integer not null default 14;
alter table public.companies
  add column if not exists pay_period_anchor date;

alter table public.companies
  drop constraint if exists companies_commission_earned_on_check;
alter table public.companies
  add constraint companies_commission_earned_on_check
  check (commission_earned_on in ('WRITTEN', 'PAID_IN_FULL', 'DELIVERED'));

alter table public.companies
  drop constraint if exists companies_commission_partial_mode_check;
alter table public.companies
  add constraint companies_commission_partial_mode_check
  check (commission_partial_mode in ('PER_ITEM', 'WHOLE_TICKET'));

alter table public.companies
  drop constraint if exists companies_commission_basis_check;
alter table public.companies
  add constraint companies_commission_basis_check
  check (commission_basis in ('PROFIT', 'REVENUE'));

alter table public.companies
  drop constraint if exists companies_pay_period_days_check;
alter table public.companies
  add constraint companies_pay_period_days_check
  check (pay_period_days between 7 and 31);

comment on column public.companies.commission_earned_on is
  'When commission is earned: WRITTEN (at sale), PAID_IN_FULL, or DELIVERED (first handover). Only DELIVERED is acted on by the earning logic in the next migration; the other values are accepted for future use.';
comment on column public.companies.commission_partial_mode is
  'Partial fulfillment handling: PER_ITEM earns on each unit as it is handed over, WHOLE_TICKET waits for the last unit. Only PER_ITEM is acted on by the earning logic in the next migration.';
comment on column public.companies.commission_basis is
  'What the rate applies to: PROFIT (revenue minus cost) or REVENUE. Only PROFIT is acted on by the earning logic in the next migration.';
comment on column public.companies.pay_period_days is
  'Length of a commission pay period in days (7-31).';
comment on column public.companies.pay_period_anchor is
  'Date any pay period starts on; other period boundaries count forward and backward from it. Null means the default anchor 2024-01-01 is used.';

-- ============================================================================
-- 2. commission_plans + employees.commission_plan_id
-- ============================================================================

create table if not exists public.commission_plans (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  name text not null,
  -- Basis points of the basis (profit or revenue); 1000 = 10 percent.
  rate_bp integer not null check (rate_bp between 0 and 10000),
  is_default boolean not null default false,
  created_at timestamptz not null default now()
);

comment on table public.commission_plans is
  'Commission plans: flat rate today; margin tiers will add a child table later.';

-- A company has at most one default plan.
create unique index if not exists idx_commission_plans_one_default
  on public.commission_plans (company_id) where is_default;

alter table public.employees
  add column if not exists commission_plan_id uuid
    references public.commission_plans (id) on delete set null;

comment on column public.employees.commission_plan_id is
  'The plan this employee earns under; null means the company default plan applies.';

-- ============================================================================
-- 3. sale_credits: per-journey credit split. Rows are never deleted;
--    superseded_at marks the moment a row stopped being the active split.
-- ============================================================================

create table if not exists public.sale_credits (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  journey_id uuid not null references public.sleep_journeys (id) on delete cascade,
  kind text not null check (kind in ('EMPLOYEE', 'STORE')),
  employee_id uuid references public.employees (id) on delete set null,
  store_id uuid references public.stores (id) on delete set null,
  share_bp integer not null check (share_bp between 1 and 10000),
  reason text,
  created_by uuid references public.employees (id) on delete set null,
  created_at timestamptz not null default now(),
  superseded_at timestamptz,
  check (
    (kind = 'EMPLOYEE' and employee_id is not null and store_id is null)
    or (kind = 'STORE' and store_id is not null and employee_id is null)
  )
);

comment on table public.sale_credits is
  'Credit split for a sale. Active rows have superseded_at null; when no active row exists for a kind the default is the assigned employee / selling store at 100 percent.';

create index if not exists idx_sale_credits_active_journey
  on public.sale_credits (journey_id) where superseded_at is null;

-- ============================================================================
-- 4. commission_entries: the ledger. The app never edits or deletes rows -
--    corrections are new ADJUSTMENT rows (reverses_entry_id points at what
--    they reverse), so there is no UPDATE or DELETE policy.
-- ============================================================================

create table if not exists public.commission_entries (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  journey_id uuid not null references public.sleep_journeys (id) on delete cascade,
  line_item_id uuid not null references public.journey_line_items (id) on delete cascade,
  fulfillment_unit_id uuid references public.journey_fulfillment_units (id) on delete set null,
  employee_id uuid not null references public.employees (id) on delete restrict,
  store_id uuid references public.stores (id) on delete set null,
  kind text not null check (kind in ('COMMISSION', 'SPIFF', 'ADJUSTMENT')),
  amount_cents integer, -- null means cost was missing and could not be computed
  earned_at timestamptz not null,
  earned_date date not null, -- store local date the earning attaches to
  pay_period_start date not null,
  revenue_cents integer,
  cost_cents integer,
  rate_bp integer,
  credit_share_bp integer,
  flags text[] not null default '{}', -- e.g. 'MISSING_COST'
  reverses_entry_id uuid references public.commission_entries (id) on delete set null,
  note text,
  created_at timestamptz not null default now()
);

-- When the table already exists from an earlier run (created with on delete
-- cascade on employee_id), create table if not exists is a no-op, so the
-- foreign key is replaced here. A ledger row must never disappear when an
-- employee row is removed. The real constraint name is looked up in
-- pg_constraint rather than assumed; the re-added constraint uses the name
-- Postgres generates on a fresh create so both paths end identical.
do $$
declare
  v_conname text;
  v_confdeltype char;
begin
  select c.conname, c.confdeltype into v_conname, v_confdeltype
  from pg_constraint c
  join pg_class child on child.oid = c.conrelid
  join pg_namespace child_ns on child_ns.oid = child.relnamespace
  join pg_class parent on parent.oid = c.confrelid
  join pg_namespace parent_ns on parent_ns.oid = parent.relnamespace
  where c.contype = 'f'
    and child_ns.nspname = 'public'
    and child.relname = 'commission_entries'
    and parent_ns.nspname = 'public'
    and parent.relname = 'employees'
    and exists (
      select 1
      from pg_attribute a
      where a.attrelid = child.oid
        and a.attname = 'employee_id'
        and a.attnum = any(c.conkey)
    );

  if v_conname is not null and v_confdeltype <> 'r' then
    execute format(
      'alter table public.commission_entries drop constraint %I',
      v_conname
    );
    v_conname := null;
  end if;

  if v_conname is null and to_regclass('public.commission_entries') is not null then
    alter table public.commission_entries
      add constraint commission_entries_employee_id_fkey
      foreign key (employee_id)
      references public.employees (id) on delete restrict;
  end if;
end;
$$;

comment on table public.commission_entries is
  'Append-only commission ledger. amount_cents null means cost was missing and the amount could not be computed (flags carries MISSING_COST). Rows are never edited or deleted; corrections are new ADJUSTMENT rows keyed by reverses_entry_id.';

-- One live earning entry per unit, employee and kind. Reversal rows
-- (reverses_entry_id set) are excluded so they never collide with a
-- re-earn after a reversal.
create unique index if not exists idx_commission_entries_unit_earning
  on public.commission_entries (fulfillment_unit_id, employee_id, kind)
  where fulfillment_unit_id is not null and reverses_entry_id is null;

create index if not exists idx_commission_entries_journey
  on public.commission_entries (journey_id);
create index if not exists idx_commission_entries_employee_period
  on public.commission_entries (employee_id, pay_period_start);

-- ============================================================================
-- 5. RLS. Browser roles can only SELECT; all writes come from
--    security-definer functions in later migrations, so there are no
--    insert/update/delete policies. Nothing is granted to anon.
-- ============================================================================

alter table public.commission_plans enable row level security;
alter table public.sale_credits enable row level security;
alter table public.commission_entries enable row level security;

drop policy if exists "Commission plans readable by commission.manage"
  on public.commission_plans;
create policy "Commission plans readable by commission.manage"
  on public.commission_plans for select
  to authenticated
  using (
    public.is_own_company(company_id)
    and public.has_permission('commission.manage')
  );

drop policy if exists "Sale credits readable by commission.manage"
  on public.sale_credits;
create policy "Sale credits readable by commission.manage"
  on public.sale_credits for select
  to authenticated
  using (
    public.is_own_company(company_id)
    and public.has_permission('commission.manage')
  );

drop policy if exists "Commission entries readable by owner of entry or commission.manage"
  on public.commission_entries;
drop policy if exists "Commission entries readable by commission.manage"
  on public.commission_entries;

-- The ledger carries cost_cents, which a salesperson must not see, so only
-- commission.manage reads it directly. The rep's own statement comes from a
-- security-definer function in a later migration that returns amounts only.
create policy "Commission entries readable by commission.manage"
  on public.commission_entries for select
  to authenticated
  using (
    public.is_own_company(company_id)
    and public.has_permission('commission.manage')
  );

grant select on public.commission_plans to authenticated;
grant select on public.sale_credits to authenticated;
grant select on public.commission_entries to authenticated;

-- Supabase grants new tables to anon by default; RLS already blocks every row, this removes the table privilege as well.
revoke all on public.commission_plans from anon, public;
revoke all on public.sale_credits from anon, public;
revoke all on public.commission_entries from anon, public;

-- ============================================================================
-- 6. Permission keys: 168's is_valid_permission_key and
--    seed_sleep_trial_permission_defaults bodies verbatim plus
--    commission.manage (owner, admin) and commission.view_own (all roles),
--    then the usual backfill over companies.
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
    'commission.view_own'
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
      ('employee', 'commission.view_own')
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
-- 7a. commission_credit_shares: the active split for a journey. When no
--     active row exists for a kind, the default is the journey's assigned
--     employee (EMPLOYEE) or selling store (STORE) at 10000 bp. The two
--     kinds default independently: explicit EMPLOYEE rows do not replace
--     the STORE default.
-- ============================================================================

create or replace function public.commission_credit_shares(p_journey_id uuid)
returns table(kind text, employee_id uuid, store_id uuid, share_bp integer)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_journey public.sleep_journeys%rowtype;
begin
  select * into v_journey
  from public.sleep_journeys
  where id = p_journey_id;

  if v_journey.id is null then
    return;
  end if;

  if exists (
    select 1 from public.sale_credits sc
    where sc.journey_id = p_journey_id
      and sc.kind = 'EMPLOYEE'
      and sc.superseded_at is null
  ) then
    return query
      select sc.kind, sc.employee_id, sc.store_id, sc.share_bp
      from public.sale_credits sc
      where sc.journey_id = p_journey_id
        and sc.kind = 'EMPLOYEE'
        and sc.superseded_at is null;
  else
    return query
      select 'EMPLOYEE'::text, v_journey.assigned_employee_id, null::uuid, 10000;
  end if;

  if exists (
    select 1 from public.sale_credits sc
    where sc.journey_id = p_journey_id
      and sc.kind = 'STORE'
      and sc.superseded_at is null
  ) then
    return query
      select sc.kind, sc.employee_id, sc.store_id, sc.share_bp
      from public.sale_credits sc
      where sc.journey_id = p_journey_id
        and sc.kind = 'STORE'
        and sc.superseded_at is null;
  else
    return query
      select 'STORE'::text, null::uuid, v_journey.store_id, 10000;
  end if;
end;
$$;

revoke execute on function public.commission_credit_shares(uuid)
  from public, anon, authenticated;

-- ============================================================================
-- 7b. Pay-period math. The period containing p_date starts
--     floor((p_date - anchor) / days) periods after the anchor; floor
--     division (not truncation) keeps dates before the anchor correct.
-- ============================================================================

create or replace function public.commission_pay_period_start(p_company_id uuid, p_date date)
returns date
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_anchor date;
  v_days integer;
begin
  select coalesce(c.pay_period_anchor, date '2024-01-01'), c.pay_period_days
    into v_anchor, v_days
  from public.companies c
  where c.id = p_company_id;

  if v_anchor is null or v_days is null or v_days <= 0 then
    return null;
  end if;

  return v_anchor
    + floor((p_date - v_anchor)::numeric / v_days)::int * v_days;
end;
$$;

create or replace function public.commission_pay_period_end(p_company_id uuid, p_date date)
returns date
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_anchor date;
  v_days integer;
begin
  select coalesce(c.pay_period_anchor, date '2024-01-01'), c.pay_period_days
    into v_anchor, v_days
  from public.companies c
  where c.id = p_company_id;

  if v_anchor is null or v_days is null or v_days <= 0 then
    return null;
  end if;

  -- First day of the NEXT period minus one day.
  return v_anchor
    + (floor((p_date - v_anchor)::numeric / v_days)::int + 1) * v_days - 1;
end;
$$;

revoke execute on function public.commission_pay_period_start(uuid, date)
  from public, anon, authenticated;
revoke execute on function public.commission_pay_period_end(uuid, date)
  from public, anon, authenticated;

-- Thin wrapper for the caller's own company. commission.manage is checked
-- inside so a plain employee cannot read period boundaries they do not
-- need; the browser calls this for the pay-period label only.
create or replace function public.commission_pay_period(p_date date)
returns table(period_start date, period_end date)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
begin
  if not public.has_permission('commission.manage') then
    raise exception 'You do not have permission to view commission periods';
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
    select public.commission_pay_period_start(v_company_id, p_date),
           public.commission_pay_period_end(v_company_id, p_date);
end;
$$;

revoke execute on function public.commission_pay_period(date)
  from public, anon;
grant execute on function public.commission_pay_period(date) to authenticated;
