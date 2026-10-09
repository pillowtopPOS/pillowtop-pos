-- 087_exchange_foundations.sql
--
-- Exchange Builder, EB-1: foundations only (docs/exchange-builder-spec.md,
-- Sections 4, 5, 12, 13, 14, 15, 17). No stock movement, no child journey,
-- no commit, no UI wiring. START_EXCHANGE / START_RETURN stay disabled.
--
--   0. EB-0 polish: correct_trial_start(4-arg) locks the trial item row
--      with SELECT ... FOR UPDATE before reading it. No other change.
--   1. sleep_trial_actions: the exchange/return record (spec Section 13).
--   2. sleep_journeys + journey_line_items link columns.
--   3. Permissions: three new keys seeded and whitelisted (085 pattern).
--   4. quote_sleep_trial_action / create_exchange_draft /
--      discard_exchange_draft + internal trial-item state helpers.
--   5. Audit events EXCHANGE_DRAFT_CREATED / EXCHANGE_DRAFT_DISCARDED.
--
-- Safe to re-run: create-or-replace / if-not-exists / drop-policy-if-exists
-- / DO-guarded constraints throughout.

-- ============================================================================
-- 0. EB-0 polish: lock the item row before reading it
--    Identical to 086 except the item SELECT takes FOR UPDATE, so two
--    concurrent corrections on the same mattress serialize on the row lock.
-- ============================================================================

create or replace function public.correct_trial_start(
  p_journey_id uuid,
  p_trial_item_id uuid,
  p_new_started_at date,
  p_reason text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item public.sleep_trial_items%rowtype;
  v_journey public.sleep_journeys%rowtype;
  v_employee_id uuid;
  v_correction_id uuid;
  v_summary text;
  v_item_name text;
  v_unit_price numeric;
  v_fee_cents int;
  v_item_count int;
  v_delivered_equiv date;
begin
  -- Lock first: the read below doubles as the row lock so a concurrent
  -- correction (or a future exchange/return state change) serializes here.
  select * into v_item
  from public.sleep_trial_items
  where id = p_trial_item_id
  for update;

  if v_item.id is null then
    raise exception 'Trial item not found';
  end if;
  if v_item.journey_id is distinct from p_journey_id then
    raise exception 'Trial item does not belong to this journey';
  end if;

  if not public.is_journey_visible(p_journey_id) then
    raise exception 'Not authorized for this journey';
  end if;

  -- Same privileged-role check as the 057 version: owner/admin/manager in
  -- the journey's company.
  if not exists (
    select 1
    from public.employees e
    join public.stores es on es.id = e.home_store_id
    join public.sleep_journeys sj on sj.id = p_journey_id
    join public.stores js on js.id = sj.store_id
    where e.auth_user_id = auth.uid()
      and es.company_id = js.company_id
      and e.role::text in ('owner','admin','manager')
  ) then
    raise exception 'Only owner, admin, or manager may correct a trial start date';
  end if;

  select id into v_employee_id
  from public.employees
  where auth_user_id = auth.uid();

  select * into v_journey
  from public.sleep_journeys
  where id = p_journey_id;

  -- Same date rules as before: required, never future, plus the delivery
  -- floor from 061 (not before the journey existed, relaxed one day for
  -- timezone drift).
  if p_new_started_at is null then
    raise exception 'New trial start date is required';
  end if;
  if p_new_started_at > current_date then
    raise exception 'Trial start date cannot be in the future';
  end if;
  if v_journey.created_at is not null
     and p_new_started_at < v_journey.created_at::date - 1 then
    raise exception 'Trial start date cannot be before the journey was created';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'A reason is required to correct the trial start';
  end if;

  if v_item.status = 'PENDING_FULFILLMENT' then
    -- The 057 guard: nothing to correct until the journey is delivered.
    if v_journey.delivered_at is null then
      raise exception 'Journey has no trial start to correct';
    end if;

    -- Same activation the delivered trigger performs for pending items
    -- (069): the corrected date is the asserted start, not re-derived.
    select jli.unit_price into v_unit_price
    from public.journey_line_items jli
    where jli.id = v_item.line_item_id;
    v_fee_cents := case when v_unit_price is not null
                        then round(v_unit_price * 100)::int end;

    update public.sleep_trial_items
    set status = 'ACTIVE',
        started_on = p_new_started_at,
        start_source = 'CORRECTION',
        fee_basis_cents = coalesce(fee_basis_cents, v_fee_cents),
        fee_basis_source = coalesce(fee_basis_source,
          case when v_fee_cents is not null then 'UNIT_PRICE' end),
        updated_at = now()
    where id = v_item.id;

    perform public.log_audit_event(
      v_item.company_id,
      'sleep_trial_item', v_item.id, 'SLEEP_TRIAL_STARTED',
      jsonb_build_object('status', 'PENDING_FULFILLMENT'),
      jsonb_build_object('status', 'ACTIVE', 'started_on', p_new_started_at,
                         'start_source', 'CORRECTION',
                         'fee_basis_cents', v_fee_cents),
      null, null, v_item.journey_id, 'EMPLOYEE', v_employee_id);

  elsif v_item.status = 'ACTIVE' then
    if v_item.started_on is null then
      raise exception 'This mattress has no trial start to correct';
    end if;
    if p_new_started_at = v_item.started_on then
      raise exception 'New date matches the current trial start';
    end if;

    update public.sleep_trial_items
    set started_on = p_new_started_at,
        start_source = 'CORRECTION',
        updated_at = now()
    where id = v_item.id;

    perform public.log_audit_event(
      v_item.company_id,
      'sleep_trial_item', v_item.id, 'SLEEP_TRIAL_START_CORRECTED',
      jsonb_build_object('started_on', v_item.started_on),
      jsonb_build_object('started_on', p_new_started_at),
      null, null, v_item.journey_id, 'EMPLOYEE', v_employee_id);
  else
    -- CLOSED / VOIDED / EXCHANGE_IN_PROGRESS / RETURN_IN_PROGRESS: the old
    -- cascade never touched these rows, so leave the item alone and reject
    -- instead of writing a correction row that changed nothing.
    raise exception 'This mattress''s trial is not active (status %) — its start date cannot be corrected',
      v_item.status;
  end if;

  -- Correction row: same fields as before plus trial_item_id.
  -- v_item still holds the pre-update row, so previous_started_at is the
  -- item's own old start.
  insert into public.sleep_trial_start_corrections (
    journey_id,
    trial_item_id,
    previous_started_at,
    new_started_at,
    reason,
    corrected_by_employee_id
  ) values (
    p_journey_id,
    v_item.id,
    v_item.started_on,
    p_new_started_at,
    btrim(p_reason),
    v_employee_id
  )
  returning id into v_correction_id;

  -- Journey-level start column: only meaningful while one item defines it.
  select count(*) into v_item_count
  from public.sleep_trial_items
  where journey_id = p_journey_id;

  if v_item_count = 1 then
    v_delivered_equiv := case
      when v_item.resolved_terms #>> '{trial,count_starts}' = 'FULFILLMENT_DATE'
        then p_new_started_at
      else p_new_started_at - 1 end;

    -- Fires trg_stv_journey_delivered, which recomputes this item's
    -- started_on back to p_new_started_at and skips it via the
    -- is-distinct check — one write, one audit.
    update public.sleep_journeys
    set delivered_at = v_delivered_equiv,
        updated_at = now()
    where id = p_journey_id;
  end if;

  -- Journey Activity row, same shape as 057, naming the mattress so a
  -- multi-mattress feed shows which one moved.
  v_item_name := nullif(btrim(
    coalesce(v_item.size_snapshot, '') || ' ' ||
    coalesce(v_item.product_name_snapshot, '')), '');
  v_summary := 'Trial start corrected'
    || case when v_item_name is not null
            then ' (' || v_item_name || ')' else '' end
    || ': ' || coalesce(v_item.started_on::text, 'unset')
    || ' → ' || p_new_started_at::text
    || '. Reason: ' || btrim(p_reason);

  insert into public.journey_interactions (
    journey_id,
    customer_id,
    interaction_type,
    channel,
    direction,
    topic,
    summary,
    created_by_employee_id,
    source_domain,
    source_record_id,
    is_internal
  ) values (
    p_journey_id,
    v_journey.customer_id,
    'other',
    'internal',
    'internal',
    'general',
    v_summary,
    v_employee_id,
    'sleep_trial',
    v_correction_id,
    true
  );

  return v_correction_id;
end;
$$;

grant execute on function public.correct_trial_start(uuid, uuid, date, text)
  to authenticated;

-- ============================================================================
-- 1. sleep_trial_actions (spec Section 13)
--    One record per exchange or return. Statuses drive the lifecycle:
--    DRAFT → COMMITTED → COMPLETED; DRAFT → CANCELLED (discard);
--    COMMITTED → CANCELLED (cancel, EB-2). All money is integer cents.
--    company_id is derived from the journey's store, never client input.
-- ============================================================================

create table if not exists public.sleep_trial_actions (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  journey_id uuid not null references public.sleep_journeys (id) on delete cascade,
  trial_item_id uuid not null references public.sleep_trial_items (id),
  action text not null check (action in ('EXCHANGE','RETURN')),
  status text not null default 'DRAFT'
    check (status in ('DRAFT','COMMITTED','COMPLETED','CANCELLED')),
  -- Locked at commit (EB-2); at draft time this holds the quote's
  -- evaluation snapshot for display.
  locked_evaluation jsonb,
  locked_fee_cents integer,
  exception_id uuid references public.sleep_trial_exceptions (id) on delete set null,
  -- "variant" and "product" are the same row in this schema — inventory
  -- positions key variant_id to products.id.
  replacement_product_id uuid references public.products (id) on delete set null,
  replacement_variant_id uuid references public.products (id) on delete set null,
  replacement_quantity integer,
  replacement_price_cents integer,
  replacement_price_reason text,
  original_credit_cents integer,
  exchange_fee_cents integer,
  other_fees_cents integer,
  tax_cents integer,
  net_cents integer,
  refund_owed_cents integer,
  commission_basis_cents integer,
  sale_attribution_employee_id uuid
    references public.employees (id) on delete set null,
  child_journey_id uuid references public.sleep_journeys (id) on delete set null,
  fulfillment_method text
    check (fulfillment_method in ('delivery','pickup')),
  replacement_delivered_on date,
  original_received_on date,
  original_location_id uuid references public.stores (id) on delete set null,
  refund_method text,
  refund_amount_cents integer,
  refund_reference text,
  refund_recorded_by uuid references public.employees (id) on delete set null,
  refund_recorded_at timestamptz,
  replacement_trial_item_id uuid
    references public.sleep_trial_items (id) on delete set null,
  concern_id uuid references public.sleep_concerns (id) on delete set null,
  idempotency_key text,
  created_by uuid references public.employees (id) on delete set null,
  created_at timestamptz not null default now(),
  committed_by uuid references public.employees (id) on delete set null,
  committed_at timestamptz,
  completed_by uuid references public.employees (id) on delete set null,
  completed_at timestamptz,
  cancelled_by uuid references public.employees (id) on delete set null,
  cancelled_at timestamptz,
  cancel_reason text
);

comment on table public.sleep_trial_actions is
  'Exchange Builder record (spec Section 13): one row per exchange or '
  'return. Owns the original-mattress side, the dollars, and the child '
  'journey link. Written only through security-definer RPCs — no direct '
  'client writes (062/065/069 lockdown pattern).';

-- Idempotency: one row per (company, key). NULL keys never collide.
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'sleep_trial_actions_idempotency_key'
  ) then
    alter table public.sleep_trial_actions
      add constraint sleep_trial_actions_idempotency_key
      unique (company_id, idempotency_key);
  end if;
end $$;

-- One open action per trial item (DRAFT or COMMITTED). create_exchange_draft
-- pre-checks for a friendly error; this index is the race-safe guarantee.
create unique index if not exists sleep_trial_actions_one_open_per_item
  on public.sleep_trial_actions (trial_item_id)
  where status in ('DRAFT','COMMITTED');

create index if not exists idx_sleep_trial_actions_journey
  on public.sleep_trial_actions (journey_id);
create index if not exists idx_sleep_trial_actions_trial_item
  on public.sleep_trial_actions (trial_item_id);

alter table public.sleep_trial_actions enable row level security;

drop policy if exists "Sleep trial actions viewable by journey viewers"
  on public.sleep_trial_actions;
create policy "Sleep trial actions viewable by journey viewers"
  on public.sleep_trial_actions for select
  to authenticated
  using (public.is_journey_visible(journey_id));

grant select on public.sleep_trial_actions to authenticated;
revoke insert, update, delete, truncate on public.sleep_trial_actions
  from public, anon, authenticated;

-- ============================================================================
-- 2. Journey and line-item link columns (spec Sections 4 B2, 13)
-- ============================================================================

alter table public.sleep_journeys
  add column if not exists parent_journey_id uuid
    references public.sleep_journeys (id) on delete set null;

alter table public.sleep_journeys
  add column if not exists exchange_action_id uuid
    references public.sleep_trial_actions (id) on delete set null;

alter table public.sleep_journeys
  add column if not exists sale_kind text not null default 'STANDARD';

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'sleep_journeys_sale_kind_check'
  ) then
    alter table public.sleep_journeys
      add constraint sleep_journeys_sale_kind_check
      check (sale_kind in ('STANDARD','EXCHANGE'));
  end if;
end $$;

-- Flags the replacement / fee / credit / other-fee lines on the child
-- journey (spec 7.1). On the ORIGINAL's delivered journey the 076 guard
-- already freezes every business field; an exchange_action_id-only update
-- passes its is-distinct carve-out unchanged.
alter table public.journey_line_items
  add column if not exists exchange_action_id uuid
    references public.sleep_trial_actions (id) on delete set null;

create index if not exists idx_sleep_journeys_parent
  on public.sleep_journeys (parent_journey_id)
  where parent_journey_id is not null;
create index if not exists idx_sleep_journeys_exchange_action
  on public.sleep_journeys (exchange_action_id)
  where exchange_action_id is not null;
create index if not exists idx_journey_line_items_exchange_action
  on public.journey_line_items (exchange_action_id)
  where exchange_action_id is not null;

-- ============================================================================
-- 3. Permissions (spec Section 12, 085 pattern)
--    New keys, same defaults table extended; every company backfilled.
--    set_role_permission's whitelist gains the keys so the Company
--    Settings grid can toggle them. No existing key or default changes.
-- ============================================================================

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
      -- start_return: owner, admin, manager
      ('owner',    'sleep_trial.start_return'),
      ('admin',    'sleep_trial.start_return'),
      ('manager',  'sleep_trial.start_return'),
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
      -- complete_exchange (spec 12): owner, admin
      ('owner',    'sleep_trial.complete_exchange'),
      ('admin',    'sleep_trial.complete_exchange'),
      -- inspect_returns (spec 12): owner, admin, manager
      ('owner',    'inventory.inspect_returns'),
      ('admin',    'inventory.inspect_returns'),
      ('manager',  'inventory.inspect_returns'),
      -- manage_inspection_checklist (spec 12): owner, admin
      ('owner',    'inventory.manage_inspection_checklist'),
      ('admin',    'inventory.manage_inspection_checklist')
  ) as g(role, permission_key)
  on conflict (company_id, role, permission_key) do nothing;
end;
$$;

revoke execute on function public.seed_sleep_trial_permission_defaults(uuid)
  from public, anon, authenticated;

-- Backfill existing companies (the companies-insert trigger already calls
-- this function for new ones); on conflict do nothing makes it idempotent.
select public.seed_sleep_trial_permission_defaults(id) from public.companies;

create or replace function public.set_role_permission(
  p_role text,
  p_key text,
  p_granted boolean
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor_id uuid;
  v_caller_role text;
  v_company_id uuid;
  v_grant_id uuid;
begin
  select e.id, e.role::text, s.company_id
    into v_actor_id, v_caller_role, v_company_id
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid()
    and e.is_active;

  if v_actor_id is null then
    raise exception 'Not authenticated as an employee';
  end if;

  if v_caller_role not in ('owner', 'admin') then
    raise exception 'Only owners and admins can change permissions';
  end if;

  if not exists (
    select 1
    from unnest(enum_range(null::public.employee_role)) as v
    where v::text = p_role
  ) then
    raise exception 'Unknown role: %', p_role;
  end if;

  if p_key not in (
    'sleep_trial.manage_concerns',
    'sleep_trial.start_exchange',
    'sleep_trial.start_return',
    'sleep_trial.request_exceptions',
    'sleep_trial.approve_exceptions',
    'sleep_trial.approve_own_exceptions',
    'sleep_trial.override_protector',
    'sleep_trial.correct_dates',
    'sleep_trial.manage_policy',
    'sleep_trial.view_policy_details',
    'inventory.reduce_below_committed',
    'sleep_trial.complete_exchange',
    'inventory.inspect_returns',
    'inventory.manage_inspection_checklist'
  ) then
    raise exception 'Unknown permission key: %', p_key;
  end if;

  if p_role = 'owner' and not p_granted then
    raise exception 'Owner permissions cannot be removed';
  end if;

  select id into v_grant_id
  from public.role_permission_grants
  where company_id = v_company_id
    and role = p_role
    and permission_key = p_key;

  if p_granted and v_grant_id is null then
    insert into public.role_permission_grants (company_id, role, permission_key, created_by)
    values (v_company_id, p_role, p_key, v_actor_id)
    returning id into v_grant_id;

    perform public.log_audit_event(
      p_company_id   := v_company_id,
      p_entity_type  := 'role_permission_grant',
      p_entity_id    := v_grant_id,
      p_event_type   := 'SLEEP_TRIAL_PERMISSION_GRANTED',
      p_after        := jsonb_build_object('role', p_role, 'permission_key', p_key, 'granted', true),
      p_actor_employee_id := v_actor_id
    );
  elsif not p_granted and v_grant_id is not null then
    delete from public.role_permission_grants where id = v_grant_id;

    perform public.log_audit_event(
      p_company_id   := v_company_id,
      p_entity_type  := 'role_permission_grant',
      p_entity_id    := v_grant_id,
      p_event_type   := 'SLEEP_TRIAL_PERMISSION_REVOKED',
      p_before       := jsonb_build_object('role', p_role, 'permission_key', p_key, 'granted', true),
      p_after        := jsonb_build_object('role', p_role, 'permission_key', p_key, 'granted', false),
      p_actor_employee_id := v_actor_id
    );
  end if;
  -- Granting an existing grant or revoking a missing one is a no-op; nothing
  -- changed, so nothing is audited.
end;
$$;

grant execute on function public.set_role_permission(text, text, boolean) to authenticated;

-- ============================================================================
-- 4a. quote_sleep_trial_action — read-only preview (spec Section 14)
--     Evaluator result + money preview + replacement-trial preview + the
--     applicable usable approved exception (validated, never consumed).
--     No stock availability in EB-1; no drafts or reservations written.
--     Note: stv_validate_trial_item_exception may persist an EXPIRED/STALE
--     flip — that lazy-expiry write is the 075 design, not a side effect
--     of quoting.
-- ============================================================================

create or replace function public.quote_sleep_trial_action(
  p_trial_item_id uuid,
  p_action text,
  p_replacement_product_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item public.sleep_trial_items%rowtype;
  v_company uuid;
  v_eval jsonb;
  v_action_result jsonb;
  v_fee_cents int;
  v_credit_cents int;
  v_repl_price_cents int;
  v_net int;
  v_used int;
  v_repl_entry jsonb;
  v_preview jsonb;
  v_exc record;
  v_exc_check jsonb;
  v_applicable jsonb;
begin
  if p_action not in ('EXCHANGE','RETURN') then
    raise exception 'action must be EXCHANGE or RETURN';
  end if;

  select * into v_item
  from public.sleep_trial_items
  where id = p_trial_item_id;
  if not found then
    raise exception 'Trial item not found';
  end if;
  if not public.is_journey_visible(v_item.journey_id) then
    raise exception 'Not authorized for this journey';
  end if;

  select st.company_id into v_company
  from public.sleep_journeys sj
  join public.stores st on st.id = sj.store_id
  where sj.id = v_item.journey_id;

  v_eval := public.stv_eval_one(p_trial_item_id, null);
  v_action_result := case p_action
    when 'EXCHANGE' then v_eval #> '{actions,EXCHANGE}'
    else v_eval #> '{actions,RETURN}' end;

  v_fee_cents := coalesce(
    (v_action_result #>> '{fee,amount_cents}')::int, 0);
  v_credit_cents := v_item.fee_basis_cents;

  -- Replacement default price: sale-aware, same rule as the client's
  -- getEffectivePrice — sale_price first, then price (dollars -> cents).
  v_repl_price_cents := null;
  if p_replacement_product_id is not null then
    select round(coalesce(p.sale_price, p.price) * 100)::int
    into v_repl_price_cents
    from public.products p
    where p.id = p_replacement_product_id
      and p.company_id = v_company;
    if not found then
      raise exception 'Replacement product not found in this company';
    end if;
  end if;

  -- net = replacement + fee - credit (other fees / tax are added later on
  -- the record; quote assumes zero). Signed: positive = customer owes.
  v_net := coalesce(v_repl_price_cents, 0)
           + coalesce(v_fee_cents, 0)
           - coalesce(v_credit_cents, 0);

  -- Replacement trial preview (policy rule base.exchange.replacement_trial,
  -- a list of {n, rule, nights?} indexed by exchange number; missing entry
  -- means NONE — docs/sleep-trial-engine.md Section 17).
  v_used := coalesce(
    (v_eval #>> '{display,exchanges_used}')::int, 0);
  v_repl_entry := null;
  if v_item.resolved_terms #> '{exchange,replacement_trial}' is not null then
    select e.val into v_repl_entry
    from jsonb_array_elements(
      v_item.resolved_terms #> '{exchange,replacement_trial}') as e(val)
    where (e.val ->> 'n')::int = v_used + 1
    limit 1;
  end if;
  if v_item.resolved_terms -> 'exchange' is null then
    v_preview := null;
  else
    v_preview := jsonb_build_object(
      'exchange_number', v_used + 1,
      'rule', coalesce(v_repl_entry ->> 'rule', 'NONE'),
      'nights', nullif(v_repl_entry ->> 'nights', '')::int,
      'replacement_minimum',
        v_item.resolved_terms #> '{exchange,replacement_minimum}');
  end if;

  -- Applicable usable approved exception for this item + action: newest
  -- APPROVED row first; validate each (may lazily mark EXPIRED/STALE) and
  -- take the first usable one. Never consumed here — consumption happens
  -- at commit (EB-2).
  v_applicable := null;
  for v_exc in
    select e.id, e.exception_type::text as exception_type, e.approved_terms
    from public.sleep_trial_exceptions e
    where e.trial_item_id = p_trial_item_id
      and e.action = p_action
      and e.status = 'APPROVED'
    order by e.decided_at desc
  loop
    v_exc_check := public.stv_validate_trial_item_exception(v_exc.id);
    if coalesce((v_exc_check ->> 'usable')::boolean, false) then
      v_applicable := jsonb_build_object(
        'exception_id', v_exc.id,
        'exception_type', v_exc.exception_type,
        'approved_terms', v_exc.approved_terms,
        'usable', true);
      exit;
    end if;
  end loop;

  return jsonb_build_object(
    'trial_item_id', p_trial_item_id,
    'journey_id', v_item.journey_id,
    'action', p_action,
    'evaluation', v_eval,
    'action_result', v_action_result,
    'locked_fee_cents', v_fee_cents,
    'original_credit_cents', v_credit_cents,
    'replacement_product_id', p_replacement_product_id,
    'replacement_price_cents', v_repl_price_cents,
    'net_cents', v_net,
    'refund_owed_cents', greatest(-v_net, 0),
    'commission_basis_cents', v_net,
    'replacement_trial_preview', v_preview,
    'applicable_exception', v_applicable,
    'quoted_at', now());
end;
$$;

revoke execute on function public.quote_sleep_trial_action(uuid, text, uuid)
  from public, anon;
grant execute on function public.quote_sleep_trial_action(uuid, text, uuid)
  to authenticated;

-- ============================================================================
-- 4b. create_exchange_draft — DRAFT record only (spec 5.4 "Start")
--     Nothing is reserved, no journey is created, the trial item is not
--     moved. Idempotent on (company_id, idempotency_key).
-- ============================================================================

create or replace function public.create_exchange_draft(
  p_trial_item_id uuid,
  p_action text,
  p_replacement_product_id uuid,
  p_replacement_variant_id uuid,
  p_fulfillment_method text,
  p_idempotency_key text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item public.sleep_trial_items%rowtype;
  v_company uuid;
  v_employee uuid;
  v_existing uuid;
  v_open record;
  v_quote jsonb;
  v_action_id uuid;
  v_exception_id uuid;
begin
  if p_action not in ('EXCHANGE','RETURN') then
    raise exception 'action must be EXCHANGE or RETURN';
  end if;

  if p_action = 'EXCHANGE'
     and not public.has_permission('sleep_trial.start_exchange') then
    raise exception 'Missing permission: sleep_trial.start_exchange';
  end if;
  if p_action = 'RETURN'
     and not public.has_permission('sleep_trial.start_return') then
    raise exception 'Missing permission: sleep_trial.start_return';
  end if;

  if p_fulfillment_method is not null
     and p_fulfillment_method not in ('delivery','pickup') then
    raise exception 'fulfillment_method must be delivery or pickup';
  end if;

  select e.id into v_employee
  from public.employees e
  where e.auth_user_id = auth.uid()
    and e.is_active;
  if v_employee is null then
    raise exception 'Employee record not found';
  end if;

  -- Lock the trial item: the ACTIVE check and the open-action check must
  -- serialize against a concurrent draft/commit on the same mattress.
  select * into v_item
  from public.sleep_trial_items
  where id = p_trial_item_id
  for update;
  if not found then
    raise exception 'Trial item not found';
  end if;
  if not public.is_journey_visible(v_item.journey_id) then
    raise exception 'Not authorized for this journey';
  end if;

  select st.company_id into v_company
  from public.sleep_journeys sj
  join public.stores st on st.id = sj.store_id
  where sj.id = v_item.journey_id;

  -- Idempotent retry: same key returns the same action id.
  if p_idempotency_key is not null then
    select a.id into v_existing
    from public.sleep_trial_actions a
    where a.company_id = v_company
      and a.idempotency_key = p_idempotency_key;
    if v_existing is not null then
      return v_existing;
    end if;
  end if;

  if v_item.status <> 'ACTIVE' then
    raise exception 'This mattress''s trial is not active (status %)',
      v_item.status;
  end if;

  -- Friendly pre-check; the partial unique index is the real guarantee.
  select a.id, e.name into v_open
  from public.sleep_trial_actions a
  left join public.employees e on e.id = a.created_by
  where a.trial_item_id = p_trial_item_id
    and a.status in ('DRAFT','COMMITTED')
  limit 1;
  if v_open.id is not null then
    raise exception 'An exchange or return is already in progress for this mattress (started by %)',
      coalesce(v_open.name, 'another employee');
  end if;

  v_quote := public.quote_sleep_trial_action(
    p_trial_item_id, p_action, p_replacement_product_id);

  v_exception_id := nullif(
    v_quote #>> '{applicable_exception,exception_id}', '')::uuid;

  insert into public.sleep_trial_actions (
    company_id,
    journey_id,
    trial_item_id,
    action,
    status,
    locked_evaluation,
    locked_fee_cents,
    exception_id,
    replacement_product_id,
    replacement_variant_id,
    replacement_quantity,
    replacement_price_cents,
    original_credit_cents,
    exchange_fee_cents,
    other_fees_cents,
    net_cents,
    refund_owed_cents,
    commission_basis_cents,
    sale_attribution_employee_id,
    fulfillment_method,
    idempotency_key,
    created_by
  ) values (
    v_company,
    v_item.journey_id,
    p_trial_item_id,
    p_action,
    'DRAFT',
    v_quote -> 'evaluation',
    nullif(v_quote ->> 'locked_fee_cents', '')::int,
    v_exception_id,
    p_replacement_product_id,
    p_replacement_variant_id,
    case when p_action = 'EXCHANGE' then 1 else null end,
    nullif(v_quote ->> 'replacement_price_cents', '')::int,
    nullif(v_quote ->> 'original_credit_cents', '')::int,
    nullif(v_quote ->> 'locked_fee_cents', '')::int,
    0,
    nullif(v_quote ->> 'net_cents', '')::int,
    nullif(v_quote ->> 'refund_owed_cents', '')::int,
    nullif(v_quote ->> 'commission_basis_cents', '')::int,
    v_employee,
    p_fulfillment_method,
    p_idempotency_key,
    v_employee
  )
  returning id into v_action_id;

  perform public.log_audit_event(
    p_company_id := v_company,
    p_entity_type := 'sleep_trial_action',
    p_entity_id := v_action_id,
    p_event_type := 'EXCHANGE_DRAFT_CREATED',
    p_after := jsonb_build_object(
      'action', p_action,
      'status', 'DRAFT',
      'trial_item_id', p_trial_item_id,
      'replacement_product_id', p_replacement_product_id,
      'fulfillment_method', p_fulfillment_method,
      'net_cents', nullif(v_quote ->> 'net_cents', '')::int,
      'exception_id', v_exception_id),
    p_journey_id := v_item.journey_id,
    p_actor_employee_id := v_employee
  );

  return v_action_id;
exception
  when unique_violation then
    -- Race: either the idempotency key or the open-action index tripped.
    if p_idempotency_key is not null then
      select a.id into v_existing
      from public.sleep_trial_actions a
      where a.company_id = v_company
        and a.idempotency_key = p_idempotency_key;
      if v_existing is not null then
        return v_existing;
      end if;
    end if;
    raise exception 'An exchange or return is already in progress for this mattress';
end;
$$;

revoke execute on function public.create_exchange_draft(
  uuid, text, uuid, uuid, text, text)
  from public, anon;
grant execute on function public.create_exchange_draft(
  uuid, text, uuid, uuid, text, text)
  to authenticated;

-- ============================================================================
-- 4c. discard_exchange_draft — DRAFT -> CANCELLED (spec 5.1)
--     Starter or a sleep_trial.complete_exchange holder.
-- ============================================================================

create or replace function public.discard_exchange_draft(
  p_action_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_action public.sleep_trial_actions%rowtype;
  v_employee uuid;
begin
  select * into v_action
  from public.sleep_trial_actions
  where id = p_action_id
  for update;
  if not found then
    raise exception 'Exchange draft not found';
  end if;
  if not public.is_journey_visible(v_action.journey_id) then
    raise exception 'Not authorized for this journey';
  end if;

  select e.id into v_employee
  from public.employees e
  where e.auth_user_id = auth.uid()
    and e.is_active;
  if v_employee is null then
    raise exception 'Employee record not found';
  end if;

  if v_action.status <> 'DRAFT' then
    raise exception 'Only a draft can be discarded (status %)',
      v_action.status;
  end if;

  if v_action.created_by is distinct from v_employee
     and not public.has_permission('sleep_trial.complete_exchange') then
    raise exception 'Only the employee who started this draft or someone with the complete-exchange permission can discard it';
  end if;

  update public.sleep_trial_actions
  set status = 'CANCELLED',
      cancelled_by = v_employee,
      cancelled_at = now()
  where id = v_action.id
    and status = 'DRAFT';
  if not found then
    raise exception 'This draft was already committed or cancelled';
  end if;

  perform public.log_audit_event(
    p_company_id := v_action.company_id,
    p_entity_type := 'sleep_trial_action',
    p_entity_id := v_action.id,
    p_event_type := 'EXCHANGE_DRAFT_DISCARDED',
    p_before := jsonb_build_object('status', 'DRAFT'),
    p_after := jsonb_build_object('status', 'CANCELLED'),
    p_journey_id := v_action.journey_id,
    p_actor_employee_id := v_employee
  );
end;
$$;

revoke execute on function public.discard_exchange_draft(uuid)
  from public, anon;
grant execute on function public.discard_exchange_draft(uuid)
  to authenticated;

-- ============================================================================
-- 4d. Internal trial-item state helpers (spec 5.3; EB-2 callers only —
--     revoked from all client roles). Each locks the item row, refuses
--     invalid source states, and writes an audit event.
-- ============================================================================

create or replace function public.stv_action_set_item_in_progress(
  p_item_id uuid,
  p_action text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item public.sleep_trial_items%rowtype;
  v_new_status text;
  v_employee uuid;
begin
  if p_action not in ('EXCHANGE','RETURN') then
    raise exception 'action must be EXCHANGE or RETURN';
  end if;
  v_new_status := case when p_action = 'EXCHANGE'
                       then 'EXCHANGE_IN_PROGRESS'
                       else 'RETURN_IN_PROGRESS' end;

  select * into v_item
  from public.sleep_trial_items
  where id = p_item_id
  for update;
  if not found then
    raise exception 'Trial item not found';
  end if;
  if v_item.status <> 'ACTIVE' then
    raise exception 'Trial item must be ACTIVE to start an action (status %)',
      v_item.status;
  end if;

  update public.sleep_trial_items
  set status = v_new_status,
      updated_at = now()
  where id = v_item.id;

  select e.id into v_employee
  from public.employees e where e.auth_user_id = auth.uid();

  perform public.log_audit_event(
    p_company_id := v_item.company_id,
    p_entity_type := 'sleep_trial_item',
    p_entity_id := v_item.id,
    p_event_type := 'SLEEP_TRIAL_ITEM_ACTION_STARTED',
    p_before := jsonb_build_object('status', 'ACTIVE'),
    p_after := jsonb_build_object('status', v_new_status, 'action', p_action),
    p_journey_id := v_item.journey_id,
    p_actor_employee_id := v_employee
  );
end;
$$;

create or replace function public.stv_action_reopen_item(
  p_item_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item public.sleep_trial_items%rowtype;
  v_employee uuid;
begin
  select * into v_item
  from public.sleep_trial_items
  where id = p_item_id
  for update;
  if not found then
    raise exception 'Trial item not found';
  end if;
  if v_item.status not in ('EXCHANGE_IN_PROGRESS','RETURN_IN_PROGRESS') then
    raise exception 'Trial item is not in an in-progress action (status %)',
      v_item.status;
  end if;

  -- Back to ACTIVE; started_on is untouched so the trial clock picks up
  -- where it left off (spec X10: days intact on cancel).
  update public.sleep_trial_items
  set status = 'ACTIVE',
      updated_at = now()
  where id = v_item.id;

  select e.id into v_employee
  from public.employees e where e.auth_user_id = auth.uid();

  perform public.log_audit_event(
    p_company_id := v_item.company_id,
    p_entity_type := 'sleep_trial_item',
    p_entity_id := v_item.id,
    p_event_type := 'SLEEP_TRIAL_ITEM_REOPENED',
    p_before := jsonb_build_object('status', v_item.status),
    p_after := jsonb_build_object('status', 'ACTIVE'),
    p_journey_id := v_item.journey_id,
    p_actor_employee_id := v_employee
  );
end;
$$;

create or replace function public.stv_action_close_item(
  p_item_id uuid,
  p_action text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item public.sleep_trial_items%rowtype;
  v_reason text;
  v_expected text;
  v_employee uuid;
begin
  if p_action not in ('EXCHANGE','RETURN') then
    raise exception 'action must be EXCHANGE or RETURN';
  end if;
  v_reason := case when p_action = 'EXCHANGE'
                   then 'EXCHANGED' else 'RETURNED' end;
  -- Computed here, not inline in the IF: plpgsql ends an IF condition at the
  -- first THEN, so a CASE ... THEN inside it is a syntax error.
  v_expected := case when p_action = 'EXCHANGE'
                     then 'EXCHANGE_IN_PROGRESS'
                     else 'RETURN_IN_PROGRESS' end;

  select * into v_item
  from public.sleep_trial_items
  where id = p_item_id
  for update;
  if not found then
    raise exception 'Trial item not found';
  end if;
  -- Only the matching in-progress state can close as EXCHANGED/RETURNED.
  if v_item.status <> v_expected then
    raise exception 'Trial item must be in % to close it as % (status %)',
      v_expected,
      v_reason,
      v_item.status;
  end if;

  update public.sleep_trial_items
  set status = 'CLOSED',
      close_reason = v_reason,
      closed_at = now(),
      updated_at = now()
  where id = v_item.id;

  select e.id into v_employee
  from public.employees e where e.auth_user_id = auth.uid();

  perform public.log_audit_event(
    p_company_id := v_item.company_id,
    p_entity_type := 'sleep_trial_item',
    p_entity_id := v_item.id,
    p_event_type := 'SLEEP_TRIAL_ITEM_CLOSED',
    p_before := jsonb_build_object('status', v_item.status),
    p_after := jsonb_build_object(
      'status', 'CLOSED', 'close_reason', v_reason),
    p_journey_id := v_item.journey_id,
    p_actor_employee_id := v_employee
  );
end;
$$;

revoke execute on function public.stv_action_set_item_in_progress(uuid, text)
  from public, anon, authenticated;
revoke execute on function public.stv_action_reopen_item(uuid)
  from public, anon, authenticated;
revoke execute on function public.stv_action_close_item(uuid, text)
  from public, anon, authenticated;
