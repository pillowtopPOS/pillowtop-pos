-- 073_sleep_trial_exceptions.sql
--
-- Sleep Trial Engine, ST-6 Phase 1 (docs/sleep-trial-engine.md Sections
-- 15.1, 15.2, 26.4): the exceptions data model. Schema only — no RPCs,
-- no evaluator changes, no UI. request_sleep_trial_exception v2 and the
-- transition functions are Phase 2.
--
--   1. Three enums: exception type / status / decision.
--   2. sleep_trial_exception_reasons + per-company seed (only companies
--      that currently have a SLEEP_TRIAL policy).
--   3. sleep_trial_exceptions — every departure from a customer's bound
--      policy, exactly the Section 15.2 fields (+ legacy_request_id).
--   4. One-way copy of sleep_trial_exception_requests rows in.
--   5. Indexes, including the unique partial that guarantees one PENDING
--      exception per (trial_item_id, exception_type) for the Phase-2
--      request RPC.
--
-- sleep_trial_exception_requests is NOT dropped or emptied. Per spec 26.4
-- it stays read-only for one release, then is dropped by a later
-- migration. Honest caveat: it cannot be literally read-only yet —
-- request_sleep_trial_exception (070), the decide/cancel RPCs (058/060),
-- request_concern_exchange (058), and stv_eval_one's pending/approved fact
-- reads (070) still touch it. Phase 2 rewires those writers/readers to
-- sleep_trial_exceptions; until then both tables exist and the copy below
-- is re-runnable (legacy_request_id makes it idempotent).

-- ============================================================================
-- 1. Enums (Section 15.1 / 15.2)
-- ============================================================================

do $$
begin
  if not exists (select 1 from pg_type where typname = 'sleep_trial_exception_type') then
    create type public.sleep_trial_exception_type as enum (
      'EARLY_EXCHANGE', 'EXPIRED_EXCHANGE', 'EXTRA_EXCHANGE', 'FEE_WAIVER',
      'RETURN_NOT_ALLOWED', 'RETURN_APPROVAL', 'EXPIRED_RETURN',
      'PROTECTOR_OVERRIDE', 'EXTEND_TRIAL', 'REPLACEMENT_TRIAL',
      'INSPECTION_OVERRIDE', 'NON_ELIGIBLE_ITEM');
  end if;
  if not exists (select 1 from pg_type where typname = 'sleep_trial_exception_status') then
    create type public.sleep_trial_exception_status as enum (
      'PENDING', 'APPROVED', 'DENIED', 'CANCELLED', 'EXPIRED', 'STALE',
      'CONSUMED');
  end if;
  if not exists (select 1 from pg_type where typname = 'sleep_trial_exception_decision') then
    create type public.sleep_trial_exception_decision as enum (
      'APPROVED_AS_REQUESTED', 'APPROVED_MODIFIED', 'DENIED',
      'SELF_AUTHORIZED');
  end if;
end;
$$;

-- ============================================================================
-- 2. sleep_trial_exception_reasons (Section 26.4)
--    Created before sleep_trial_exceptions so reason_code_id can reference
--    it.
-- ============================================================================

create table if not exists public.sleep_trial_exception_reasons (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  label text not null,
  sort_order integer not null,
  is_active boolean not null default true,
  requires_note boolean not null default false,
  unique (company_id, label)
);

comment on table public.sleep_trial_exception_reasons is
  'Reason-code list for sleep trial exceptions (Section 15.2). Seeded per '
  'company below; editable, never deleted once used. NOTE: a company that '
  'adopts a SLEEP_TRIAL policy AFTER this migration will have no rows — the '
  'first-time policy-create/publish path (067) must run this same seed then. '
  'Not solved in this migration; do not lose it.';

alter table public.sleep_trial_exception_reasons enable row level security;

drop policy if exists "Sleep trial exception reasons viewable by company members"
  on public.sleep_trial_exception_reasons;
create policy "Sleep trial exception reasons viewable by company members"
  on public.sleep_trial_exception_reasons for select
  to authenticated
  -- Company-scoped (no journey_id): same pattern as 066/067.
  using (company_id = public.current_employee_company_id());

grant select on public.sleep_trial_exception_reasons to authenticated;
-- Write lockdown: reason lists are managed inside security-definer
-- functions (future admin UI), never by direct client writes.
revoke insert, update, delete, truncate on public.sleep_trial_exception_reasons
  from anon, authenticated;

-- Seed: every company that currently has a SLEEP_TRIAL policy. 'Other'
-- requires a note (Section 15.2: note required for Other and for
-- self-approvals).
insert into public.sleep_trial_exception_reasons
  (company_id, label, sort_order, requires_note)
select p.company_id, r.label, r.sort_order, r.requires_note
from (
  select distinct company_id
  from public.policies
  where policy_type = 'SLEEP_TRIAL'
) p
cross join (values
  ('Customer hardship',            1,  false),
  ('Delivery problem',             2,  false),
  ('Incorrect recommendation',     3,  false),
  ('Suspected product defect',     4,  false),
  ('Manufacturer accommodation',   5,  false),
  ('Customer retention',           6,  false),
  ('Store error',                  7,  false),
  ('Employee error',               8,  false),
  ('Management goodwill',          9,  false),
  ('Other',                        10, true)
) as r(label, sort_order, requires_note)
on conflict (company_id, label) do nothing;

-- ============================================================================
-- 3. sleep_trial_exceptions (Section 15.2, fields in spec order)
-- ============================================================================

create table if not exists public.sleep_trial_exceptions (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  journey_id uuid not null references public.sleep_journeys (id) on delete cascade,
  -- Nullable on purpose: NON_ELIGIBLE_ITEM is the type for "no trial item
  -- exists" (the approval creates one, Section 15.1), and migrated legacy
  -- requests may not resolve to a single item.
  trial_item_id uuid references public.sleep_trial_items (id) on delete set null,
  exception_type public.sleep_trial_exception_type not null,
  -- EXCHANGE, RETURN, or TRIAL (extensions). Text + check, not a fourth
  -- enum — three values don't need enum machinery.
  action text not null check (action in ('EXCHANGE','RETURN','TRIAL')),
  -- The full evaluator result at request time ("what the system said").
  -- For migrated legacy rows this carries the request's recorded facts
  -- instead of a fabricated evaluator blob.
  original_evaluation jsonb,
  policy_version_id uuid references public.policy_versions (id) on delete set null,
  rule_reference text,
  requested_terms jsonb,         -- e.g. {"fee_percent_bp":0} / {"extension_nights":30}
  reason_code_id uuid references public.sleep_trial_exception_reasons (id) on delete set null,
  reason_note text,              -- required for Other and self-approvals (RPC-enforced)
  customer_circumstances text,
  notes text,
  approver_note text,
  attachments jsonb not null default '[]'::jsonb,  -- storage file refs (existing pattern)
  requester_employee_id uuid not null references public.employees (id) on delete restrict,
  requested_at timestamptz not null default now(),
  status public.sleep_trial_exception_status not null default 'PENDING',
  decision public.sleep_trial_exception_decision,
  approved_terms jsonb,          -- what was actually granted
  approver_employee_id uuid references public.employees (id) on delete set null,
  decided_at timestamptz,
  decision_note text,
  self_authorized boolean not null default false,
  valid_until timestamptz,       -- decided_at + exceptions.approval_valid_days
  facts_hash text,               -- hash of the facts the approval covers (15.7)
  consumed_at timestamptz,
  consumed_by_type text,         -- 'exchange' | 'return' — no FK: those record
                                 -- tables ship with the Exchange Builder
  consumed_by_id uuid,
  financial_impact_cents integer, -- computed at consumption: fee policy said - fee charged
  idempotency_key text,
  -- Approved non-spec column: the legacy request row this was migrated
  -- from, so the Phase-2 re-copy (rows written between now and the
  -- cutover) is idempotent via "where not exists".
  legacy_request_id uuid unique references public.sleep_trial_exception_requests (id) on delete set null
);

comment on table public.sleep_trial_exceptions is
  'Every departure from a customer''s bound sleep-trial policy (Section '
  '15.2). Status transitions happen only inside security-definer functions '
  '(Phase 2) — no direct table writes, same lockdown as 062/065/069. '
  'Per spec: no created_at/updated_at — requested_at plus the decision/'
  'consumption timestamps and audit_events cover it.';

alter table public.sleep_trial_exceptions enable row level security;

drop policy if exists "Sleep trial exceptions viewable by journey viewers"
  on public.sleep_trial_exceptions;
create policy "Sleep trial exceptions viewable by journey viewers"
  on public.sleep_trial_exceptions for select
  to authenticated
  using (public.is_journey_visible(journey_id));

grant select on public.sleep_trial_exceptions to authenticated;
revoke insert, update, delete, truncate on public.sleep_trial_exceptions
  from anon, authenticated;

-- ============================================================================
-- 4. Migrate sleep_trial_exception_requests rows (Section 26.4)
--    Only 'early_exchange' rows exist by construction (requested_action is
--    a text column that only ever held that value). Status map:
--    pending->PENDING, approved->APPROVED, denied->DENIED,
--    expired->EXPIRED, cancelled->CANCELLED.
--    trial_item_id: the journey's single live item resolves it; a journey
--    with several live items gets NULL — the legacy request was
--    journey-scoped, so which mattress it covered is unknowable.
--    Idempotent via legacy_request_id — re-run after Phase-2 cutover picks
--    up rows written in the gap.
-- ============================================================================

insert into public.sleep_trial_exceptions (
  company_id, journey_id, trial_item_id,
  exception_type, action, original_evaluation,
  reason_note,
  requester_employee_id, requested_at,
  status, decision,
  approver_employee_id, decided_at,
  valid_until,
  legacy_request_id
)
select
  st.company_id,
  r.journey_id,
  case when count(i.id) = 1 then (array_agg(i.id))[1] end,
  'EARLY_EXCHANGE',
  'EXCHANGE',
  jsonb_build_object(
    'legacy_request', true,
    'current_trial_night', r.current_trial_night,
    'normal_eligibility_date', r.normal_eligibility_date,
    'sleep_concern_id', r.sleep_concern_id),
  r.reason,
  r.requester_employee_id,
  r.requested_at,
  (case r.status
     when 'pending'   then 'PENDING'
     when 'approved'  then 'APPROVED'
     when 'denied'    then 'DENIED'
     when 'expired'   then 'EXPIRED'
     when 'cancelled' then 'CANCELLED'
   end)::public.sleep_trial_exception_status,
  (case r.status
     when 'approved' then 'APPROVED_AS_REQUESTED'
     when 'denied'   then 'DENIED'
   end)::public.sleep_trial_exception_decision,
  r.approver_employee_id,
  r.decided_at,
  r.expires_at,
  r.id
from public.sleep_trial_exception_requests r
join public.sleep_journeys sj on sj.id = r.journey_id
join public.stores st on st.id = sj.store_id
left join public.sleep_trial_items i
  on i.journey_id = r.journey_id
 and i.status not in ('CLOSED','VOIDED')
where r.requested_action = 'early_exchange'
  and not exists (
    select 1 from public.sleep_trial_exceptions e
    where e.legacy_request_id = r.id)
group by r.id, st.company_id;

-- ============================================================================
-- 5. Indexes
-- ============================================================================

create index if not exists idx_sleep_trial_exceptions_journey
  on public.sleep_trial_exceptions (journey_id);
create index if not exists idx_sleep_trial_exceptions_company_status
  on public.sleep_trial_exceptions (company_id, status);
create index if not exists idx_sleep_trial_exceptions_item
  on public.sleep_trial_exceptions (trial_item_id);

-- Idempotent request retries (060 pattern).
create unique index if not exists idx_sleep_trial_exceptions_idempotency
  on public.sleep_trial_exceptions (idempotency_key)
  where idempotency_key is not null;

-- One PENDING exception per (item, type) — the Phase-2 request RPC relies
-- on this atomic guard instead of check-then-insert (Section 15.4). NULL
-- trial_item_id rows never collide (NULLs are distinct), which is the
-- correct behavior for NON_ELIGIBLE_ITEM.
create unique index if not exists idx_sleep_trial_exceptions_pending
  on public.sleep_trial_exceptions (trial_item_id, exception_type)
  where status = 'PENDING';
