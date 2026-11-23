-- ============================================================================
-- 178: commission spiffs
--
--   TBM pays spiffs monthly together with sales bonuses, not in the
--   bi-weekly pay period, so there is no payout integration here: the
--   monthly report arrives in a later slice. Both spiff kinds write to
--   commission_entries with kind = 'SPIFF':
--
--   1. Product spiffs: automatic, earned at the sale. The
--      journey_updated_to_sold event on journey_events is what "sold"
--      means; a separate trigger earns one SPIFF entry per line per
--      matching rule per current EMPLOYEE credit holder. Active
--      spiff_rules match by product id, brand or category (brand lives
--      on products, category on product_categories; both are free text
--      compared trimmed and case-insensitive), and rules stack. The
--      earned_date is the store-local date of the sold event.
--   2. Google review spiffs: the only manually entered spiff. Any role
--      can log one through log_google_review (default $25); the amount
--      splits across the journey's current credit holders and the
--      earned_date is today in the journey store's timezone, not the
--      review date. Voiding and journey cancellation write negative
--      reversing entries; old rows are never edited.
--
--   The bi-weekly report must ignore SPIFF rows completely, so
--   commission_period_live_lines now counts and sums only COMMISSION
--   and ADJUSTMENT kinds and get_payout_report applies the same filter
--   to its late-entry count. Both are create or replace with unchanged
--   signatures; the pay formula and spiff_cents = 0 are untouched.
-- ============================================================================

-- ============================================================================
-- 1. Permission keys. commission.spiffs_manage (rules, voiding) is
--    owner and admin only; commission.spiffs_log_review goes to every
--    role the app uses. Both keys are added to the single whitelist so
--    per-employee overrides can use them, then seeded exactly the way
--    174 and 176 seeded theirs.
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
    'commission.payouts_manage',
    'commission.spiffs_manage',
    'commission.spiffs_log_review'
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
      ('admin',    'commission.payouts_manage'),
      -- commission.spiffs_manage (178): owner, admin
      ('owner',    'commission.spiffs_manage'),
      ('admin',    'commission.spiffs_manage'),
      -- commission.spiffs_log_review (178): all roles
      ('owner',    'commission.spiffs_log_review'),
      ('admin',    'commission.spiffs_log_review'),
      ('manager',  'commission.spiffs_log_review'),
      ('sales',    'commission.spiffs_log_review'),
      ('employee', 'commission.spiffs_log_review')
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
-- 2. spiff_rules. Effective-dated match rules for automatic product
--    spiffs. No delete path exists: stop a rule with is_active = false
--    or an end date. Rules only ever change through the security
--    definer RPCs in section 10, which audit every create and change.
-- ============================================================================

create table if not exists public.spiff_rules (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  name text not null,
  scope text not null check (scope in ('PRODUCT', 'BRAND', 'CATEGORY')),
  product_id uuid references public.products (id) on delete cascade,
  scope_value text,
  amount_cents integer not null check (amount_cents > 0),
  starts_on date,
  ends_on date,
  is_active boolean not null default true,
  created_by uuid references public.employees (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (ends_on is null or starts_on is null or ends_on >= starts_on),
  check (
    (scope = 'PRODUCT' and product_id is not null)
    or (scope in ('BRAND', 'CATEGORY')
        and nullif(btrim(scope_value), '') is not null)
  )
);

create index if not exists idx_spiff_rules_company
  on public.spiff_rules (company_id, is_active);

alter table public.spiff_rules enable row level security;

drop policy if exists "Spiff rules readable by commission.spiffs_manage"
  on public.spiff_rules;
create policy "Spiff rules readable by commission.spiffs_manage"
  on public.spiff_rules for select
  to authenticated
  using (
    public.is_own_company(company_id)
    and public.has_permission('commission.spiffs_manage')
  );

revoke all on public.spiff_rules from anon, public;
grant select on public.spiff_rules to authenticated;
revoke insert, update, delete, truncate, references, trigger
  on public.spiff_rules from authenticated;

-- ============================================================================
-- 3. google_review_spiffs. One active (not voided) review per journey
--    enforced by the partial unique index. Select is open to
--    commission.spiffs_log_review because the review log holds no cost
--    or pay data; the commission entries it spawns stay behind
--    commission.manage like every other ledger row.
-- ============================================================================

create table if not exists public.google_review_spiffs (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  journey_id uuid not null references public.sleep_journeys (id) on delete cascade,
  review_date date not null,
  amount_cents integer not null check (amount_cents > 0),
  note text,
  logged_by uuid references public.employees (id) on delete set null,
  logged_at timestamptz not null default now(),
  voided_at timestamptz,
  voided_by uuid references public.employees (id) on delete set null,
  void_reason text
);

create unique index if not exists idx_google_review_one_active
  on public.google_review_spiffs (journey_id)
  where voided_at is null;

create index if not exists idx_google_review_spiffs_company
  on public.google_review_spiffs (company_id, review_date);

alter table public.google_review_spiffs enable row level security;

drop policy if exists "Google reviews readable by commission.spiffs_log_review"
  on public.google_review_spiffs;
create policy "Google reviews readable by commission.spiffs_log_review"
  on public.google_review_spiffs for select
  to authenticated
  using (
    public.is_own_company(company_id)
    and public.has_permission('commission.spiffs_log_review')
  );

revoke all on public.google_review_spiffs from anon, public;
grant select on public.google_review_spiffs to authenticated;
revoke insert, update, delete, truncate, references, trigger
  on public.google_review_spiffs from authenticated;

-- ============================================================================
-- 4. commission_entries gets the two spiff links. spiff_rule_id marks a
--    rule-earned spiff; review_spiff_id marks a logged Google review
--    spiff, so the two kinds stay distinguishable. line_item_id drops
--    its NOT NULL because a review spiff attaches to the journey, not a
--    line. The partial unique index is the idempotency guard for the
--    earn trigger: one live entry per line, employee and rule, so a
--    repeated sold event cannot double-pay.
-- ============================================================================

alter table public.commission_entries
  alter column line_item_id drop not null;

alter table public.commission_entries
  add column if not exists spiff_rule_id uuid
    references public.spiff_rules (id) on delete set null;

alter table public.commission_entries
  add column if not exists review_spiff_id uuid
    references public.google_review_spiffs (id) on delete set null;

comment on column public.commission_entries.spiff_rule_id is
  'Set on rule-earned product spiffs (178); null on commission and '
  'review rows. Copied onto reversal entries for traceability.';

comment on column public.commission_entries.review_spiff_id is
  'Set on Google review spiffs (178); null on commission and rule rows. '
  'Copied onto reversal entries for traceability.';

create unique index if not exists idx_commission_entries_spiff_rule_earn
  on public.commission_entries (line_item_id, employee_id, spiff_rule_id)
  where kind = 'SPIFF'
    and reverses_entry_id is null
    and spiff_rule_id is not null;

-- ============================================================================
-- 5. commission_period_live_lines: SPIFF rows must not appear in the
--    bi-weekly report at all, so the entries CTE now filters to
--    COMMISSION and ADJUSTMENT kinds in the WHERE clause, which fixes
--    entry_count, not_calculated_count and commission_cents together.
--    Only this filter changed; signature, draws and shape are verbatim.
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
        and ce.kind in ('COMMISSION', 'ADJUSTMENT')
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
-- 6. get_payout_report: verbatim 177 body plus the same kind filter on
--    the closed-period late-entry count, so a SPIFF row written after a
--    close is not reported as a late entry either. Signature and every
--    other behaviour identical; spiff_cents stays 0.
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
                and ce.kind in ('COMMISSION', 'ADJUSTMENT')
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
-- 7. list_commission_entries: the line-item join becomes a LEFT join so
--    review spiffs (no line) appear in the ledger alongside commission
--    and rule spiff rows. Everything else identical.
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
    left join public.journey_line_items li on li.id = ce.line_item_id
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
-- 8. Product spiff earning. spiff_earn_for_sale runs for every line on
--    the journey that has a product and positive quantity, matches each
--    active rule inside its date window and writes one SPIFF entry per
--    line per rule per EMPLOYEE credit holder. earned_date is the
--    store-local date of the FIRST sold event on the journey; revenue,
--    cost and rate are null because a spiff has no margin math.
-- ============================================================================

create or replace function public.spiff_earn_for_sale(
  p_journey_id uuid,
  p_sold_at timestamptz
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_j record;
  v_sold_at timestamptz;
  v_sale_date date;
  v_line record;
  v_rule record;
  v_share record;
  v_amount integer;
  v_inserted integer;
  v_written integer := 0;
begin
  select j.id, j.store_id, j.price, j.cancelled_at, s.company_id,
         coalesce(s.timezone, c.business_timezone) as tz
    into v_j
  from public.sleep_journeys j
  join public.stores s on s.id = j.store_id
  join public.companies c on c.id = s.company_id
  where j.id = p_journey_id;

  -- The event row that fired the trigger cannot be trusted (see the
  -- comment on trg_zz_spiff_earn below), so "sold" is proven here
  -- instead of taken from current_state: the journey must exist, be
  -- uncancelled, carry at least one line item, be priced above zero
  -- and be paid in full.
  if v_j.id is null
     or v_j.cancelled_at is not null
     or v_j.price is null
     or v_j.price <= 0
     or not exists (
       select 1 from public.journey_line_items li
       where li.journey_id = p_journey_id
     )
     or coalesce(public.total_paid(p_journey_id), 0) < v_j.price then
    return 0;
  end if;

  -- The sale time is the FIRST journey_updated_to_sold event ever
  -- written, not the current one, so a re-fired or hand-inserted
  -- event can never move the sale date forward onto a newer rule.
  -- The triggering row is already visible to this AFTER trigger, so
  -- min() finds it when this really is the first sold event.
  select min(e.created_at) into v_sold_at
  from public.journey_events e
  where e.journey_id = p_journey_id
    and e.event_type = 'journey_updated_to_sold';

  if v_sold_at is null then
    return 0;
  end if;

  v_sale_date := (v_sold_at at time zone coalesce(v_j.tz, 'UTC'))::date;

  for v_line in
    select li.id as line_item_id, li.product_id, li.quantity,
           p.brand, pc.name as category_name
    from public.journey_line_items li
    join public.products p on p.id = li.product_id
    left join public.product_categories pc on pc.id = p.category_id
    where li.journey_id = p_journey_id
      and li.product_id is not null
      and li.quantity > 0
  loop
    for v_rule in
      select r.id, r.amount_cents
      from public.spiff_rules r
      where r.company_id = v_j.company_id
        and r.is_active
        and (r.starts_on is null or r.starts_on <= v_sale_date)
        and (r.ends_on is null or r.ends_on >= v_sale_date)
        and (
          (r.scope = 'PRODUCT' and r.product_id = v_line.product_id)
          or (r.scope = 'BRAND' and v_line.brand is not null
              and lower(btrim(r.scope_value)) = lower(btrim(v_line.brand)))
          or (r.scope = 'CATEGORY' and v_line.category_name is not null
              and lower(btrim(r.scope_value))
                  = lower(btrim(v_line.category_name)))
        )
    loop
      for v_share in
        select cs.employee_id, cs.share_bp
        from public.commission_credit_shares(p_journey_id) cs
        where cs.kind = 'EMPLOYEE'
          and cs.employee_id is not null
      loop
        -- cents per unit * quantity * share, rounded half up.
        v_amount := floor(
          v_rule.amount_cents::numeric * v_line.quantity
            * v_share.share_bp / 10000 + 0.5
        )::integer;

        insert into public.commission_entries (
          company_id, journey_id, line_item_id, fulfillment_unit_id,
          employee_id, store_id, kind, amount_cents, earned_at,
          earned_date, pay_period_start, revenue_cents, cost_cents,
          rate_bp, credit_share_bp, flags, spiff_rule_id, review_spiff_id
        ) values (
          v_j.company_id, p_journey_id, v_line.line_item_id, null,
          v_share.employee_id, v_j.store_id, 'SPIFF', v_amount,
          v_sold_at, v_sale_date,
          coalesce(
            public.commission_pay_period_start(v_j.company_id, v_sale_date),
            v_sale_date
          ),
          null, null, null, v_share.share_bp, '{}',
          v_rule.id, null
        )
        on conflict (line_item_id, employee_id, spiff_rule_id)
          where kind = 'SPIFF'
            and reverses_entry_id is null
            and spiff_rule_id is not null
          do nothing;

        get diagnostics v_inserted = row_count;
        v_written := v_written + v_inserted;
      end loop;
    end loop;
  end loop;

  return v_written;
end;
$$;

revoke execute on function public.spiff_earn_for_sale(uuid, timestamptz)
  from public, anon, authenticated;

-- The sold event already means "sold" everywhere else in the app; the
-- spiff earn is its own trigger so a spiff bug can never block the sale,
-- the state derivation or the commission earn. On error it warns and
-- writes an audit_events row like migration 175 does, then still
-- returns new so the event insert stands.
create or replace function public.trg_spiff_earn()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
begin
  perform public.spiff_earn_for_sale(new.journey_id, new.created_at);
  return new;
exception when others then
  raise warning 'spiff_earn_for_sale failed for journey %: %',
    new.journey_id, sqlerrm;

  select s.company_id into v_company_id
  from public.sleep_journeys j
  join public.stores s on s.id = j.store_id
  where j.id = new.journey_id;

  begin
    perform public.log_audit_event(
      v_company_id,
      'journey_event',
      new.id,
      'SPIFF_EARN_ERROR',
      null,
      jsonb_build_object(
        'journey_id', new.journey_id,
        'event_id', new.id,
        'sqlstate', sqlstate,
        'error', sqlerrm
      ),
      'SPIFF_EARN_FAILED',
      sqlerrm,
      new.journey_id,
      'SYSTEM'
    );
  exception when others then
    raise warning 'spiff error audit write failed for journey %: %',
      new.journey_id, sqlerrm;
  end;

  return new;
end;
$$;

revoke execute on function public.trg_spiff_earn()
  from public, anon, authenticated;

-- journey_events is directly insertable by authenticated users (a known
-- go-live gate, not just a spiffs problem), so this trigger cannot trust
-- the event; the paid-in-full proof inside spiff_earn_for_sale is what
-- stops a hand-inserted sold event from paying out.
drop trigger if exists trg_zz_spiff_earn on public.journey_events;
create trigger trg_zz_spiff_earn
  after insert on public.journey_events
  for each row
  when (new.event_type = 'journey_updated_to_sold')
  execute function public.trg_spiff_earn();

-- ============================================================================
-- 9. Cancellation reversal. Every cancel path funnels through setting
--    sleep_journeys.cancelled_at (the journey_cancelled event trigger,
--    plus any direct update), so the hook is an AFTER UPDATE trigger on
--    that transition: it catches every path, not only the event one.
--    Only rule-earned spiffs reverse; Google review spiffs survive a
--    cancelled sale and are voided explicitly instead. Reversals are
--    new negative entries; old rows are never edited.
-- ============================================================================

create or replace function public.spiff_reverse_for_cancel(p_journey_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_j record;
  v_ce record;
  v_today date;
  v_count integer := 0;
begin
  select j.id, j.store_id, s.company_id
    into v_j
  from public.sleep_journeys j
  join public.stores s on s.id = j.store_id
  where j.id = p_journey_id;

  if v_j.id is null then
    return 0;
  end if;

  v_today := coalesce(public.business_today(v_j.store_id), current_date);

  for v_ce in
    select ce.id, ce.employee_id, ce.store_id, ce.line_item_id,
           ce.amount_cents, ce.credit_share_bp, ce.spiff_rule_id
    from public.commission_entries ce
    where ce.journey_id = p_journey_id
      and ce.kind = 'SPIFF'
      and ce.spiff_rule_id is not null
      and ce.reverses_entry_id is null
      and not exists (
        select 1 from public.commission_entries r
        where r.reverses_entry_id = ce.id
      )
  loop
    insert into public.commission_entries (
      company_id, journey_id, line_item_id, fulfillment_unit_id,
      employee_id, store_id, kind, amount_cents, earned_at, earned_date,
      pay_period_start, revenue_cents, cost_cents, rate_bp,
      credit_share_bp, flags, reverses_entry_id, note,
      spiff_rule_id, review_spiff_id
    ) values (
      v_j.company_id, p_journey_id, v_ce.line_item_id, null,
      v_ce.employee_id, v_ce.store_id, 'SPIFF',
      -1 * v_ce.amount_cents, now(), v_today,
      coalesce(
        public.commission_pay_period_start(v_j.company_id, v_today),
        v_today
      ),
      null, null, null, v_ce.credit_share_bp, '{}',
      v_ce.id, 'Auto-reversed: journey cancelled',
      v_ce.spiff_rule_id, null
    );
    v_count := v_count + 1;
  end loop;

  if v_count > 0 then
    perform public.log_audit_event(
      v_j.company_id,
      'sleep_journey',
      p_journey_id,
      'SPIFF_ENTRIES_REVERSED',
      null,
      jsonb_build_object(
        'reversed_count', v_count,
        'reason', 'journey_cancelled'
      ),
      null,
      'Journey cancelled: rule-based spiff entries reversed',
      p_journey_id,
      'SYSTEM'
    );
  end if;

  return v_count;
end;
$$;

revoke execute on function public.spiff_reverse_for_cancel(uuid)
  from public, anon, authenticated;

create or replace function public.trg_spiff_cancel_reverse()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
begin
  perform public.spiff_reverse_for_cancel(new.id);
  return new;
exception when others then
  raise warning 'spiff_reverse_for_cancel failed for journey %: %',
    new.id, sqlerrm;

  select s.company_id into v_company_id
  from public.stores s
  where s.id = new.store_id;

  begin
    perform public.log_audit_event(
      v_company_id,
      'sleep_journey',
      new.id,
      'SPIFF_REVERSE_ERROR',
      null,
      jsonb_build_object(
        'journey_id', new.id,
        'sqlstate', sqlstate,
        'error', sqlerrm
      ),
      'SPIFF_REVERSE_FAILED',
      sqlerrm,
      new.id,
      'SYSTEM'
    );
  exception when others then
    raise warning 'spiff reversal audit write failed for journey %: %',
      new.id, sqlerrm;
  end;

  return new;
end;
$$;

revoke execute on function public.trg_spiff_cancel_reverse()
  from public, anon, authenticated;

drop trigger if exists trg_zz_spiff_cancel_reverse on public.sleep_journeys;
create trigger trg_zz_spiff_cancel_reverse
  after update of cancelled_at on public.sleep_journeys
  for each row
  when (old.cancelled_at is null and new.cancelled_at is not null)
  execute function public.trg_spiff_cancel_reverse();

-- ============================================================================
-- 10. Rule RPCs, all behind commission.spiffs_manage. Edits only affect
--     sales made after the edit because matching happens inside the
--     sold-event trigger; old entries are never recomputed or edited.
-- ============================================================================

create or replace function public.list_spiff_rules()
returns table(
  id uuid,
  name text,
  scope text,
  product_id uuid,
  product_name text,
  scope_value text,
  amount_cents integer,
  starts_on date,
  ends_on date,
  is_active boolean,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
begin
  if not public.has_permission('commission.spiffs_manage') then
    raise exception 'You do not have permission to manage spiff rules';
  end if;

  select s.company_id into v_company_id
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid()
    and e.is_active;

  return query
    select r.id, r.name, r.scope, r.product_id, p.item_name,
           r.scope_value, r.amount_cents, r.starts_on, r.ends_on,
           r.is_active, r.created_at, r.updated_at
    from public.spiff_rules r
    left join public.products p on p.id = r.product_id
    where r.company_id = v_company_id
    order by r.is_active desc, r.name;
end;
$$;

revoke execute on function public.list_spiff_rules()
  from public, anon;
grant execute on function public.list_spiff_rules()
  to authenticated;

create or replace function public.save_spiff_rule(
  p_id uuid default null,
  p_name text default null,
  p_scope text default null,
  p_product_id uuid default null,
  p_scope_value text default null,
  p_amount_cents integer default null,
  p_starts_on date default null,
  p_ends_on date default null,
  p_is_active boolean default true
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
  v_caller_employee_id uuid;
  v_existing public.spiff_rules%rowtype;
  v_rule_id uuid;
  v_product_id uuid;
  v_scope_value text;
  v_is_active boolean;
begin
  if not public.has_permission('commission.spiffs_manage') then
    raise exception 'You do not have permission to manage spiff rules';
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

  if nullif(btrim(p_name), '') is null then
    raise exception 'name is required';
  end if;

  if p_scope is null or p_scope not in ('PRODUCT', 'BRAND', 'CATEGORY') then
    raise exception 'scope must be PRODUCT, BRAND or CATEGORY';
  end if;

  if p_amount_cents is null or p_amount_cents <= 0 then
    raise exception 'amount_cents must be greater than 0';
  end if;

  if p_starts_on is not null and p_ends_on is not null
     and p_ends_on < p_starts_on then
    raise exception 'ends_on cannot be before starts_on';
  end if;

  -- Normalize: PRODUCT keeps only product_id, the other scopes keep
  -- only scope_value, so the table check and the matcher see the same
  -- shape no matter what the caller sent.
  if p_scope = 'PRODUCT' then
    if p_product_id is null then
      raise exception 'product_id is required for PRODUCT scope';
    end if;
    select p.id into v_product_id
    from public.products p
    where p.id = p_product_id
      and p.company_id = v_company_id;
    if v_product_id is null then
      raise exception 'Product does not belong to your company';
    end if;
    v_scope_value := null;
  else
    v_scope_value := nullif(btrim(p_scope_value), '');
    if v_scope_value is null then
      raise exception 'scope_value is required for % scope', p_scope;
    end if;
    v_product_id := null;
  end if;

  if p_id is null then
    insert into public.spiff_rules (
      company_id, name, scope, product_id, scope_value, amount_cents,
      starts_on, ends_on, is_active, created_by
    ) values (
      v_company_id, btrim(p_name), p_scope, v_product_id, v_scope_value,
      p_amount_cents, p_starts_on, p_ends_on,
      coalesce(p_is_active, true), v_caller_employee_id
    )
    returning id into v_rule_id;

    perform public.log_audit_event(
      v_company_id,
      'spiff_rule',
      v_rule_id,
      'SPIFF_RULE_SAVED',
      null,
      (select to_jsonb(r) from public.spiff_rules r where r.id = v_rule_id)
    );
  else
    select * into v_existing
    from public.spiff_rules r
    where r.id = p_id
      and r.company_id = v_company_id;

    if v_existing.id is null then
      raise exception 'Spiff rule not found';
    end if;

    v_is_active := coalesce(p_is_active, v_existing.is_active);

    update public.spiff_rules r
    set name = btrim(p_name),
        scope = p_scope,
        product_id = v_product_id,
        scope_value = v_scope_value,
        amount_cents = p_amount_cents,
        starts_on = p_starts_on,
        ends_on = p_ends_on,
        is_active = v_is_active,
        updated_at = now()
    where r.id = p_id;

    perform public.log_audit_event(
      v_company_id,
      'spiff_rule',
      p_id,
      'SPIFF_RULE_SAVED',
      to_jsonb(v_existing),
      (select to_jsonb(r) from public.spiff_rules r where r.id = p_id)
    );

    v_rule_id := p_id;
  end if;

  return v_rule_id;
end;
$$;

revoke execute on function public.save_spiff_rule(uuid, text, text, uuid, text, integer, date, date, boolean)
  from public, anon;
grant execute on function public.save_spiff_rule(uuid, text, text, uuid, text, integer, date, date, boolean)
  to authenticated;

create or replace function public.set_spiff_rule_active(
  p_id uuid,
  p_active boolean
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
  v_existing public.spiff_rules%rowtype;
begin
  if not public.has_permission('commission.spiffs_manage') then
    raise exception 'You do not have permission to manage spiff rules';
  end if;

  select s.company_id into v_company_id
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid()
    and e.is_active;

  if v_company_id is null then
    raise exception 'Not authenticated as an employee';
  end if;

  select * into v_existing
  from public.spiff_rules r
  where r.id = p_id
    and r.company_id = v_company_id;

  if v_existing.id is null then
    raise exception 'Spiff rule not found';
  end if;

  if v_existing.is_active is not distinct from p_active then
    return;
  end if;

  update public.spiff_rules r
  set is_active = p_active,
      updated_at = now()
  where r.id = p_id;

  perform public.log_audit_event(
    v_company_id,
    'spiff_rule',
    p_id,
    'SPIFF_RULE_TOGGLED',
    to_jsonb(v_existing),
    (select to_jsonb(r) from public.spiff_rules r where r.id = p_id)
  );
end;
$$;

revoke execute on function public.set_spiff_rule_active(uuid, boolean)
  from public, anon;
grant execute on function public.set_spiff_rule_active(uuid, boolean)
  to authenticated;

-- ============================================================================
-- 11. Google review RPCs. Logging is open to every role through
--     commission.spiffs_log_review; voiding stays owner and admin
--     through commission.spiffs_manage. The review row and its entries
--     insert in one transaction so a partial log is impossible.
-- ============================================================================

create or replace function public.log_google_review(
  p_journey_id uuid,
  p_review_date date,
  p_amount_cents integer default 2500,
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
  v_j record;
  v_review_id uuid;
  v_earned date;
  v_share record;
begin
  if not public.has_permission('commission.spiffs_log_review') then
    raise exception 'You do not have permission to log reviews';
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

  select j.id, j.store_id, s.company_id
    into v_j
  from public.sleep_journeys j
  join public.stores s on s.id = j.store_id
  where j.id = p_journey_id;

  if v_j.id is null or v_j.company_id <> v_company_id then
    raise exception 'Journey does not belong to your company';
  end if;

  if p_review_date is null then
    raise exception 'review_date is required';
  end if;

  v_earned := coalesce(public.business_today(v_j.store_id), current_date);

  if p_review_date > v_earned then
    raise exception 'review_date cannot be in the future';
  end if;

  if p_amount_cents is null or p_amount_cents <= 0 then
    raise exception 'amount_cents must be greater than 0';
  end if;

  begin
    insert into public.google_review_spiffs (
      company_id, journey_id, review_date, amount_cents, note, logged_by
    ) values (
      v_company_id, p_journey_id, p_review_date, p_amount_cents,
      p_note, v_caller_employee_id
    )
    returning id into v_review_id;
  exception
    when unique_violation then
      raise exception 'An active review is already logged for this journey';
  end;

  -- One entry per current EMPLOYEE credit holder, split by share. The
  -- spiff belongs to the credit holders, not to whoever typed the log.
  -- earned_date is today, not the review date, and revenue, cost and
  -- rate stay null because there is no margin math.
  for v_share in
    select cs.employee_id, cs.share_bp
    from public.commission_credit_shares(p_journey_id) cs
    where cs.kind = 'EMPLOYEE'
      and cs.employee_id is not null
  loop
    insert into public.commission_entries (
      company_id, journey_id, line_item_id, fulfillment_unit_id,
      employee_id, store_id, kind, amount_cents, earned_at, earned_date,
      pay_period_start, revenue_cents, cost_cents, rate_bp,
      credit_share_bp, flags, note, spiff_rule_id, review_spiff_id
    ) values (
      v_company_id, p_journey_id, null, null,
      v_share.employee_id, v_j.store_id, 'SPIFF',
      floor(p_amount_cents::numeric * v_share.share_bp / 10000 + 0.5)::integer,
      now(), v_earned,
      coalesce(
        public.commission_pay_period_start(v_company_id, v_earned),
        v_earned
      ),
      null, null, null, v_share.share_bp, '{}',
      p_note, null, v_review_id
    );
  end loop;

  perform public.log_audit_event(
    v_company_id,
    'google_review_spiff',
    v_review_id,
    'GOOGLE_REVIEW_LOGGED',
    null,
    jsonb_build_object(
      'journey_id', p_journey_id,
      'review_date', p_review_date,
      'amount_cents', p_amount_cents
    ),
    null,
    p_note,
    p_journey_id
  );

  return v_review_id;
end;
$$;

revoke execute on function public.log_google_review(uuid, date, integer, text)
  from public, anon;
grant execute on function public.log_google_review(uuid, date, integer, text)
  to authenticated;

create or replace function public.void_google_review(
  p_id uuid,
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
  v_review public.google_review_spiffs%rowtype;
  v_ce record;
  v_today date;
  v_store uuid;
begin
  if not public.has_permission('commission.spiffs_manage') then
    raise exception 'You do not have permission to manage spiffs';
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

  if nullif(btrim(p_reason), '') is null then
    raise exception 'A void reason is required';
  end if;

  select * into v_review
  from public.google_review_spiffs g
  where g.id = p_id
    and g.company_id = v_company_id;

  if v_review.id is null then
    raise exception 'Review not found';
  end if;

  if v_review.voided_at is not null then
    raise exception 'Review is already voided';
  end if;

  select j.store_id into v_store
  from public.sleep_journeys j
  where j.id = v_review.journey_id;

  v_today := coalesce(public.business_today(v_store), current_date);

  update public.google_review_spiffs g
  set voided_at = now(),
      voided_by = v_caller_employee_id,
      void_reason = btrim(p_reason)
  where g.id = p_id
    and g.voided_at is null;

  -- Reversing entries, never edits: one negative row per un-reversed
  -- spiff entry this review produced.
  for v_ce in
    select ce.id, ce.employee_id, ce.store_id, ce.amount_cents,
           ce.credit_share_bp
    from public.commission_entries ce
    where ce.review_spiff_id = p_id
      and ce.kind = 'SPIFF'
      and ce.reverses_entry_id is null
      and not exists (
        select 1 from public.commission_entries r
        where r.reverses_entry_id = ce.id
      )
  loop
    insert into public.commission_entries (
      company_id, journey_id, line_item_id, fulfillment_unit_id,
      employee_id, store_id, kind, amount_cents, earned_at, earned_date,
      pay_period_start, revenue_cents, cost_cents, rate_bp,
      credit_share_bp, flags, reverses_entry_id, note,
      spiff_rule_id, review_spiff_id
    ) values (
      v_company_id, v_review.journey_id, null, null,
      v_ce.employee_id, v_ce.store_id, 'SPIFF',
      -1 * v_ce.amount_cents, now(), v_today,
      coalesce(
        public.commission_pay_period_start(v_company_id, v_today),
        v_today
      ),
      null, null, null, v_ce.credit_share_bp, '{}',
      v_ce.id, 'Voided Google review: ' || btrim(p_reason),
      null, p_id
    );
  end loop;

  perform public.log_audit_event(
    v_company_id,
    'google_review_spiff',
    p_id,
    'GOOGLE_REVIEW_VOIDED',
    to_jsonb(v_review),
    (select to_jsonb(g) from public.google_review_spiffs g where g.id = p_id),
    null,
    btrim(p_reason),
    v_review.journey_id
  );
end;
$$;

revoke execute on function public.void_google_review(uuid, text)
  from public, anon;
grant execute on function public.void_google_review(uuid, text)
  to authenticated;

create or replace function public.list_google_reviews(
  p_from date,
  p_to date
)
returns table(
  id uuid,
  journey_id uuid,
  journey_number text,
  customer_name text,
  review_date date,
  amount_cents integer,
  logged_by_name text,
  logged_at timestamptz,
  voided_at timestamptz,
  void_reason text
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
begin
  if not public.has_permission('commission.spiffs_log_review') then
    raise exception 'You do not have permission to view reviews';
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
    select g.id, g.journey_id, sj.journey_number,
           btrim(cu.first_name || ' ' || cu.last_name),
           g.review_date, g.amount_cents, emp.name, g.logged_at,
           g.voided_at, g.void_reason
    from public.google_review_spiffs g
    join public.sleep_journeys sj on sj.id = g.journey_id
    join public.customers cu on cu.id = sj.customer_id
    left join public.employees emp on emp.id = g.logged_by
    where g.company_id = v_company_id
      and (p_from is null or g.review_date >= p_from)
      and (p_to is null or g.review_date <= p_to)
    order by g.review_date desc, g.logged_at desc;
end;
$$;

revoke execute on function public.list_google_reviews(date, date)
  from public, anon;
grant execute on function public.list_google_reviews(date, date)
  to authenticated;
